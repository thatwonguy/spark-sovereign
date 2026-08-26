#!/usr/bin/env bash
# =============================================================================
# BANDWIDTH PROBE — measure the roofline instead of assuming it
# =============================================================================
# docs/LESSONS.md #16 asserts "13.5 GB read per token over a ~273 GB/s bus",
# and that pair of numbers has been used to explain the measured 15-17 tok/s
# as near-optimal. BOTH numbers are assumptions. Neither has ever been measured
# on this box:
#
#   273 GB/s   is the GB10 SPEC SHEET figure. Real achievable bandwidth on
#              LPDDR5x is typically 70-85% of spec. If the true number is
#              ~220 GB/s, the roofline is ~16 tok/s and we are already at 100%.
#
#   13.5 GB    assumes the NVFP4 kernels genuinely read 4 bits per parameter.
#              If the kernel path dequantizes to BF16, or silently falls back
#              to a slower general path, the real figure could be 2-4x higher
#              — which would mean we are NOT near any ceiling and there IS
#              config headroom worth chasing. This repo has already been bitten
#              by exactly that failure mode: config/models.yml warns that the
#              previous MoE brain "falls back to Marlin and runs 2.5x slower"
#              when moe_backend is unset.
#
# This script measures both, then derives the third:
#
#       bytes_per_token = achieved_bandwidth / measured_decode_rate
#
# and compares it against what NVFP4 weights SHOULD cost. That ratio is the
# whole answer:
#
#       ratio ~1.0   weights are being read at their quantized width.
#                    The roofline is real and config tuning cannot beat it.
#                    Faster single-stream requires speculation or fewer bits.
#
#       ratio >1.5   the kernels are moving far more data than the weights
#                    occupy. Something in the serving path is wrong, and
#                    ordinary config work has real headroom. CHASE THIS.
#
# Usage:
#   bash scripts/bandwidth_probe.sh
#   TOKS=25.4 bash scripts/bandwidth_probe.sh   # skip the decode benchmark
#
# Runs a short GPU memcpy benchmark in a throwaway container, then (unless
# TOKS is supplied) benchmarks the live Brain. Does not restart anything.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true
BRAIN_API_KEY="${BRAIN_API_KEY:-}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
print(val if val is not None else '')
"
}

BRAIN_IMAGE=$(get_field brain docker_image)
BRAIN_PATH=$(get_field brain local_path)
BUF_GB="${BUF_GB:-2}"          # per-buffer size; 2 GB x2 fits beside a 0.45-util Brain
ITERS="${ITERS:-30}"

echo ""
echo "============================================================"
echo " Bandwidth Probe — measuring the roofline, not assuming it"
echo "============================================================"

# -- 1. Achieved memory bandwidth --------------------------------------------
# Device-to-device copy of a large buffer. Reads BUF_GB and writes BUF_GB per
# iteration, so bytes moved = 2 x BUF_GB. This is a STREAM-copy style figure:
# an upper bound on what any kernel can sustain, and the honest denominator
# for a roofline. Run in a throwaway container so a crash cannot touch Brain.
echo ""
echo ">>> 1. Achieved device memory bandwidth (${BUF_GB} GB buffers, ${ITERS} iters)"
echo "    Spec sheet for GB10 is 273 GB/s. Expect 70-85% of that."
echo ""

# No --ipc host and no --network host: a memcpy benchmark needs neither, and
# the Brain container's own flags are not a reason to hand the same namespace
# access to a throwaway. --network none keeps it off the network entirely.
BW=$(docker run --rm --gpus all --network none \
        -e BUF_GB="${BUF_GB}" -e ITERS="${ITERS}" \
        --entrypoint python3 "${BRAIN_IMAGE}" -c '
import os, time, torch
buf_gb = float(os.environ["BUF_GB"])
iters = int(os.environ["ITERS"])
n = int(buf_gb * (1 << 30) // 2)          # float16 elements
try:
    a = torch.empty(n, dtype=torch.float16, device="cuda")
    b = torch.empty(n, dtype=torch.float16, device="cuda")
except RuntimeError as e:
    print(f"ERROR {e}")
    raise SystemExit(1)
a.fill_(1.0)
for _ in range(5):                         # warmup: clocks, allocator
    b.copy_(a)
torch.cuda.synchronize()
t0 = time.perf_counter()
for _ in range(iters):
    b.copy_(a)
torch.cuda.synchronize()
dt = time.perf_counter() - t0
moved = 2 * a.numel() * a.element_size() * iters      # read + write
print(f"{moved / dt / 1e9:.1f}")
' 2>/dev/null | tail -1)

if ! echo "${BW}" | grep -qE '^[0-9.]+$'; then
    echo "    ERROR: bandwidth measurement failed."
    echo "    Try a smaller buffer: BUF_GB=1 bash scripts/bandwidth_probe.sh"
    echo "    (Brain reserves 45% of memory; a 2 GB x2 test may not fit"
    echo "     alongside other GPU containers.)"
    exit 2
fi

echo "    Achieved: ${BW} GB/s"
echo ""

# -- 2. Measured decode rate --------------------------------------------------
echo ">>> 2. Single-stream decode rate"
if [ -n "${TOKS:-}" ]; then
    echo "    Using supplied TOKS=${TOKS} tok/s (benchmark skipped)"
else
    BRAIN_PORT=$(get_field brain port)
    if ! curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
            "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; then
        echo "    Brain is not up — cannot measure. Re-run with TOKS=<rate>."
        exit 2
    fi
    BENCH=$(bash "${REPO_ROOT}/scripts/benchmark_brain.sh" 2>&1)
    echo "${BENCH}" | sed 's/^/    /'
    # benchmark_brain.sh prints a median line; pull the first decode figure.
    TOKS=$(echo "${BENCH}" | grep -ioE '[0-9]+\.[0-9]+ tok/s' | head -1 | grep -oE '[0-9.]+')
    if [ -z "${TOKS}" ]; then
        echo "    Could not parse a rate from the benchmark output."
        echo "    Re-run with TOKS=<rate> taken from the table above."
        exit 2
    fi
fi
echo ""

# -- 3. Derive bytes/token and compare against the quantized weight size ------
echo ">>> 3. Derived bytes moved per token"

WEIGHTS_GB=""
if [ -d "${BRAIN_PATH}" ]; then
    # On-disk size of the checkpoint is the best available proxy for how many
    # bytes a correct kernel path has to read per forward pass.
    WEIGHTS_GB=$(du -sb "${BRAIN_PATH}" 2>/dev/null | awk '{printf "%.1f", $1/1e9}')
fi

BW="${BW}" TOKS="${TOKS}" WEIGHTS_GB="${WEIGHTS_GB}" python3 - <<'PYEOF'
import os, sys

bw    = float(os.environ["BW"])
toks  = float(os.environ["TOKS"])
wraw  = os.environ.get("WEIGHTS_GB", "")

per_token = bw / toks

print(f"    achieved bandwidth   : {bw:.1f} GB/s")
print(f"    measured decode      : {toks:.1f} tok/s")
print(f"    => bytes per token   : {per_token:.1f} GB")
print("")

if not wraw:
    print("    Checkpoint dir not readable here (run this ON the Spark) —")
    print("    cannot compute the ratio. Compare per-token by hand against")
    print("    the on-disk size of the weights.")
    sys.exit(0)

weights = float(wraw)
print(f"    checkpoint on disk   : {weights:.1f} GB")
ratio = per_token / weights
print(f"    ratio                : {ratio:.2f}x")
print("")

if ratio < 1.25:
    print("    VERDICT: weights are being read at roughly their quantized")
    print("    width. The bandwidth roofline is REAL and close.")
    print("")
    print(f"    Ceiling at this bandwidth: ~{bw / weights:.1f} tok/s single-stream.")
    print("    Config tuning cannot meaningfully beat that. Going faster")
    print("    single-stream needs FEWER BYTES (lower-bit quant) or FEWER")
    print("    PASSES (speculative decoding) — see specdecode_sweep.sh,")
    print("    which now includes the free n-gram/prompt-lookup method.")
elif ratio < 1.6:
    print("    VERDICT: moving somewhat more than the weights occupy. Some of")
    print("    this is legitimate — KV cache reads, activations, and the")
    print("    copy benchmark above is an optimistic upper bound. But it is")
    print("    worth checking the attention backend and quant kernel path")
    print("    before concluding you are at a ceiling.")
else:
    print("    VERDICT: *** MOVING FAR MORE DATA THAN THE WEIGHTS OCCUPY ***")
    print("    This is NOT a bandwidth ceiling — it is a serving-path problem.")
    print("    You are reading roughly", f"{ratio:.1f}x", "the bytes a correct NVFP4")
    print("    path should need. Ordinary config work has real headroom here.")
    print("")
    print("    Check, in order:")
    print("      - quant kernel fallback. config/models.yml already documents")
    print("        this exact failure for MoE ('falls back to Marlin, 2.5x")
    print("        slower'). Grep the log for the kernel/backend actually")
    print("        chosen for the NVFP4 linear layers.")
    print("      - attention backend vs kv_cache_dtype: fp8. A BF16 KV")
    print("        fallback doubles KV bytes read per token.")
    print("      - enforce_eager / CUDA graph state — per-token launch")
    print("        overhead shows up here as apparent extra traffic.")
    print("")
    print(f"    If the path were correct, this box would sustain ~{bw / weights:.1f} tok/s.")
PYEOF

echo ""
echo "============================================================"
echo " This measures the CEILING. It does not measure whether any"
echo " particular technique reaches it. For that:"
echo "   bash scripts/specdecode_probe.sh        # is speculation live?"
echo "   bash scripts/specdecode_sweep.sh        # mtp vs ngram vs off"
echo "   bash scripts/benchmark_concurrency.sh   # does batching scale?"
echo "============================================================"
