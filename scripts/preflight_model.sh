#!/usr/bin/env bash
# =============================================================================
# PREFLIGHT — can this box actually run a candidate model, before downloading it
# =============================================================================
# Answers four questions in ~10 seconds, without pulling weights:
#   1. Which candidate repo actually exists, and how big is it?  (HF API)
#   2. What does its config.json say?   (context, experts, vision, quant method)
#   3. Does the pinned image's vLLM know the architecture?       (model registry)
#   4. Will weights + KV cache fit the budget?
#
# Built for zero-day models on brand-new architectures, where the failure mode
# is downloading ~90 GB and only then finding out the image cannot register the
# model. Every previous swap in this repo learned that the expensive way.
#
# RUN THIS ON THE SPARK. It needs python3, docker, and /opt/models to answer
# anything meaningful — on a workstation every check skips or reports nothing.
#
# Usage:
#   bash scripts/preflight_model.sh <hf_repo> [more_repos...]
#
# Pass SEVERAL candidate names when the exact repo is unknown — Unsloth's
# convention varies (`Qwen3.8-27B-NVFP4` but `Qwen3.8-2.4T-A95B-GGUF`, i.e.
# MoE uploads may carry an -A{active}B suffix). The first repo that exists
# wins; the rest are reported as not-found and skipped. Example:
#
#   bash scripts/preflight_model.sh \
#       unsloth/Qwen3.8-Flash-Next-NVFP4 \
#       unsloth/Qwen3.8-Flash-Next-125B-A6B-NVFP4 \
#       unsloth/Qwen3.8-Flash-Next
#
# Override the image with PREFLIGHT_IMAGE=<tag>; default is brain.docker_image
# from config/models.yml.
#
# Exit codes: 0 = all checks passed, 1 = a hard blocker, 2 = advisory warning.
# Nothing here writes to /opt/models or starts a long-lived container.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

export PATH="$HOME/.local/bin:$PATH"
export HF_TOKEN="${HF_TOKEN:-}"

MODELS_DIR="${MODELS_DIR:-/opt/models}"

# Every check below is a python3 one-liner, so bail early and loudly if the
# interpreter is missing — otherwise the checks return blank and the later
# error messages blame HuggingFace for what is really a local problem.
#
# This deliberately RUNS python3 instead of using `command -v`. On Windows,
# Git Bash finds the Microsoft Store alias stub at
# ~/AppData/Local/Microsoft/WindowsApps/python3.exe, so `command -v` succeeds
# and only execution fails. That is not a hypothetical: it is how this guard
# got missed the first time.
if ! python3 -c 'import sys, json, urllib.request' >/dev/null 2>&1; then
    echo "ERROR: python3 is on PATH but not usable — every check here needs it."
    echo "PATH=${PATH}"
    echo ""
    echo "  Run this ON THE SPARK, not on the Windows laptop. Preflight needs"
    echo "  python3, docker, and ${MODELS_DIR} to answer anything useful; on a"
    echo "  workstation all three checks would skip or lie."
    echo ""
    echo "    ssh <username>@spark-XXXX.local     # see scripts/00_first_boot.sh"
    echo "    cd ~/spark-sovereign && git fetch && git checkout brain-flash-next-eval"
    echo "    bash scripts/preflight_model.sh <hf_repo>"
    exit 1
fi

# Total memory CUDA reports on GB10. Matches the figure 03_vllm_servers.sh prints.
VISIBLE_GIB=121.69
# Always-on non-Brain consumers, from the Memory Map in config/models.yml
# (ASR 3.0 + TTS 1.4 + SearXNG 0.5 + NemoClaw/OpenClaw 1.0 + OS/Docker/vLLM 6.0).
RESERVED_GIB=11.9

if [ "$#" -lt 1 ]; then
    echo "Usage: bash scripts/preflight_model.sh <hf_repo> [more_repos...]"
    echo "       PREFLIGHT_IMAGE=<tag> to override the Docker image."
    exit 1
fi

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
print(val if val is not None else '')
"
}

DOCKER_IMAGE="${PREFLIGHT_IMAGE:-$(get_field brain docker_image)}"

WARN=0
FAIL=0

echo "========================================================"
echo " spark-sovereign — model preflight"
echo "========================================================"
echo "  Candidates : $*"
echo "  Image      : ${DOCKER_IMAGE}"
echo ""

# ── 1. Which candidate exists, and how big is it (no weights downloaded) ──────
echo ">>> [1/4] Resolving candidate repos against the HuggingFace API..."
RESOLVED="$(python3 - "$@" <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

token = os.environ.get("HF_TOKEN") or ""


def fetch(url):
    req = urllib.request.Request(
        url, headers={"User-Agent": "spark-sovereign-preflight"}
    )
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


winner = None
for repo in sys.argv[1:]:
    try:
        meta = fetch("https://huggingface.co/api/models/%s?blobs=true" % repo)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("MISS\t%s\tnot published" % repo)
        elif e.code in (401, 403):
            print("MISS\t%s\tgated - set HF_TOKEN and accept the license" % repo)
        else:
            print("MISS\t%s\tHTTP %s" % (repo, e.code))
        continue
    except Exception as e:
        print("MISS\t%s\tunreachable (%s)" % (repo, e))
        continue

    # Weight shards only. Ignore docs, tokenizer files, and .index.json.
    total = 0
    shards = 0
    for s in meta.get("siblings") or []:
        name = s.get("rfilename", "")
        if name.endswith((".safetensors", ".gguf", ".bin", ".pt")):
            total += s.get("size") or 0
            shards += 1

    gib = total / (1024 ** 3)
    archs = ((meta.get("config") or {}).get("architectures")) or []
    print("HIT\t%s\t%.1f GiB, %d shards" % (repo, gib, shards))
    if winner is None:
        winner = (repo, gib, shards, ",".join(archs) if archs else "UNKNOWN")

if winner is None:
    print("NONE")
else:
    print("WIN\t%s\t%.1f\t%d\t%s" % winner)
PYEOF
)"

printf '%s\n' "${RESOLVED}" | while IFS=$'\t' read -r tag repo detail _rest; do
    case "${tag}" in
        HIT)  echo "    FOUND    ${repo} — ${detail}" ;;
        MISS) echo "    missing  ${repo} — ${detail}" ;;
    esac
done

WIN_LINE="$(printf '%s\n' "${RESOLVED}" | grep '^WIN' || true)"
if [ -z "${WIN_LINE}" ]; then
    echo ""
    echo "    BLOCKER: none of the candidate repos exist yet."
    echo "    If the model has not dropped, this is expected — re-run once it"
    echo "    is live. Do not edit models.yml until a candidate resolves."
    exit 1
fi

HF_REPO="$(printf '%s' "${WIN_LINE}" | cut -f2)"
REPO_GIB="$(printf '%s' "${WIN_LINE}" | cut -f3)"
SHARDS="$(printf '%s' "${WIN_LINE}" | cut -f4)"
ARCHS="$(printf '%s' "${WIN_LINE}" | cut -f5)"

echo ""
echo "    Using       : ${HF_REPO}"
echo "    Weight files: ${SHARDS} shards, ${REPO_GIB} GiB total"
echo "    Architecture: ${ARCHS}"
if [ "${ARCHS}" = "UNKNOWN" ]; then
    echo "    NOTE: no architectures[] in config.json — GGUF repos and some"
    echo "          quantized uploads omit it. Check the model card by hand."
    WARN=1
fi
echo ""

# ── 2. The facts that would otherwise be guesses in models.yml ────────────────
# config.json is ~20 KB. Pulling it turns context length, expert counts, vision
# support and quant method from "UNCONFIRMED" comments into measured values.
echo ">>> [2/4] Reading config.json for the fields models.yml has to guess..."
# Kept on disk so the stage 4 fit check can read it too: it needs the n-gram /
# PLE dimensions to work out how much of the checkpoint is offloadable.
CFG_JSON="$(mktemp -t preflight-config-XXXXXX.json 2>/dev/null || echo /tmp/preflight-config.$$.json)"
trap 'rm -f "${CFG_JSON}"' EXIT
python3 - "${HF_REPO}" "${CFG_JSON}" <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

repo = sys.argv[1]
token = os.environ.get("HF_TOKEN") or ""
url = "https://huggingface.co/%s/resolve/main/config.json" % repo
req = urllib.request.Request(url, headers={"User-Agent": "spark-sovereign-preflight"})
if token:
    req.add_header("Authorization", "Bearer " + token)

try:
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    cfg = json.loads(raw)
except Exception as e:
    print("    SKIP: could not fetch config.json (%s)" % e)
    sys.exit(0)

# Hand it to stage 4 rather than fetching twice.
if len(sys.argv) > 2 and sys.argv[2]:
    try:
        with open(sys.argv[2], "wb") as f:
            f.write(raw)
    except Exception:
        pass


def find(d, *keys):
    """Look for a key at the top level or one level into a *_config block."""
    for k in keys:
        if k in d:
            return d[k]
    for v in d.values():
        if isinstance(v, dict):
            for k in keys:
                if k in v:
                    return v[k]
    return None


ctx = find(cfg, "max_position_embeddings", "seq_length")
rope = cfg.get("rope_scaling")
experts = find(cfg, "num_experts", "n_routed_experts", "num_local_experts")
active = find(cfg, "num_experts_per_tok", "num_experts_per_token")
vision = any(k in cfg for k in ("vision_config", "visual", "image_token_id"))
quant = (cfg.get("quantization_config") or {}).get("quant_method")
layers = find(cfg, "num_hidden_layers")
dtype = cfg.get("torch_dtype")

print("    context (max_position_embeddings) : %s" % (ctx if ctx else "not stated"))
if rope:
    print("    rope_scaling                      : %s" % json.dumps(rope)[:120])
print("    MoE experts / active per token    : %s / %s" % (experts or "n/a", active or "n/a"))
print("    vision block present              : %s" % ("YES" if vision else "no"))
print("    quantization_config.quant_method  : %s" % (quant or "none (unquantized upload)"))
print("    hidden layers / torch_dtype       : %s / %s" % (layers or "?", dtype or "?"))

# Surface anything n-gram shaped. For Flash-Next this is the whole ballgame:
# a BF16 lookup table is ~95 GiB on its own and will not fit on one GB10.
ngram = {k: v for k, v in cfg.items() if "ngram" in k.lower() or "n_gram" in k.lower()}
if ngram:
    print("    N-gram related keys               : %s" % json.dumps(ngram)[:200])

print("")
print("    ^ copy these into the OPTION 3 block, replacing the UNCONFIRMED lines.")
PYEOF
echo ""

# ── 3. Does the vLLM inside the pinned image register that architecture? ──────
# The check that matters most for a zero-day architecture: a preview model can
# download perfectly and still be unloadable by an image that predates it.
# Note: Unsloth's NVFP4 uploads quantize lm_head to FP8 and need vLLM MAIN, so
# a registered architecture is necessary but not automatically sufficient.
echo ">>> [3/4] Checking vLLM architecture support inside ${DOCKER_IMAGE}..."
if ! command -v docker >/dev/null 2>&1; then
    echo "    SKIP: docker not available on this host (run this on the Spark)."
    WARN=1
elif ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    echo "    Image not present locally. Pull it first, then re-run:"
    echo "      docker pull ${DOCKER_IMAGE}"
    echo "    Skipping the registry check for now."
    WARN=1
elif [ "${ARCHS}" = "UNKNOWN" ]; then
    echo "    SKIP: architecture unknown, nothing to look up."
    WARN=1
else
    SUPPORTED="$(docker run --rm --entrypoint python3 "${DOCKER_IMAGE}" -c \
        'from vllm.model_executor.models.registry import ModelRegistry
print(chr(10).join(sorted(ModelRegistry.get_supported_archs())))' 2>/dev/null)"

    if [ -z "${SUPPORTED}" ]; then
        echo "    WARN: could not read the vLLM model registry from this image."
        echo "          (Entrypoint or vLLM internals may differ in this build.)"
        WARN=1
    else
        MISSING=""
        IFS=',' read -ra ARCH_LIST <<< "${ARCHS}"
        for a in "${ARCH_LIST[@]}"; do
            if printf '%s\n' "${SUPPORTED}" | grep -qxF "${a}"; then
                echo "    OK       ${a} — registered"
            else
                echo "    MISSING  ${a} — NOT in this image's vLLM registry"
                MISSING="${MISSING} ${a}"
            fi
        done
        if [ -n "${MISSING}" ]; then
            echo ""
            echo "    BLOCKER: this image cannot load the model. Downloading"
            echo "    ${REPO_GIB} GiB now would be wasted. Options:"
            echo "      - wait for a vLLM build that ships the architecture"
            echo "      - switch docker_image to the arm64/GB10 tag others confirm"
            echo "      - run it under llama.cpp instead (outside this stack)"
            FAIL=1
        fi
    fi
fi
echo ""

# ── 4. Will it fit — disk to download onto, and memory to serve from ──────────
echo ">>> [4/4] Fit check..."
if [ -d "${MODELS_DIR}" ]; then
    FREE_GIB="$(df -BG --output=avail "${MODELS_DIR}" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [ -n "${FREE_GIB}" ]; then
        echo "    Disk free on ${MODELS_DIR}: ${FREE_GIB} GiB (need ${REPO_GIB} GiB)"
        if python3 -c "import sys; sys.exit(0 if ${FREE_GIB} < ${REPO_GIB} else 1)"; then
            echo "    BLOCKER: not enough free disk. Prune or archive a model first"
            echo "    (scripts/02_download_models.sh offers archive-on-prune)."
            FAIL=1
        fi
    fi
else
    echo "    SKIP disk check: ${MODELS_DIR} does not exist on this host."
    WARN=1
fi

# Total system RAM, so the fit check can tell unified memory from a discrete
# GPU. On a discrete card, host RAM is memory the GPU does not have. On GB10 it
# is the SAME memory, and "offload to host" moves bytes from one side of one
# pool to the other without creating any.
SYS_RAM_GIB="$(awk '/MemTotal/ {printf "%.2f", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)"

python3 - "${REPO_GIB}" "${VISIBLE_GIB}" "${RESERVED_GIB}" "${CFG_JSON:-}" "${SYS_RAM_GIB}" <<'PYEOF'
import json, os, sys

weights, visible, reserved = (float(x) for x in sys.argv[1:4])
sys_ram = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
budget = visible - reserved

# OFFLOADABLE WEIGHT. Comparing the whole checkpoint against GPU memory is
# right for an ordinary model and wrong for one that keeps part of itself in
# host RAM by design.
#
# Qwen3.8-Flash-Next carries a 51B n-gram embedding table alongside its 125B
# MoE. Its own card calls embeddings "more amenable to offloading than MoE",
# and vLLM's PLE-Offload puts that table in host memory so it never occupies
# VRAM. Counting it against the GPU budget reported BLOCKED for a model that
# fits with ~42 GiB of KV cache to spare — the same failure shape as a roofline
# that divides by a whole checkpoint when only some experts are read.
#
# Size comes from the config, not a guess: ngram_vocab_size_base x ple_embed_dim
# at 2 bytes. Reported separately so the operator sees both numbers and knows
# the second one depends on actually passing the offload flag.
offload = 0.0
cfg_path = sys.argv[4] if len(sys.argv) > 4 else ""
if cfg_path and os.path.isfile(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        lm = cfg.get("language_config") or cfg.get("text_config") or cfg
        vocab = lm.get("ngram_vocab_size_base") or cfg.get("ngram_vocab_size_base")
        dim = lm.get("ple_embed_dim") or cfg.get("ple_embed_dim")
        if vocab and dim:
            offload = float(vocab) * float(dim) * 2 / (1024 ** 3)
    except Exception:
        offload = 0.0

resident = weights - offload

# UNIFIED MEMORY. If the GPU's visible memory is most of the machine's RAM,
# this is a shared pool (GB10, Grace-Hopper, Apple silicon) and offloading
# frees nothing — the bytes land in the same 128 GB.
#
# This check exists because its absence produced a confidently wrong CLEAR.
# Qwen3.8-Flash-Next was reported as fitting with 35 GiB of KV cache to spare:
# 76 GiB on GPU plus 95 GiB "offloaded to host". The box has 121 GiB total. It
# needed 171. The server loaded the weights, registered the offload layer, and
# died — after a 170 GiB download.
#
# On a discrete GPU the original arithmetic is right. The bug was assuming it.
unified = sys_ram > 0 and visible > 0.5 * sys_ram

print("    GPU visible        : %.2f GiB" % visible)
if sys_ram > 0:
    print("    System RAM         : %.2f GiB%s"
          % (sys_ram, "   <- UNIFIED with GPU memory" if unified else ""))
print("    Always-on reserved : %.2f GiB (ASR/TTS/SearXNG/OS/Docker)" % reserved)
print("    Weights (total)    : %.1f GiB" % weights)

if offload > 0 and unified:
    # The pool is shared, so the whole checkpoint has to live in it at once.
    kv = budget - weights
    print("    n-gram/PLE table   : %.1f GiB  (offloadable on a DISCRETE GPU)" % offload)
    print("    Left for KV cache  : %.1f GiB" % kv)
    print("")
    print("    UNIFIED MEMORY: offloading does NOT help here. Host and device")
    print("    share one pool, so %.1f GiB of weights must fit in %.2f GiB"
          % (weights, budget))
    print("    whether the table is 'on GPU' or 'on host'. PLE-Offload assumes")
    print("    host RAM the GPU does not already have.")
elif offload > 0:
    kv = budget - resident
    print("    n-gram/PLE table   : %.1f GiB  <- offloadable to HOST RAM" % offload)
    print("    Weights on GPU     : %.1f GiB  (with PLE-Offload enabled)" % resident)
    print("    Left for KV cache  : %.1f GiB" % kv)
    print("      REQUIRES the PLE-Offload flag. Without it the table is resident")
    print("      and the real figure is %.1f GiB of weights, %.1f GiB of KV."
          % (weights, budget - weights))
else:
    kv = budget - resident
    print("    Left for KV cache  : %.1f GiB" % kv)

if kv <= 0:
    print("    BLOCKER: weights alone exceed the budget. Needs a smaller quant.")
    sys.exit(1)

# vLLM's --gpu-memory-utilization is a fraction of TOTAL visible memory and
# covers weights + KV cache together, so derive it from the whole budget.
# This is a CEILING, not a recommendation: it is what the budget permits, not
# what the model needs. A model with room to spare should sit well under it —
# the v5.0 27B fits in 0.45 while this line would report 0.90.
print("    Max safe gpu_memory_utilization : %.2f" % (budget / visible))
print("      Ceiling the budget allows, NOT a target. Use the lowest value that")
print("      leaves enough KV cache for your max_model_len x max_num_seqs.")

if kv < 8:
    print("    WARN: under ~8 GiB of KV cache. Expect to cut max_model_len and")
    print("          max_num_seqs hard, or to OOM at long context.")
    sys.exit(2)
if kv < 20:
    print("    NOTE: tight KV budget. Start at max_model_len 65536 /")
    print("          max_num_seqs 4 and raise only after nvidia-smi confirms.")
PYEOF
FIT_RC=$?
# 0 = fits, 2 = fits but tight. Any other code (including a crashed
# interpreter) means the check did not run — never treat that as a pass.
case "${FIT_RC}" in
    0) ;;
    2) WARN=1 ;;
    *) FAIL=1 ;;
esac

echo ""
echo "========================================================"
if [ "${FAIL}" != "0" ]; then
    echo " RESULT: BLOCKED — do not download yet. See blockers above."
    exit 1
elif [ "${WARN}" != "0" ]; then
    echo " RESULT: PASSED WITH WARNINGS — read them before committing ~90 GB."
    exit 2
fi
echo " RESULT: CLEAR — safe to fill in config/models.yml and run"
echo "         bash scripts/02_download_models.sh"
echo "========================================================"
