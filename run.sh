#!/usr/bin/env bash
# run.sh - one-command setup and launch for this recipe on one NVIDIA GB10.
#
#   git clone https://github.com/sxuff/dsv41-flash-single-gb10 && cd dsv41-flash-single-gb10 && ./run.sh
#
# Every pin and flag below is copied from this repo's README, patches or
# receipts, or from upstream at the pinned commit; the comment next to each value
# names its source. Nothing here tunes, "improves" or changes a measured setting.
set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

# ===================== recipe config (per repo) =============================
RECIPE_NAME="dsv41-flash-single-gb10"
PORT="${PORT:-8000}"                             # upstream scripts/env.sh API_PORT (default 8000); serve.sh publishes it with docker -p
MODELS_DIR="${MODELS_DIR:-$HOME/models}"         # upstream scripts/env.sh MODELS_DIR
SRC_DIR="${SRC_DIR:-$HOME/src}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/dsv41-flash-single-gb10}"
NEEDS_TOOLS="git curl sha256sum docker python3 nvidia-smi ss numfmt zstd sudo"   # zstd: upstream scripts/fetch_base.sh
# Not an upstream number: the measured boots started with 113.7 to 114 GiB available (README "How far to
# trust these"), and below 100 GiB the planner would put far more experts on the SSD than was measured.
NEED_MEM_BYTES=$(( 100 * 1073741824 ))
ENGINE_KIND=docker
CONTAINER_NAME="dsv41-tp1"                       # upstream scripts/env.sh CONTAINER
READY_URL="http://127.0.0.1:${PORT}/v1/models"
READY_TIMEOUT=3600                               # upstream serve.sh passes VLLM_ENGINE_READY_TIMEOUT_S=3600; a boot took about 4 min here (README "Recipe")
EXPECTED_LINE="22.0 and 20.5 tok/s on real agent requests at the server's 0.6 / 0.95 sampling, 802 and 700 tok/s prefill on real 20K to 30K prompts (two boots, runs s-k5a and s-k5b)"
RECEIPT_PATH="results/dsv41-gx10-20261106.json"

# Upstream recipe at the commit tested here (README "Recipe"), plus patches/01, which adds
# --enable-prompt-tokens-details to the vLLM command so clients see cached prompt tokens (README "Agent clients").
UP_URL="https://github.com/vcruz305/DSV4.1-Flash-1017-EXL3-Spark-recipe"
UP_COMMIT="8036aa741e2c2328035ed546f1f844b6797775f6"
UP_DIR="$SRC_DIR/dsv41-recipe-${UP_COMMIT:0:12}"
PATCHES="
96b86933d3fba11d223929d2b259c8ac15930c6af5f8a0a3d1ba6d82c85a0b91 01-prompt-tokens-details.patch
"

# Serving image, built by upstream's scripts/build_image.sh on top of its base image. Names, base archive pins and
# BASE_DL_DIR: upstream scripts/env.sh at UP_COMMIT. Archive size: the Hugging Face tree at BASE_HF_REV.
IMAGE="dsv41-1017-exl3:r6w"
BASE_IMAGE="dsv41-1017-ds41f:r6w"
BASE_HF_REPO="vcruz305/DSV4.1-Flash-1017-Spark-base-image"
BASE_HF_REV="17ed433666f4cc6dfa86bcc1d3f4448255fd58fb"
BASE_ARCHIVE="dsv41-1017-ds41f-r6w-redist.tar.zst"
BASE_ARCHIVE_SHA256="97d31344b0e5f8e17bf69e05d679a25b3256a452a7275bc294eb6bd149f58e9a"
BASE_ARCHIVE_BYTES=8779929450
BASE_DL_DIR="${BASE_DL_DIR:-$HOME/.cache/dsv41-base-image}"
IMAGE_BYTES=23500363557                          # docker image inspect .Size of $IMAGE as built on the GX10 (base layers included)

# The 1.55 bpw REXL3 pack, the overlay that makes it loadable, and the SSD expert set built from this repo's record.
P_REPO="vcruz305/DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw"
P_REV="c40cf25cc3148bae95ac27483505c883840bf8a7"   # the revision downloaded and measured here (its .cache/huggingface metadata)
PACK_NAME="DSV4.1-Flash-1017-SAGE-REXL3-1.55bpw"   # upstream build_rexl3_overlay.sh default source dir
OVERLAY_NAME="rexl3-vic-overlay"                    # upstream build_rexl3_overlay.sh default overlay dir, served as MODEL_NAME
OVERLAY_BYTES=$(( 57 * 1073741824 / 10 ))           # upstream pack README: "+5.7 GiB of disk"
RESERVE_GIB="${RESERVE_GIB:-5}"                     # measured value (README "Measured")
ALIAS_DIR="${DSV41_DECODE_ALIAS_DIR:-$HOME/.cache/dsv41-ds41f/alias-decode}"   # kept apart from upstream's alias-cold
ALIAS_MAX_BYTES=$(( 15 * 1073741824 ))              # upstream plan_reserve.py --max-cold-gib default (15 GiB)
DECODE_NPZ="configs/route-heat-decode-rexl3-1.55bpw.npz"
DECODE_NPZ_SHA256="73328dd4065c2f0733936ab3df84d9d04950df8e0a461fb511a88d3a88731e7c"

# Disk this script may still need besides the weights: the image (and its base archive) if missing,
# the overlay's two converted files, and the SSD expert set at its largest.
ENGINE_DISK_BYTES=0
docker image inspect "$IMAGE" >/dev/null 2>&1 || ENGINE_DISK_BYTES=$(( IMAGE_BYTES + BASE_ARCHIVE_BYTES ))
[ -f "$MODELS_DIR/$OVERLAY_NAME/nonrouted-fp8.safetensors" ] || ENGINE_DISK_BYTES=$(( ENGINE_DISK_BYTES + OVERLAY_BYTES ))
[ -f "$ALIAS_DIR/experts.bin" ] || ENGINE_DISK_BYTES=$(( ENGINE_DISK_BYTES + ALIAS_MAX_BYTES ))

# Pinned pack: 27 files, 320,275,901,289 bytes. LFS files: SHA-256 from the Hub's LFS metadata at P_REV.
# The 8 small files: hashed from the copies downloaded at P_REV (their git blob IDs match the Hub tree).
# Columns: sha256 bytes repo revision path dest.
WEIGHTS="
f90bfdfb68634ca7fca6ab0e2fa09742601f1f11477b0c6cc67ae278c86ae02d 1641 $P_REPO $P_REV .gitattributes $PACK_NAME/.gitattributes
f2c6c602815669d292889e5be8c802f2ed950653b77999b1584e8e6aed25d040 1084 $P_REPO $P_REV LICENSE $PACK_NAME/LICENSE
38e2b4fd19d61a0419b8b2ec584b4dd91eff3d644c49ace241251fe73a15db06 4394 $P_REPO $P_REV README.md $PACK_NAME/README.md
adaa16cddf2ed5415bb2518e72b514b9c8dbb750bcb8aa0b6a0de9c8e6b616b9 4015 $P_REPO $P_REV chat_template.jinja $PACK_NAME/chat_template.jinja
25882944c203b1970a9187dc47334ebafbb7e95ffda888fd86c8181af9e15867 3170 $P_REPO $P_REV config.json $PACK_NAME/config.json
c60a86322ec17b4142bfef3c57a8d81fb428550cdf487f88a4320cb59fe46481 517120 $P_REPO $P_REV engram_token_map.u32 $PACK_NAME/engram_token_map.u32
96a22d3ec2d7c13d94641a2446a75ff0403f23d91f748f3e12e109aa0c9c2b7b 191 $P_REPO $P_REV generation_config.json $PACK_NAME/generation_config.json
3325699ab4f884be2a9b21df2ae808f07620ac2551857a146917fd61d08d9ac3 8435709676 $P_REPO $P_REV model-00001-of-00017.safetensors $PACK_NAME/model-00001-of-00017.safetensors
a9bb7a4a945a0f2415bbd987cee74debe65b50b48c58ec241e748ea5020a4566 8497805052 $P_REPO $P_REV model-00002-of-00017.safetensors $PACK_NAME/model-00002-of-00017.safetensors
2195e269b88ae8199413d125bc74de59925edb68679b184f2aff193af00043c6 8499766344 $P_REPO $P_REV model-00003-of-00017.safetensors $PACK_NAME/model-00003-of-00017.safetensors
7e4cdeebf47ad56ec5914d780a5c57e8b9734a750284d6eb0a492b604b541eda 8498337912 $P_REPO $P_REV model-00004-of-00017.safetensors $PACK_NAME/model-00004-of-00017.safetensors
696f0c282862957c84dfb603523a625e017c585dd1d1b606241e3af87e318da0 8495729900 $P_REPO $P_REV model-00005-of-00017.safetensors $PACK_NAME/model-00005-of-00017.safetensors
2278cca353412de31b1bd3e84a772e0012e543ebc51f9c1024c6f1e621565b8b 8492707804 $P_REPO $P_REV model-00006-of-00017.safetensors $PACK_NAME/model-00006-of-00017.safetensors
959a17fbd2f5d5e6e72d0f03ea886fbde9f460ee824c46d5eb48647ce536f7e5 8499856352 $P_REPO $P_REV model-00007-of-00017.safetensors $PACK_NAME/model-00007-of-00017.safetensors
2f46bf6aee9d609f8d24412c01806801df26a0448d61afff1cc461fd62f61f5f 8499942840 $P_REPO $P_REV model-00008-of-00017.safetensors $PACK_NAME/model-00008-of-00017.safetensors
4e8e2c63668d1852c4cc54c074ab7253e1e5eae23e76109c288590afb04027a1 8497457720 $P_REPO $P_REV model-00009-of-00017.safetensors $PACK_NAME/model-00009-of-00017.safetensors
5fd6175054f5ab2066ce23ae795a983839b16b16d9040e104fffcd7b80ac9728 8499019352 $P_REPO $P_REV model-00010-of-00017.safetensors $PACK_NAME/model-00010-of-00017.safetensors
9a02cefb9fd6837d005ac4dd6ce14195a21d97149e0f70d9b0c791face393208 8498785524 $P_REPO $P_REV model-00011-of-00017.safetensors $PACK_NAME/model-00011-of-00017.safetensors
ac192e11610d8b260447b53a7d23471694f32aae03eab47414bfbc8081c895e9 8498632912 $P_REPO $P_REV model-00012-of-00017.safetensors $PACK_NAME/model-00012-of-00017.safetensors
bbafc2f600a94dd8968fd9d9820c11e9039524def5d5d9aab939f82d16efc4bc 8496560936 $P_REPO $P_REV model-00013-of-00017.safetensors $PACK_NAME/model-00013-of-00017.safetensors
0e09567a49f109c43d97621923253103f49fba4d04e3b95ccc50e34f2b1131f0 4205339304 $P_REPO $P_REV model-00014-of-00017.safetensors $PACK_NAME/model-00014-of-00017.safetensors
66e3f88eba871acd9df219c7d96b241cc1dd7ec600852804a06a7716027642f9 2565653752 $P_REPO $P_REV model-00015-of-00017.safetensors $PACK_NAME/model-00015-of-00017.safetensors
76a05106ece259be83d1bfea0dcb54f23377864ee60fd321690f35e6698a2af5 101535150936 $P_REPO $P_REV model-00016-of-00017.safetensors $PACK_NAME/model-00016-of-00017.safetensors
9dc51433e195bc78b5ad846b68643cc0351d3b174e5e4309222d3b7402c83afd 101537926640 $P_REPO $P_REV model-00017-of-00017.safetensors $PACK_NAME/model-00017-of-00017.safetensors
aca1776829a6754f9d9d3434a862a6a0728aec6c04f1abcf238991ad53a623f4 14618660 $P_REPO $P_REV model.safetensors.index.json $PACK_NAME/model.safetensors.index.json
c90dfa01249db1be4245780a052ede752e1361c612ac6d08e2bdada7d599476b 6367257 $P_REPO $P_REV tokenizer.json $PACK_NAME/tokenizer.json
6ac8c8dc065ed118161d02dd532749ae3f52c243deac27872134fae2f50d8547 801 $P_REPO $P_REV tokenizer_config.json $PACK_NAME/tokenizer_config.json
"

engine_step() {
  # 0) what upstream needs beyond the shared checks (upstream README "Quick start" and TESTING-AND-RESULTS.md)
  if sudo -n true 2>/dev/null; then ok "passwordless sudo -n (upstream runs docker, sysctl, swapoff and drop_caches with it)"
  else fail "upstream's scripts need passwordless sudo -n for docker, sysctl, swapoff/swapon and tee /proc/sys/vm/drop_caches"; fi
  if docker ps >/dev/null 2>&1; then ok "docker works without sudo (this script watches the container with it)"
  else fail "docker ps must work without sudo: add yourself to the docker group, then log in again"; fi
  if python3 -c 'import numpy' 2>/dev/null; then ok "host python3 has numpy (upstream's SSD-set builder)"
  else fail "host python3 needs numpy for upstream's SSD-set builder (Ubuntu: sudo apt-get install -y python3-numpy)"; fi

  # 1) upstream at the pinned commit; every patch checked by SHA-256, then applied in order
  local mark="$UP_DIR/.dsv41-patches-applied" want sha name
  want="$(printf '%s\n' "$PATCHES" | sed '/^$/d' | sha256sum | cut -d' ' -f1)"
  while read -r sha name; do
    [ -z "${sha:-}" ] && continue
    [ "$(sha256sum "$REPO_DIR/patches/$name" | cut -d' ' -f1)" = "$sha" ] || die "patches/$name SHA-256 differs from its pin"
  done <<< "$PATCHES"
  ok "patch SHA-256 matches its pin (01)"
  if [ -f "$mark" ] && [ "$(cat "$mark")" = "$UP_COMMIT $want" ]; then ok "upstream ${UP_COMMIT:0:12} + patches: $UP_DIR"
  elif [ "$CHECK" = 1 ]; then plan "clone $UP_URL to $UP_DIR, check out ${UP_COMMIT:0:12}, git apply patch 01"
  else
    [ ! -e "$UP_DIR" ] || die "$UP_DIR exists but is not a finished patched tree; move it away and re-run"
    mkdir -p "$SRC_DIR"; git_pin "$UP_URL" "$UP_COMMIT" "$UP_DIR"
    while read -r sha name; do
      [ -z "${sha:-}" ] && continue
      git -C "$UP_DIR" apply "$REPO_DIR/patches/$name"
    done <<< "$PATCHES"
    echo "$UP_COMMIT $want" > "$mark"; ok "patched: $UP_DIR"
  fi

  # 2) the serving image, built by upstream (README "Recipe": bash scripts/build_image.sh)
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then ok "image present: $IMAGE"; return; fi
  if [ "$CHECK" = 1 ]; then
    docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 ||
      plan "download $BASE_HF_REPO@${BASE_HF_REV:0:12} $BASE_ARCHIVE ($(human "$BASE_ARCHIVE_BYTES")) to $BASE_DL_DIR and check its SHA-256"
    plan "build $IMAGE with upstream scripts/build_image.sh (about 10 min)"
    return
  fi
  if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    # Fetched here with curl so upstream's fetch_base.sh finds it verified and needs no host huggingface_hub.
    local f="$BASE_DL_DIR/$BASE_ARCHIVE"
    if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" != "$BASE_ARCHIVE_BYTES" ]; then
      mkdir -p "$BASE_DL_DIR"; printf '    get   %s (%s)\n' "$BASE_ARCHIVE" "$(human "$BASE_ARCHIVE_BYTES")"
      { [ -n "${HF_TOKEN:-}" ] && printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN"; true; } |
        curl --fail --location --retry 5 --retry-delay 5 --continue-at - --config - \
             --output "$f.part" "https://huggingface.co/$BASE_HF_REPO/resolve/$BASE_HF_REV/$BASE_ARCHIVE"
      mv "$f.part" "$f"
    fi
    if ! echo "$BASE_ARCHIVE_SHA256  $f" | sha256sum -c --status; then
      mv "$f" "$f.sha256-mismatch"; die "SHA-256 mismatch for $f (kept as $f.sha256-mismatch)"
    fi
    ok "sha256 ok: $BASE_ARCHIVE"
  fi
  ( cd "$UP_DIR" && BASE_DL_DIR="$BASE_DL_DIR" bash scripts/build_image.sh )
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "build_image.sh did not produce $IMAGE"
  ok "image built: $IMAGE"
}

serve_step() {   # README "Recipe": overlay, SSD set from the decode-only record, then upstream's serve.sh with AUTO_COLD=0
  local pack="$MODELS_DIR/$PACK_NAME" overlay="$MODELS_DIR/$OVERLAY_NAME"
  local want_set="npz=$DECODE_NPZ_SHA256 reserve_gib=$RESERVE_GIB model=$OVERLAY_NAME"

  # 1) overlay: EXL3 head -> BF16, non-routed layers -> FP8, everything else hard-linked (GPU must be free)
  if [ -f "$overlay/head-bf16.safetensors" ] && [ -f "$overlay/nonrouted-fp8.safetensors" ] && [ -f "$overlay/model.safetensors.index.json" ]; then
    ok "overlay present: $overlay"
  elif [ "$CHECK" = 1 ]; then plan "build the REXL3 overlay at $overlay with upstream build_rexl3_overlay.sh (about 5.7 GiB)"
  else ( cd "$UP_DIR" && MODELS_DIR="$MODELS_DIR" bash packs/1.55bpw-rexl3/scripts/build_rexl3_overlay.sh "$pack" "$overlay" ); fi

  # 2) SSD expert set, sized from the memory free right now (README "Recipe"; rebuilt when RESERVE_GIB changes)
  if [ -f "$ALIAS_DIR/.decode-set" ] && [ "$(cat "$ALIAS_DIR/.decode-set")" = "$want_set" ] && [ -f "$ALIAS_DIR/selection.json" ] && [ -f "$ALIAS_DIR/experts.bin" ]; then
    ok "SSD expert set present: $ALIAS_DIR ($want_set)"
  elif [ "$CHECK" = 1 ]; then plan "size and build the SSD expert set from $DECODE_NPZ at RESERVE_GIB=$RESERVE_GIB into $ALIAS_DIR (upstream plan_reserve.py --build)"
  else
    [ "$(sha256sum "$REPO_DIR/$DECODE_NPZ" | cut -d' ' -f1)" = "$DECODE_NPZ_SHA256" ] || die "$DECODE_NPZ SHA-256 differs from its pin"
    rm -f "$ALIAS_DIR/.decode-set"
    ( cd "$UP_DIR" && MODELS_DIR="$MODELS_DIR" python3 packs/1.55bpw-rexl3/tools/plan_reserve.py --reserve-gib "$RESERVE_GIB" \
        --npz "$REPO_DIR/$DECODE_NPZ" --model-name "$OVERLAY_NAME" --model-dir "$overlay" --out "$ALIAS_DIR" --build )
    echo "$want_set" > "$ALIAS_DIR/.decode-set"; ok "SSD expert set built: $ALIAS_DIR"
  fi

  # 3) upstream's launcher: guard armed, host sysctls set and restored by guard.sh stop
  local argv=(env COLD_SELECTION="$ALIAS_DIR/selection.json" ALIAS_DIR="$ALIAS_DIR" MODELS_DIR="$MODELS_DIR"
    MODEL_NAME="$OVERLAY_NAME" ROUTE_STATS=1 DYN_RESIDENCY=1 DYN_RESIDENCY_MAX_SWAPS=0 AUTO_COLD=0 API_PORT="$PORT"
    bash packs/1.55bpw-rexl3/scripts/serve.sh)
  if [ "$CHECK" = 1 ]; then plan "in $UP_DIR: HF_OVERRIDES_JSON=\$(python3 packs/1.55bpw-rexl3/tools/rexl3_overrides.py) ${argv[*]}"; return; fi
  [ -f "${CACHE_DIR:-$HOME/.cache/dsv41-ds41f}/kkref/jit/.warm" ] ||
    printf '    note  first boot: the JIT cache is cold, so upstream compiles with one worker (about 5 min).\n          Once it is ready, ./run.sh --stop && ./run.sh serves with upstream'"'"'s measured worker settings.\n'
  ( cd "$UP_DIR" && HF_OVERRIDES_JSON="$(python3 packs/1.55bpw-rexl3/tools/rexl3_overrides.py)" "${argv[@]}" ) | tee "$LOGFILE"
  nohup docker logs -f "$CONTAINER_NAME" >>"$LOGFILE" 2>&1 &
}

stop_override() {   # upstream's stop: removes the container, stops the guard, restores the host sysctls
  if [ -z "$(docker ps -aq --filter "name=^${CONTAINER_NAME}\$" 2>/dev/null)" ]; then ok "nothing started by this script is running"; return; fi
  [ -d "$UP_DIR" ] || die "$UP_DIR not found; stop it with upstream's scripts/guard.sh stop"
  ( cd "$UP_DIR" && doit bash scripts/guard.sh stop )
  ok "stopped $CONTAINER_NAME and restored the host sysctls"
}

curl_test() {      # served model id dsv41 and upstream's own check (scripts/smoke.sh, must answer "Paris")
  cat <<EOF
curl -s http://127.0.0.1:${PORT}/v1/chat/completions -H 'Content-Type: application/json' \\
  -d '{"model":"dsv41","messages":[{"role":"user","content":"What is the capital of France? One word."}],"max_tokens":2000}'
cd ${UP_DIR} && API_PORT=${PORT} bash scripts/smoke.sh
EOF
}
# ===================== end of recipe config =================================

# ---------------------------------------------------------------------------
# Shared machinery (identical in every sxuff recipe repo).
# ---------------------------------------------------------------------------
CHECK=0; ACTION=run
usage() {
  cat <<EOF
Usage: ./run.sh [--check] [--stop] [--help]

Sets up and launches ${RECIPE_NAME} on one NVIDIA GB10 (SM121).

  (no flag)  check the machine, build or pull the pinned engine, download the
             pinned weights, verify SHA-256, start the server, print a test.
             Safe to re-run: finished steps are skipped.
  --check    print what would happen; change nothing.
  --stop     stop the server this script started.
  --help     show this text.

Environment:
  HF_TOKEN     Hugging Face token, read from the environment only, never saved.
  MODELS_DIR   weights        (default: ${MODELS_DIR})
  SRC_DIR      engine source  (default: ${SRC_DIR})
  STATE_DIR    pid and log    (default: ${STATE_DIR})
  PORT         server port    (default: ${PORT})

Expected: ${EXPECTED_LINE}
Receipt:  ${RECEIPT_PATH}
EOF
}
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --stop)  ACTION=stop ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $a (see ./run.sh --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
plan() { printf '    would %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
CHECK_FAILED=0   # under --check, a failed pre-flight check is reported and the plan continues
fail() { if [ "$CHECK" = 1 ]; then printf '    FAIL  %s\n' "$*"; CHECK_FAILED=1; else die "$*"; fi; }
human(){ numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
doit() { if [ "$CHECK" = 1 ]; then plan "$*"; else "$@"; fi; }   # mutate, or describe under --check

PIDFILE="${STATE_DIR}/server.pid"
LOGFILE="${STATE_DIR}/server.log"
STOP_CMD="cd ${REPO_DIR} && ./run.sh --stop"

server_running() {
  if [ "$ENGINE_KIND" = docker ]; then
    [ -n "$(docker ps -q --filter "name=^${CONTAINER_NAME}\$" 2>/dev/null)" ]
  else
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
  fi
}

stop_step() {   # may be overridden in the config block (e.g. to call scripts/stop.sh)
  if ! server_running; then ok "nothing started by this script is running"; return; fi
  if [ "$ENGINE_KIND" = docker ]; then doit docker stop "$CONTAINER_NAME"
  else
    local pid; pid="$(cat "$PIDFILE")"; doit kill "$pid"
    if [ "$CHECK" = 0 ]; then
      for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid"; rm -f "$PIDFILE"
    fi
  fi
  ok "stopped"
}
declare -f stop_override >/dev/null && stop_step() { stop_override; }

if [ "$ACTION" = stop ]; then say "Stopping ${RECIPE_NAME}"; stop_step; exit 0; fi
[ "$CHECK" = 1 ] && say "--check: nothing will be changed"

# git checkout of an exact commit, idempotent. Usage: git_pin <url> <sha> <dir>
git_pin() {
  local url="$1" sha="$2" dir="$3"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then ok "source at ${sha:0:12}: $dir"; return; fi
  if [ ! -d "$dir/.git" ]; then doit git clone --quiet "$url" "$dir"; fi
  if [ "$CHECK" = 1 ]; then plan "check out $sha in $dir"; return; fi
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir has local changes; refusing to move it to $sha"
  git -C "$dir" fetch --quiet origin "$sha" 2>/dev/null || git -C "$dir" fetch --quiet origin
  git -C "$dir" checkout --quiet --detach "$sha"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "could not check out $sha in $dir"
  ok "source at ${sha:0:12}: $dir"
}

# docker image by digest, idempotent. Usage: image_pin <repo@sha256:...>
image_pin() {
  if docker image inspect "$1" >/dev/null 2>&1; then ok "image present: $1"; else doit docker pull "$1"; fi
}

# --- 1. machine ------------------------------------------------------------
say "Machine"
[ "$(uname -m)" = aarch64 ] || die "expected aarch64 (GB10), got $(uname -m)"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found"
GPU="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader | head -1)"
case "$GPU" in *GB10*", 12.1") ok "GPU: $GPU" ;; *) die "measured on an NVIDIA GB10 (SM121); found: ${GPU:-none}" ;; esac
MISSING=""; for t in $NEEDS_TOOLS; do command -v "$t" >/dev/null || MISSING="$MISSING $t"; done
if [ -n "$MISSING" ]; then fail "missing tool(s):$MISSING"; else ok "tools: $NEEDS_TOOLS"; fi
ALREADY=0; server_running && ALREADY=1
MEM_AVAIL=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) * 1024 ))
if [ "$ALREADY" = 1 ]; then ok "server already running; memory check skipped"
elif [ "$MEM_AVAIL" -lt "$NEED_MEM_BYTES" ]; then
  fail "need $(human "$NEED_MEM_BYTES") available memory, have $(human "$MEM_AVAIL"). Stop other models first (nvidia-smi, docker ps)."
else ok "memory: $(human "$MEM_AVAIL") available, need $(human "$NEED_MEM_BYTES")"; fi
if [ "$ALREADY" = 1 ]; then ok "port ${PORT}: served by this recipe"
else
  # The server binds 127.0.0.1 (or the host network). A listener on 127.0.0.1, a wildcard or ::1
  # blocks it; one bound to another interface address does not, and is only reported.
  PORT_ALL="$(ss -ltnH "sport = :${PORT}" 2>/dev/null || true)"
  PORT_CLASH="$(printf '%s\n' "$PORT_ALL" | awk '{print $4}' | grep -E '^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]|\[::ffff:127\.0\.0\.1\]):' || true)"
  PORT_DOCKER="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "(127\.0\.0\.1|0\.0\.0\.0|\[::\]|:::?):${PORT}->" || true)"
  if [ -n "$PORT_CLASH$PORT_DOCKER" ]; then
    printf '    port %s is taken:\n%s\n%s\n' "$PORT" "$PORT_CLASH" "$PORT_DOCKER"
    fail "free port ${PORT} or run: PORT=<other> ./run.sh"
  elif [ -n "$PORT_ALL" ]; then
    ok "port ${PORT}: free on 127.0.0.1 (also bound elsewhere: $(printf '%s' "$PORT_ALL" | awk '{print $4}' | tr '\n' ' '))"
  else ok "port ${PORT}: free"; fi
fi

# --- 2. disk ---------------------------------------------------------------
say "Disk"
nearest_dir() { local d="$1"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; echo "$d"; }
NEED_DISK=$ENGINE_DISK_BYTES
while read -r sha size repo rev rpath dest; do
  [ -z "${sha:-}" ] && continue
  have=0; [ -f "$MODELS_DIR/$dest" ] && have=$(stat -c %s "$MODELS_DIR/$dest")
  [ "$have" -lt "$size" ] && NEED_DISK=$(( NEED_DISK + size - have ))
done <<< "$WEIGHTS"
FREE_DISK=$(df -B1 --output=avail "$(nearest_dir "$MODELS_DIR")" | tail -1 | tr -d ' ')
if [ "$FREE_DISK" -ge "$NEED_DISK" ]; then ok "need $(human "$NEED_DISK") more, have $(human "$FREE_DISK")"
else fail "need $(human "$NEED_DISK") more disk under $MODELS_DIR, have $(human "$FREE_DISK"). Nothing was deleted."; fi

# --- 3. engine -------------------------------------------------------------
say "Engine"
engine_step

# --- 4. weights: pinned revision + SHA-256 -----------------------------------
hf_fetch() {   # repo rev path dest. The token reaches curl on stdin: never in argv or a file.
  { [ -n "${HF_TOKEN:-}" ] && printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN"; true; } |
    curl --fail --location --retry 5 --retry-delay 5 --continue-at - --config - \
         --output "$4.part" "https://huggingface.co/$1/resolve/$2/$3"
  mv "$4.part" "$4"
}
default_weights_step() {
  while read -r sha size repo rev rpath dest; do
    [ -z "${sha:-}" ] && continue
    local f="$MODELS_DIR/$dest" mark="$MODELS_DIR/$dest.sha256-ok"
    if [ -f "$mark" ] && [ "$(cat "$mark")" = "$sha $size" ] && [ "$(stat -c %s "$f" 2>/dev/null)" = "$size" ]; then
      ok "verified earlier: $dest"; continue
    fi
    if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" != "$size" ]; then
      if [ "$CHECK" = 1 ]; then plan "download $repo@${rev:0:12} $rpath ($(human "$size"))"; continue; fi
      mkdir -p "$(dirname "$f")"; printf '    get   %s (%s)\n' "$rpath" "$(human "$size")"
      hf_fetch "$repo" "$rev" "$rpath" "$f"
    elif [ "$CHECK" = 1 ]; then plan "verify SHA-256 of $dest"; continue; fi
    local got; got="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ "$got" != "$sha" ]; then mv "$f" "$f.sha256-mismatch"; die "SHA-256 mismatch for $dest: expected $sha, got $got (kept as $f.sha256-mismatch)"; fi
    echo "$sha $size" > "$mark"; ok "sha256 ok: $dest"
  done <<< "$WEIGHTS"
}
declare -f weights_step >/dev/null || weights_step() { default_weights_step; }
say "Weights"
weights_step

# --- 5. serve --------------------------------------------------------------
say "Server"
if [ "$ALREADY" = 1 ]; then ok "already running"
elif [ "$CHECK" = 1 ]; then serve_step
else
  mkdir -p "$STATE_DIR"; serve_step
  printf '    wait  for %s (up to %ss; log: %s)\n' "$READY_URL" "$READY_TIMEOUT" "$LOGFILE"
  t=0
  until curl -fsS -o /dev/null "$READY_URL" 2>/dev/null; do
    server_running || die "server exited during start-up; see $LOGFILE"
    [ "$t" -ge "$READY_TIMEOUT" ] && die "not ready after ${READY_TIMEOUT}s; see $LOGFILE"
    sleep 5; t=$((t + 5))
  done
  ok "ready after ${t}s"
fi

# --- 6. done ---------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  if [ "$CHECK_FAILED" = 1 ]; then say "Check finished with FAIL lines above; nothing was changed. ./run.sh would stop at the first one."; exit 1; fi
  say "Check finished; nothing was changed. Run ./run.sh to do it."; exit 0
fi
say "Test it"
curl_test
say "Stop it"
echo "$STOP_CMD"
echo
echo "Expected: ${EXPECTED_LINE} - receipt: ${RECEIPT_PATH}"
