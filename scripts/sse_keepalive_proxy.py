#!/usr/bin/env python3
"""HTTP forwarder that keeps silent SSE streams alive.

The server sends nothing during a prompt fill or while the model writes a tool
call's arguments, and Node's fetch drops a response body after 300 s of silence.
This forwards each request to the server and, on chunked text/event-stream
responses, sends an SSE comment after a stretch of silence. Comments only go
between events, and SSE clients ignore them. Other responses pass through as is.

Uses the listening socket from systemd when a socket unit starts it, otherwise
binds --listen HOST:PORT.
"""
import argparse
import asyncio
import os
import socket
import time

LIMIT = 1 << 20
COMMENT = b": keep-alive\n\n"
COMMENT_CHUNK = b"%x\r\n%s\r\n" % (len(COMMENT), COMMENT)
HOP_BY_HOP = {b"connection", b"keep-alive", b"proxy-connection"}
UNAVAILABLE_BODY = b'{"error":"model server unavailable"}'
UNAVAILABLE = (
    b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\n"
    b"Content-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(UNAVAILABLE_BODY), UNAVAILABLE_BODY)
)
EXPECTED_ERRORS = (ConnectionError, asyncio.IncompleteReadError, asyncio.CancelledError)


def field_name(line):
    return line.partition(b":")[0].strip().lower()


def close_after(head):
    """One request per connection keeps the byte handling simple."""
    lines = head[:-4].split(b"\r\n")
    kept = [lines[0]] + [line for line in lines[1:] if field_name(line) not in HOP_BY_HOP]
    return b"\r\n".join(kept + [b"Connection: close"]) + b"\r\n\r\n"


def is_keepalive_stream(head):
    fields = {field_name(line): line.partition(b":")[2].strip().lower() for line in head[:-4].split(b"\r\n")[1:]}
    return (
        b"text/event-stream" in fields.get(b"content-type", b"")
        and b"chunked" in fields.get(b"transfer-encoding", b"")
        and b"content-encoding" not in fields
    )


async def copy(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


async def forward_request_body(client, server):
    """Returns only when the client leaves, which is what cancels the generation."""
    server_open = True
    while data := await client.read(65536):
        if server_open:
            try:
                server.write(data)
                await server.drain()
            except ConnectionError:
                server_open = False


async def relay_stream(reader, writer, keepalive_s):
    comments = 0
    between_events = True
    while True:
        next_line = asyncio.ensure_future(reader.readuntil(b"\r\n"))
        try:
            while not (await asyncio.wait({next_line}, timeout=keepalive_s))[0]:
                if between_events:
                    writer.write(COMMENT_CHUNK)
                    await writer.drain()
                    comments += 1
        except BaseException:
            next_line.cancel()
            raise
        size_line = next_line.result()
        size = int(size_line.split(b";")[0], 16)
        if size == 0:
            writer.write(size_line)
            while (trailer := await reader.readuntil(b"\r\n")) != b"\r\n":
                writer.write(trailer)
            writer.write(trailer)
            await writer.drain()
            return comments
        chunk = await reader.readexactly(size + 2)
        writer.write(size_line + chunk)
        await writer.drain()
        between_events = chunk[:-2].endswith(b"\n\n")


async def forward_response(server, client, keepalive_s):
    while True:
        head = await server.readuntil(b"\r\n\r\n")
        if not head.split(b" ", 2)[1].startswith(b"1"):
            break
        client.write(head)
        await client.drain()
    client.write(close_after(head))
    await client.drain()
    if not is_keepalive_stream(head):
        await copy(server, client)
        return
    started = time.monotonic()
    comments = await relay_stream(server, client, keepalive_s)
    if comments:
        print(f"stream done after {time.monotonic() - started:.0f} s, {comments} keep-alives", flush=True)


async def handle(client_r, client_w, upstream, keepalive_s):
    server_w = None
    tasks = []
    try:
        head = await client_r.readuntil(b"\r\n\r\n")
        try:
            server_r, server_w = await asyncio.open_connection(*upstream, limit=LIMIT)
        except OSError:
            client_w.write(UNAVAILABLE)
            await client_w.drain()
            return
        server_w.write(close_after(head))
        await server_w.drain()
        tasks = [
            asyncio.create_task(forward_request_body(client_r, server_w)),
            asyncio.create_task(forward_response(server_r, client_w, keepalive_s)),
        ]
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    except (*EXPECTED_ERRORS, asyncio.LimitOverrunError):
        pass
    finally:
        for task in tasks:
            task.cancel()
        for result in await asyncio.gather(*tasks, return_exceptions=True):
            if isinstance(result, Exception) and not isinstance(result, EXPECTED_ERRORS):
                print(f"request failed: {type(result).__name__}", flush=True)
        for writer in (server_w, client_w):
            if writer:
                writer.close()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1:8002")
    parser.add_argument("--upstream", default="127.0.0.1:8000")
    parser.add_argument("--keepalive", type=float, default=15.0)
    args = parser.parse_args()
    host, port = args.upstream.rsplit(":", 1)
    upstream = (host, int(port))

    def serve(reader, writer):
        return handle(reader, writer, upstream, args.keepalive)

    if os.environ.get("LISTEN_PID") == str(os.getpid()) and os.environ.get("LISTEN_FDS") == "1":
        server = await asyncio.start_server(serve, sock=socket.socket(fileno=3), limit=LIMIT)
    else:
        host, port = args.listen.rsplit(":", 1)
        server = await asyncio.start_server(serve, host, int(port), limit=LIMIT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
