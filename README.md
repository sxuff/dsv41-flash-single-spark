# DeepSeek V4.1 Flash on one NVIDIA GB10

## Run it

```bash
git clone https://github.com/sxuff/dsv41-flash-single-spark && cd dsv41-flash-single-spark && ./run.sh
```

Expected: **22.0 and 20.5 tok/s** on real agent requests at the server's 0.6 / 0.95 sampling, **802 and 700 tok/s** prefill on real 20K to 30K prompts (two boots) — receipt: [`results/dsv41-gx10-20261106.json`](results/dsv41-gx10-20261106.json), runs `s-k5a` and `s-k5b`

Needs one GB10, about 400 GB free disk, passwordless `sudo -n` (upstream sets memory sysctls and runs docker with it), docker usable without sudo, and `numpy` for the host `python3`. `./run.sh --check` prints every step and changes nothing; `./run.sh --stop` stops the server and restores the host settings. The API is OpenAI-compatible on `http://127.0.0.1:8000/v1`, model `dsv41`.

[Victor Cruz's recipe](https://github.com/vcruz305/DSV4.1-Flash-1017-EXL3-Spark-recipe) for DeepSeek-V4.1-Flash-1017 (SAGE REXL3, 1.55 bpw, served by vLLM) with one change: the experts it reads from the SSD are picked from decode traffic only. On an ASUS Ascent GX10 with 5 GiB of RAM kept free, that gives about **21 tok/s** on real agent requests and **700 to 800 tok/s** prefill on real 20K to 30K prompts.

Everything else is the upstream recipe. This repository holds the route record, `run.sh`, one small patch, a keep-alive forwarder for agent clients, the test script and the receipts. It does not vendor upstream.

## What changes

The model doesn't fit in memory, so upstream reads its least-used experts from the SSD. Which experts go there decides the speed. Upstream picks them from a record of your traffic, counted per token. A long prompt has far more tokens than the answer that follows it, so a record can end up mostly describing prefill.

[`configs/route-heat-decode-rexl3-1.55bpw.npz`](configs/route-heat-decode-rexl3-1.55bpw.npz) was recorded with the prompt excluded: the prefix cache was filled with the record paused, then the record ran while 18 agent sessions decoded.

The comparison below is against a record made from bench7, a prefill probe and 24 replayed sessions. It is not against upstream's shipped set, which doesn't fit on this box at boot, or a record from weeks of real traffic.

## Measured

All at `k=5`, `RESERVE_GIB=5` (about 12.5 GiB of experts on the SSD). Agent figures come from 6 Hermes sessions the record never saw: 20K to 30K prompt tokens, capped at 384 generated tokens.

| | Record with prefill routes | Decode-only record |
|---|---:|---:|
| Real-prompt prefill | 394 and 457 tok/s (2 boots) | **655 to 802 tok/s** (5 boots) |
| First token, cold 20K to 30K prompt | 55 and 49 s | **29 to 37 s** |
| First token, prefix cached | 2.3 and 1.8 s | 1.1 to 1.5 s |
| Agent decode, cached prompt, temperature 0 | 19.2 and 19.1 tok/s | 22.1 to 26.0 tok/s (3 boots) |
| Agent decode, cached prompt, server sampling 0.6 / 0.95 | not measured | **22.0 and 20.5 tok/s** (2 boots) |
| Bench7, temperature 0 | 30.5 (2 reps) and 23.0 tok/s | 28.2 and 23.1 tok/s |
| Synthetic prefill, about 2K prompt | 210 tok/s | 149 to 191 tok/s |

Hermes sends no temperature, so the 0.6 / 0.95 row is what agent clients get.

There is no same-session comparison of the two records. The prefill gain looks real: it is large, and SSD reads per prompt token fell about 40% (0.86 to 0.46-0.58 MiB). The decode gain is less certain: only part of it comes from shorter steps, and the rest is more tokens per step, which the SSD set shouldn't change.

Upstream's closest figures, on its author's box and sessions: 23.5 to 25.7 tok/s on Hermes sessions at temperature 0; 17.7 to 22.5 tok/s on chat replies at 0.6 / 0.95, on its 1.62 bpw pack; and on 2K prompts, 494 to 500 tok/s with its SSD set cached and 214 with its reserve in use. Its README's 30.3 tok/s on Hermes has no backing in its testing doc and was not reproduced here.

### Context and quality

Measured on the record with prefill routes, not re-run on the decode-only set. The weights are identical; only their location changes.

| Prompt | Prefill | Code planted in the prompt |
|---:|---:|---|
| 32K | 756 tok/s | found |
| 131K | 934 tok/s | found |
| 262K | 949 tok/s | found |
| 520K | 890 tok/s | found |
| 999K (`MAXLEN=1048576 KVB=1342177280`) | 776 tok/s | found, 21.5 min fill, 2.87 GiB lowest free memory |

GSM8K 196/200 (98.0%) and HumanEval 159/164 (96.95%), greedy, through the served API. The question sets came from local copies and may differ from upstream's.

### What did not help

| Change | Result |
|---|---|
| `k=3`, `k=4` | Not better than the default `k=5`. At 0.6 / 0.95: `k=3` 19.2 tok/s against 22.0 and 20.5. At temperature 0: `k=3` 21.7, `k=4` 21.6, `k=5` 22.6. These gaps are about the size of the noise. |
| `k=7` | Slower on the older record: 17.0 against 18.4 tok/s, one boot each. |
| `VLLM_EXL3_ATS_HUGEPAGE=1` | Worse. Real-prompt prefill 711 to 406 tok/s, SSD reads per step up 2.5 times, bench7 28.2 to 17.6 tok/s. `thp_file_alloc` stayed 0, so no file hugepages were used, and cold data held in memory fell to 0.5-0.9 GiB. Only short synthetic prompts gained. |
| `VLLM_EXL3_ATS_PREFETCH=0` | No proven effect. One run looked better and the repeat did not. |
| `MNBT=4224 LPT=4218` | No real prefill gain. |

Upstream's `serve.sh` hard-codes the prefetch setting and doesn't pass the hugepage one. To repeat those two rows, change its line 293 to:

```bash
  -e VLLM_EXL3_ATS_PREFETCH="${ATS_PREFETCH:-1}" -e VLLM_EXL3_ATS_HUGEPAGE="${ATS_HUGEPAGE:-0}" \
```

Not tried: leaving background compaction on, and prefetching the next layer's experts. A smaller reserve would put fewer experts on the SSD, but this box can't go to 0: upstream's shipped 8.4 GiB set was killed at the 0.5 GiB memory guard while booting.

### How far to trust these

- **Decode numbers are noisy.** The engine is not bit-deterministic, as upstream documents. Identical temperature-0 requests gave the same text in 2 of 36 comparisons, bench7 ranged 23.0 to 30.5 tok/s on one configuration (the 30.5 used two reps, the 23.0 one), and two boots of one setting differed by 8%. Don't compare single runs; pool requests across boots.
- **One box, few sessions.** Everything ran on one GX10 with 114 GiB free before boot (the recipe calibrates at 116.6) and with the desktop and Hermes running. Only 6 sessions were measured.
- **Test conditions differ from upstream.** This box has no passwordless sudo, so the memory sysctls were set by hand, the guard ran as a normal user, swap stayed on (unused), and the page cache was not dropped between boots.
- **Long agent sessions refill slower.** When a client's history changed near its start, refills of about 225K tokens ran at 230 to 260 tok/s, well below the prefill above. Not investigated.

Receipts: [per-run summary](results/dsv41-gx10-20261106.json) · [all 228 agent requests](results/dsv41-gx10-20261106-requests.jsonl). Session ids and generated text are not included.

## Agent clients

Found while running it behind DeepSeek Harness and Hermes for two days:

- **Cache hits show as 0%.** vLLM only reports cached prompt tokens when started with `--enable-prompt-tokens-details`; without it, `prompt_tokens_details` is `null` and clients show no cache hits even though the prefix cache works (38.2M of 39.4M prompt tokens were cached). [`patches/01-prompt-tokens-details.patch`](patches/01-prompt-tokens-details.patch) adds the flag to upstream's serve command, and `run.sh` applies it. It only changes what the API reports.
- **Long tool calls get cut at 5 minutes.** The `deepseek_v41` tool parser sends a call's name, then nothing until the call closes. A tool call longer than about 7K tokens is silent for over 300 s, and Node clients (undici's default body timeout) drop it as `terminated` on every retry. [`scripts/sse_keepalive_proxy.py`](scripts/sse_keepalive_proxy.py) sits in front of the API and sends an SSE comment after 15 s of silence, only between events. Point the client at it:

  ```bash
  python3 scripts/sse_keepalive_proxy.py --listen 127.0.0.1:8002 --upstream 127.0.0.1:8000
  ```

  Measured through it with Node's `fetch`: 365 s without data, 24 comments, all 6,000 lines of the tool call intact. It also works as a systemd socket-activated service (it takes fd 3 when `LISTEN_FDS` is set).
- **Reasoning loops past about 160K tokens.** All 8 loops seen started at 159K to 181K tokens of context, none below, though most steps above 150K were fine. Exact repeats end early with `finish_reason: "repetition"` (upstream's `REP_STOP`, on by default); looser ones run to the 32,768-token cap, about 20 minutes. Compact or start a new session before 150K. In DeepSeek Harness, a `contextWindow` of `239616` with `maxTokens: 32768` makes its default rule compact at 141,312 tokens; don't lower it on a session already past that, or its output cap drops to 1 token.
- **Image-heavy sessions refill from the start.** DeepSeek Harness drops a request's oldest images once they pass `maxRequestImageBytes` (20 MiB by default). That changes the prompt near its start, so only the first ~20K tokens stay cached.

## What run.sh does

1. Checks the machine: GB10, tools, free memory, port, disk, passwordless `sudo -n`, docker without sudo, host `numpy`.
2. Clones upstream at `8036aa7` into `~/src/dsv41-recipe-8036aa741e2c` and applies patch 01.
3. Builds upstream's image with `scripts/build_image.sh` if it's missing. It first fetches upstream's 8.8 GB base image archive at its pinned revision with curl and checks upstream's SHA-256, so the host doesn't need `huggingface_hub`.
4. Downloads the 1.55 bpw pack at revision `c40cf25` (27 files, 320 GB) to `~/models/DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw` and checks every file's SHA-256. `HF_TOKEN` is optional: neither repository was gated on 2026-11-11.
5. Builds upstream's REXL3 overlay at `~/models/rexl3-vic-overlay` (about 5.7 GiB more; the GPU must be free).
6. Builds the SSD expert set from the decode record at `RESERVE_GIB=5` into `~/.cache/dsv41-ds41f/alias-decode`. The planner sizes it from the memory free at that moment, so run it with your usual apps open. It's rebuilt when `RESERVE_GIB` changes; delete `alias-decode/.decode-set` to rebuild it for another reason.
7. Serves with upstream's `serve.sh` and waits for the API. `serve.sh` sets the host memory sysctls and arms upstream's memory guard; `./run.sh --stop` runs upstream's `guard.sh stop`, which removes the container and restores the sysctls.

Finished steps are skipped on the next run. Boot takes about 4 minutes. On the first boot the JIT cache is cold and upstream compiles with one worker; once it's ready, `./run.sh --stop && ./run.sh` serves with upstream's measured worker settings. `VISION_IMAGES=N ./run.sh` accepts up to N images per prompt (upstream's default is 1).

If the reserve fits with upstream's shipped SSD set on your box, the planner keeps the shipped set and this record isn't used. On the GX10 the set had to be 12.5 GiB against the shipped 8.4.

`run.sh` was checked with `--check` on the GX10 behind these numbers, with its download URLs, pins and patch verified there. That box has no passwordless sudo, so `run.sh` hasn't run end to end on it; the measured boots ran the same upstream commands by hand, below.

### By hand

```bash
git clone https://github.com/vcruz305/DSV4.1-Flash-1017-EXL3-Spark-recipe.git
cd DSV4.1-Flash-1017-EXL3-Spark-recipe
git checkout 8036aa7
git apply /path/to/this/repo/patches/01-prompt-tokens-details.patch   # optional, see "Agent clients"
bash scripts/build_image.sh
HF_XET_HIGH_PERFORMANCE=1 hf download vcruz305/DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw --revision c40cf25cc3148bae95ac27483505c883840bf8a7 \
  --local-dir ~/models/DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw
bash packs/1.55bpw-rexl3/scripts/build_rexl3_overlay.sh
```

Build the SSD set from the decode record, with the GPU free and your usual apps running. It sizes the set from the memory free right now and from the engine's use on upstream's calibration (1 GiB KV pool, `MAXLEN=524288`, vision on), so rebuild it if any of those change. Change `--reserve-gib` to keep more or less RAM free:

```bash
export ALIAS_DIR=~/.cache/dsv41-ds41f/alias-decode MODEL_NAME=rexl3-vic-overlay MODEL_DIR=~/models/rexl3-vic-overlay
python3 packs/1.55bpw-rexl3/tools/plan_reserve.py --reserve-gib 5 \
  --npz /path/to/this/repo/configs/route-heat-decode-rexl3-1.55bpw.npz \
  --model-name "$MODEL_NAME" --model-dir "$MODEL_DIR" --out "$ALIAS_DIR" --build
```

Serve it. `AUTO_COLD=0` matters: without it, upstream re-picks the set from your traffic at each restart and can replace this one.

```bash
COLD_SELECTION="$ALIAS_DIR/selection.json" ALIAS_DIR="$ALIAS_DIR" MODEL_NAME="$MODEL_NAME" \
  HF_OVERRIDES_JSON="$(python3 packs/1.55bpw-rexl3/tools/rexl3_overrides.py)" \
  ROUTE_STATS=1 DYN_RESIDENCY=1 DYN_RESIDENCY_MAX_SWAPS=0 AUTO_COLD=0 \
  bash packs/1.55bpw-rexl3/scripts/serve.sh
bash scripts/smoke.sh
```

For 1M context add `MAXLEN=1048576 KVB=1342177280` to the serve command; the 1M test kept the set built for the default KV pool.

### Record your own traffic (optional)

[`scripts/agent_steps.py`](scripts/agent_steps.py) reads Hermes `request_dump_*.json` files from `~/.hermes/sessions`. Serve as above with a separate record that starts paused:

```bash
HEAT=~/.cache/dsv41-ds41f/route-heat-decode
mkdir -p "$HEAT" && touch "$HEAT/pause"
# serve as above, adding DYN_RESIDENCY_STATE_DIR="$HEAT"
python3 /path/to/this/repo/scripts/agent_steps.py --mode record --shard 0/2 --limit 24 --spread \
  --tokens 640 --max-chars 120000 --pause-file "$HEAT/pause" --out record.jsonl
touch "$HEAT/flush.now"    # wait for this file to disappear, then stop the server
bash scripts/guard.sh stop && docker rm -f dsv41-tp1
```

Then build the set again with `--npz "$HEAT/route-heat-rexl3-vic-overlay.npz"`.

### Measure

The same test used here, on the sessions the record left out:

```bash
python3 /path/to/this/repo/scripts/agent_steps.py --mode measure --sampling server --shard 1/2 --limit 6 \
  --tokens 384 --passes 4 --out agent.jsonl
```

It prints tok/s, ms per step, tokens per step and SSD reads. Add `--text-out` to also save the generated text. Pool across requests and boots rather than reading one median.

## Credits

See [NOTICE.md](NOTICE.md). The recipe, packs and engine work belong to their authors; this repository adds the decode-only record and these measurements.
