#!/usr/bin/env python3
"""Agent decode speed split into step time and tokens per step, plus SSD reads per step.

Same session pick and trim as the recipe's bench/hermes_decode.py, so --mode measure sends the same
requests as the baseline. --mode record fills the prefix cache with the route record paused, then
decodes with it running, so the record holds decode routes and almost no prefill routes.
"""
import argparse, glob, hashlib, json, os, re, statistics as st, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--mode", choices=["measure", "record", "dry"], default="measure")
ap.add_argument("--dir", default=os.path.expanduser("~/.hermes/sessions"))
ap.add_argument("--url", default="http://127.0.0.1:8000/v1/chat/completions")
ap.add_argument("--metrics", default="http://127.0.0.1:8000/metrics")
ap.add_argument("--model", default="dsv41")
ap.add_argument("--max-chars", type=int, default=240000)
ap.add_argument("--tokens", type=int, default=384)
ap.add_argument("--shard", default="1/2")
ap.add_argument("--limit", type=int, default=6)
ap.add_argument("--spread", action="store_true", help="take sessions evenly across the shard, not the oldest")
ap.add_argument("--pause-file", default="")
ap.add_argument("--out", default="/dev/null")
ap.add_argument("--passes", type=int, default=2, help="ignore_eos passes per session in measure mode")
ap.add_argument("--real-pass", action="store_true", help="one more pass per session that stops where the model stops")
ap.add_argument("--text-out", default="", help="generated text goes here, never to --out or the console")
ap.add_argument("--sampling", choices=["greedy", "server"], default="greedy", help="server: send no temperature or ignore_eos, as agent clients do")
a = ap.parse_args()

KEYS = ("vllm:spec_decode_num_drafts", "vllm:spec_decode_num_accepted_tokens", "vllm:spec_decode_num_draft_tokens")


def body_of(f):
    x = json.load(open(f))
    b = x.get("request", {}).get("body") or x.get("request") or x
    return x.get("session_id") or f, json.loads(b) if isinstance(b, str) else b


def trim(msgs, cap):
    head = [m for m in msgs[:1] if m.get("role") == "system"]
    tail, n = [], len(json.dumps(head))
    for m in reversed(msgs[len(head):]):
        s = len(json.dumps(m))
        if n + s > cap and tail:
            break
        tail.append(m)
        n += s
    tail.reverse()
    while tail and tail[0].get("role") in ("tool", "assistant"):
        tail.pop(0)
    return head + tail


def scrape():
    out = {}
    with urllib.request.urlopen(a.metrics, timeout=30) as r:
        for line in r.read().decode("utf-8", "replace").splitlines():
            m = re.match(r"^(vllm:spec_decode_num_\w+?)_total\{[^}]*\}\s+(\S+)$", line)
            if m:
                out[m.group(1)] = float(m.group(2))
    return out


def nvme_mib():
    for line in open("/proc/diskstats"):
        p = line.split()
        if p[2] == "nvme0n1":
            return int(p[5]) * 512 / 2**20
    return 0.0


def mem():
    v = {}
    for line in open("/proc/meminfo"):
        k, x = line.split(":")
        v[k] = int(x.split()[0]) / 2**20
    return {"free_gib": round(v["MemFree"], 2), "cache_gib": round(v["Cached"], 2), "avail_gib": round(v["MemAvailable"], 2)}


def stream(p):
    req = urllib.request.Request(a.url, data=json.dumps(p).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time()
    ttft = None
    usage = {}
    parts = []
    finish = None
    with urllib.request.urlopen(req, timeout=3600) as r:
        for line in r:
            line = line.strip()
            if not line.startswith(b"data: ") or line == b"data: [DONE]":
                continue
            d = json.loads(line[6:])
            if d.get("usage"):
                usage = d["usage"]
            for c in d.get("choices", []):
                dl = c.get("delta", {})
                finish = c.get("finish_reason") or finish
                piece = dl.get("content") or dl.get("reasoning_content") or dl.get("reasoning")
                if dl.get("tool_calls"):
                    piece = (piece or "") + json.dumps(dl["tool_calls"])
                if piece:
                    parts.append(piece)
                    if ttft is None:
                        ttft = time.time()
    t1 = time.time()
    gen = usage.get("completion_tokens", 0)
    dec = t1 - ttft if ttft and gen > 1 and t1 > ttft else 0.0
    return {"ttft": round((ttft or t1) - t0, 2), "gen": gen, "decode_tps": round((gen - 1) / dec, 2) if dec else None,
            "prompt": usage.get("prompt_tokens"), "s": round(t1 - t0, 2), "dec_s": dec, "finish": finish, "text": "".join(parts)}


def run(p):
    b, n0 = scrape(), nvme_mib()
    try:
        r = stream(p)
    except Exception as e:  # keep going: one bad session must not end the test
        return {"err": repr(e)[:200]}
    time.sleep(0.5)
    af, n1 = scrape(), nvme_mib()
    d = {k: af.get(k, 0.0) - b.get(k, 0.0) for k in KEYS}
    steps = d[KEYS[0]]
    dec = r.pop("dec_s")
    text = r.pop("text")
    r["sha"] = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:12]
    r["text_full"] = text
    r.update(steps=steps, ms_step=round(dec * 1000 / steps, 1) if steps else None,
             tok_step=round(1 + d[KEYS[1]] / steps, 3) if steps else None,
             draft_tok_step=round(d[KEYS[2]] / steps, 3) if steps else None,
             nvme_mib=round(n1 - n0), mib_step=round((n1 - n0) / steps, 1) if steps else None, **mem())
    return r


best = {}
for f in sorted(glob.glob(os.path.join(a.dir, "request_dump_*.json"))):
    try:
        sid, b = body_of(f)
    except Exception:
        continue
    if b.get("messages"):
        best[sid] = b
k, n = map(int, a.shard.split("/"))
shard = [x for i, x in enumerate(best.items()) if i % n == k]
items = (shard[:: max(1, len(shard) // a.limit)] if a.spread else shard)[: a.limit or None]


def payload(b, tokens, ignore_eos=True):
    p = {"model": a.model, "max_tokens": tokens, "stream": True,
         "stream_options": {"include_usage": True},
         "messages": trim(b["messages"], a.max_chars - len(json.dumps(b.get("tools") or [])))}
    if a.sampling == "greedy":
        p.update(temperature=0.0, ignore_eos=ignore_eos)
    if b.get("tools"):
        p["tools"] = b["tools"]
    return p


if a.mode == "dry":
    print("sessions", len(best), "shard", len(shard), "picked", len(items))
    for sid, b in items:
        print(sid, len(json.dumps(payload(b, 1))))
    raise SystemExit(0)

rows = []
log = open(a.out, "a")
textlog = open(a.text_out, "a") if a.text_out else None


def note(rec):
    text = rec.pop("text_full", None)
    if textlog and text is not None:
        textlog.write(json.dumps({"sid": rec.get("sid"), "pass": rec.get("pass", rec.get("phase")), "sha": rec.get("sha"), "text": text}) + "\n")
        textlog.flush()
    rows.append(rec)
    log.write(json.dumps(rec) + "\n")
    log.flush()
    print(rec, flush=True)


if a.mode == "measure":
    for sid, b in items:
        for ps in range(1, a.passes + 1):
            note({"sid": sid, "pass": ps, **run(payload(b, a.tokens))})
        if a.real_pass:
            note({"sid": sid, "pass": "real", **run(payload(b, a.tokens, ignore_eos=False))})
    for ps in [*range(1, a.passes + 1), *(["real"] if a.real_pass else [])]:
        s = [r for r in rows if r["pass"] == ps and r.get("steps")]
        if s:
            print("SUMMARY", json.dumps({"pass": ps, "n": len(s),
                  "tok_s_med": round(st.median(r["decode_tps"] for r in s), 2),
                  "ms_step": round(st.mean(r["ms_step"] for r in s), 1),
                  "tok_step": round(st.mean(r["tok_step"] for r in s), 3),
                  "mib_step": round(st.mean(r["mib_step"] for r in s), 1),
                  "ttft_med": round(st.median(r["ttft"] for r in s), 2)}), flush=True)
else:
    for sid, b in items:
        note({"sid": sid, "phase": "fill", **run(payload(b, 1))})
    os.remove(a.pause_file)
    time.sleep(2)
    for sid, b in items:
        note({"sid": sid, "phase": "decode", **run(payload(b, a.tokens))})
    s = [r for r in rows if r.get("phase") == "decode" and r.get("steps")]
    print("SUMMARY", json.dumps({"n": len(s), "gen": sum(r["gen"] for r in s),
          "ttft_med": round(st.median(r["ttft"] for r in s), 2), "tok_s_med": round(st.median(r["decode_tps"] for r in s), 2),
          "errors": sum(1 for r in rows if r.get("err"))}), flush=True)
