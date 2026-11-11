# Dependency boundary

This repository holds a route record, a setup script, one patch, a test script, a keep-alive forwarder, commands and measurements. It doesn't vendor the recipe, the engine or the weights. `run.sh` fetches those from their authors, pinned by commit, revision and SHA-256.

## What this builds on

- Recipe: https://github.com/vcruz305/DSV4.1-Flash-1017-EXL3-Spark-recipe, commit `8036aa7`, by Victor Cruz (vcruz305). MIT.
- REXL3 path, reserve planner, traffic-picked cold set: AgentSparko, upstreamed into that recipe.
- Weights: https://huggingface.co/vcruz305/DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw, by Victor Cruz, from DeepSeek-V4.1-Flash-1017 by DeepSeek. Gated, under their own licenses.
- Engine: https://github.com/christopherowen/spark-ds41f on justincasey's base recipe, https://github.com/vcruz305/exllamav3, ExLlamaV3 by turboderp, and vLLM.

## What is here

- `run.sh`: new. Its shared second half is the same in every sxuff recipe repository.
- `patches/01-prompt-tokens-details.patch`: a two-line change to the recipe's `packs/1.55bpw-rexl3/scripts/serve_inner.sh` and `serve.sh`, Copyright (c) 2026 Victor Cruz, MIT.
- `scripts/sse_keepalive_proxy.py`: new, standard library only.
- `scripts/agent_steps.py`: new test script. Its session selection and trimming follow upstream's `bench/hermes_decode.py`, Copyright (c) 2026 Victor Cruz, MIT.
- `configs/route-heat-decode-rexl3-1.55bpw.npz`: per-expert route counts from 18 Hermes sessions, in upstream's record format. It holds counts and a timestamp, no prompts or generated text.
- `results/`: numbers from the tests, with session ids and generated text removed.
