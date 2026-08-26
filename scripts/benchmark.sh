#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — the only benchmarking entry point
# =============================================================================
#
#   *** AD-HOC. NOT PART OF ANY SEQUENCE. ***
#   Nothing calls this. It is absent from boot_sequence.sh, watchdog.sh and
#   the numbered 00-04 setup path, deliberately unnumbered so it cannot be
#   mistaken for a setup step, and must never be added to one.
#
# ONE COMMAND FILLS THE REPORT:
#
#     bash scripts/benchmark.sh
#
# That runs the audit, then every configuration in the matrix, then writes
# docs/BENCHMARKS.md. Nothing else needs invoking.
#
# SUBCOMMANDS (for when you want one piece):
#   audit      declared config vs what the server actually did   (read-only, ~1 min)
#   quick      decode rate + TTFT of the running config          (read-only, ~1 min)
#   bandwidth  achieved memory bandwidth + derived bytes/token   (read-only, ~1 min)
#   matrix     sweep every configuration                         (hours, Brain down)
#   render     regenerate BENCHMARKS.md from the ledger          (instant)
#   list       show the matrix and what has been measured        (instant)
#
# OPTIONS:
#   --only a,b   restrict the matrix to named configurations
#   --redo       re-measure configurations already in the ledger
#
# All measurement primitives and the report renderer live in
# scripts/lib/bench.sh. This file is orchestration only.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/bench.sh"

RUNS="${RUNS:-3}"
MAX_TOKENS="${MAX_TOKENS:-256}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"
STREAMS="${STREAMS:-1 4 8}"

CMD="all"
ONLY=""
REDO=0
while [ $# -gt 0 ]; do
    case "$1" in
        audit|quick|bandwidth|matrix|render|list|all) CMD="$1"; shift ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --redo) REDO=1; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

bench_init

# =============================================================================
# THE MATRIX
# =============================================================================
# name | engine | OVERRIDE_field=value ...
#
# ONE FACTOR AT A TIME from the baseline, deliberately, not a full cross
# product. A product of five parameters is hundreds of hours of model loads and
# still would not say WHICH factor moved the number. OFAT attributes cause.
# The INTERACTION rows are the exception: those settings are known to trade
# against each other, so testing them separately would mislead.
#
# An empty value UNSETS the field (spec-off), which is distinct from omitting it.
MATRIX=$(cat <<'EOF'
baseline|vllm|
prefix-off|vllm|OVERRIDE_enable_prefix_caching=false
attn-triton|vllm|OVERRIDE_attention_backend=TRITON_ATTN
attn-flashinfer|vllm|OVERRIDE_attention_backend=FLASHINFER
kv-bf16|vllm|OVERRIDE_kv_cache_dtype=auto
spec-off|vllm|OVERRIDE_speculative_config=
spec-mtp3|vllm|OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":3}
spec-mtp2|vllm|OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":2}
spec-ngram5|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4}
spec-ngram3|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":3,"prompt_lookup_max":4}
util-080|vllm|OVERRIDE_gpu_memory_utilization=0.80
INTERACTION-flashinfer-bf16kv|vllm|OVERRIDE_attention_backend=FLASHINFER OVERRIDE_kv_cache_dtype=auto
INTERACTION-triton-util080|vllm|OVERRIDE_attention_backend=TRITON_ATTN OVERRIDE_gpu_memory_utilization=0.80
sglang-baseline|sglang|
sglang-radix-off|sglang|OVERRIDE_disable_radix_cache=true
EOF
)

# =============================================================================
cmd_list() {
    echo ""
    echo "Matrix ($(echo "${MATRIX}" | grep -c '|') configurations):"
    while IFS='|' read -r n e o; do
        [ -z "${n}" ] && continue
        printf "  %-32s %-9s %s\n" "${n}" "[${e}]" "${o:-<models.yml as committed>}"
    done <<< "${MATRIX}"
    echo ""
    echo "Already measured (${LEDGER}):"
    if [ -s "${LEDGER}" ]; then
        LEDGER="${LEDGER}" python3 -c "
import json, os
for line in open(os.environ['LEDGER'], encoding='utf-8'):
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    d = r.get('decode_toks')
    print(f\"  {r.get('name','?'):<32} {r.get('validity','?'):<8} {d if d else '—'} tok/s\")
"
    else
        echo "  (none yet — run: bash scripts/benchmark.sh)"
    fi
    echo ""
}

cmd_render() { render_report; }

cmd_quick() {
    require_brain || return 2
    echo ""
    echo "-- Quick benchmark: ${BRAIN_NAME} --"
    echo "   ${RUNS} runs x ${MAX_TOKENS} tokens"
    m_decode "${RUNS}" "${MAX_TOKENS}" || { echo "   measurement failed"; return 2; }
    echo "   decode : ${DECODE_TOKS} tok/s"
    echo "   TTFT   : ${TTFT_MS} ms"
}

cmd_bandwidth() {
    echo ""
    echo "-- Bandwidth probe --"
    echo "   Measuring achieved device bandwidth (spec sheet for GB10 is 273 GB/s;"
    echo "   real LPDDR5x sustains 70-85% of spec, which is why this is measured)."
    m_bandwidth
    if [ -z "${BANDWIDTH}" ]; then
        echo "   FAILED. Try a smaller buffer: BUF_GB=1 bash scripts/benchmark.sh bandwidth"
        return 2
    fi
    echo "   achieved: ${BANDWIDTH} GB/s"
    if require_brain 2>/dev/null; then
        m_decode 1 128
        local wpath; wpath=$(get_field brain local_path)
        local wgb=""; [ -d "${wpath}" ] && wgb=$(du -sb "${wpath}" 2>/dev/null | awk '{printf "%.1f", $1/1e9}')
        BANDWIDTH="${BANDWIDTH}" DECODE_TOKS="${DECODE_TOKS}" WGB="${wgb}" python3 -c "
import os
bw, toks = float(os.environ['BANDWIDTH']), float(os.environ['DECODE_TOKS'])
per = bw / toks
print(f'   decode  : {toks:.1f} tok/s')
print(f'   => bytes per token: {per:.1f} GB')
w = os.environ.get('WGB') or ''
if not w:
    raise SystemExit(0)
weights = float(w); ratio = per / weights
print(f'   checkpoint on disk: {weights:.1f} GB   ratio: {ratio:.2f}x')
print('')
if ratio < 1.25:
    print(f'   Weights are read at roughly their quantized width. The roofline is')
    print(f'   REAL: ~{bw/weights:.1f} tok/s single-stream. Config tuning cannot beat it —')
    print('   going faster needs FEWER BYTES (lower-bit quant) or FEWER PASSES')
    print('   (speculative decoding).')
elif ratio < 1.6:
    print('   Somewhat more traffic than the weights occupy. Some is legitimate')
    print('   (KV reads, activations). Check the attention backend and quant')
    print('   kernel before concluding you are at a ceiling.')
else:
    print('   *** MOVING FAR MORE DATA THAN THE WEIGHTS OCCUPY ***')
    print('   This is NOT a bandwidth ceiling, it is a serving-path problem, and')
    print('   ordinary config work has real headroom. Check the quant kernel')
    print('   fallback, the attention backend vs kv_cache_dtype, and CUDA-graph')
    print(f'   state. A correct path would sustain ~{bw/weights:.1f} tok/s.')
"
    fi
}

cmd_audit() {
    require_brain || return 2
    echo ""
    echo "============================================================"
    echo " Serving Audit — declared vs actual"
    echo "============================================================"
    echo "  models.yml declares:"
    printf "    %-24s %s\n" \
        "max_model_len"          "$(get_field brain max_model_len)" \
        "kv_cache_dtype"         "$(get_field brain kv_cache_dtype)" \
        "enable_prefix_caching"  "$(get_field brain enable_prefix_caching)" \
        "attention_backend"      "$(get_field brain attention_backend || true)" \
        "gpu_memory_utilization" "$(get_field brain gpu_memory_utilization)"
    echo ""
    echo ">>> Startup decisions (redacted)"
    brain_logs | grep -iE "attention backend|using .*attn|flashinfer|kv cache dtype|prefix cach|speculative" \
        | head -12 | redact | sed 's/^/    /'
    echo ""
    echo ">>> Measured behaviour"
    m_prefix_reuse
    m_spec_drafted
    validate_runtime ""
    echo "    prefix reuse   : ${PREFIX_REUSE:-?}x  (>=1.8 means prefix caching is live)"
    echo "    tokens drafted : ${SPEC_DRAFTED:-?}   (0 means speculation is configured but dead)"
    echo "    KV cache       : ${KV_TOKENS:-?} tokens vs advertised $(get_field brain max_model_len)"
    echo ""
    local rc=0
    if [ -n "${PREFIX_REUSE}" ] && \
       [ "$(python3 -c "print(1 if ${PREFIX_REUSE} < 1.8 else 0)")" = "1" ] && \
       [ "$(get_field brain enable_prefix_caching)" = "true" ]; then
        echo "  *** enable_prefix_caching is true but reuse is ${PREFIX_REUSE}x."
        echo "  *** The flag is accepted and the feature is NOT taking effect."
        echo "  *** Every agent turn reprocesses the whole conversation prefix."
        rc=1
    fi
    if [ -n "${VALIDATION_NOTE}" ] && [ "${VALIDITY}" != "VALID" ]; then
        echo "  *** ${VALIDATION_NOTE}"
        rc=1
    fi
    [ "${rc}" = "0" ] && echo "  Declared config matches observed behaviour."
    echo "============================================================"
    return ${rc}
}

cmd_matrix() {
    echo ""
    echo "============================================================"
    echo " Config Matrix"
    echo "============================================================"
    echo "  Ledger : ${LEDGER}"
    echo "  Report : ${REPORT}"
    echo "  Runs   : ${RUNS} x ${MAX_TOKENS} tokens per configuration"
    echo ""
    echo "  Brain is restarted once per configuration and is DOWN throughout."
    echo "  Expect hours. Ctrl-C is safe: progress is kept and production"
    echo "  config is restored on exit."
    echo ""
    read -r -p "  Continue? [y/N] " C
    case "${C}" in [yY]|[yY][eE][sS]) ;; *) echo "  Aborted."; return 0 ;; esac

    # spark-watchdog.timer restarts Brain from models.yml whenever the port is
    # silent past its grace window. Mid-matrix that replaces the configuration
    # under test with the committed one and misattributes the results —
    # silently. Worse for SGLang rows: watchdog recovery starts vLLM, swapping
    # the ENGINE out from under a measurement.
    WATCHDOG_WAS_ACTIVE=0
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet spark-watchdog.timer 2>/dev/null; then
        WATCHDOG_WAS_ACTIVE=1
        echo ""
        echo ">>> Stopping spark-watchdog.timer for the duration..."
        sudo systemctl stop spark-watchdog.timer || {
            echo "    ERROR: could not stop the watchdog. It would race the matrix"
            echo "    and misattribute results. Aborting."
            return 1
        }
    fi
    cleanup() {
        echo ""
        echo ">>> Restoring production configuration..."
        restore_production
        if [ "${WATCHDOG_WAS_ACTIVE}" = "1" ]; then
            echo ">>> Restarting spark-watchdog.timer..."
            sudo systemctl start spark-watchdog.timer \
                || echo "    WARN: could not restart the timer — start it manually."
        fi
        echo ">>> Report: ${REPORT}"
    }
    trap cleanup EXIT INT TERM

    mkdir -p "$(dirname "${LEDGER}")"; touch "${LEDGER}"

    while IFS='|' read -r NAME ENGINE OVERRIDES; do
        [ -z "${NAME}" ] && continue
        if [ -n "${ONLY}" ] && ! echo ",${ONLY}," | grep -q ",${NAME},"; then continue; fi
        if [ "${REDO}" = "0" ] && grep -q "\"name\": \"${NAME}\"" "${LEDGER}" 2>/dev/null; then
            echo ""; echo "SKIP ${NAME} — already measured (--redo to repeat)"; continue
        fi

        echo ""
        echo "============================================================"
        echo " ${NAME}   [${ENGINE}]"
        echo "   ${OVERRIDES:-<models.yml as committed>}"
        echo "============================================================"

        VALIDITY=""; VALIDATION_NOTE=""; LAUNCH_NOTE=""
        DECODE_TOKS=""; TTFT_MS=""; AGG_MAX=""; PREFIX_REUSE=""
        SPEC_DRAFTED=""; KV_TOKENS=""; BANDWIDTH=""

        launch_engine "${ENGINE}" "${OVERRIDES}"
        case $? in
            0)  if wait_ready "${READY_TIMEOUT}"; then
                    validate_runtime "${OVERRIDES}"
                    echo "    validity: ${VALIDITY} — ${VALIDATION_NOTE}"
                    m_decode "${RUNS}" "${MAX_TOKENS}"
                    m_concurrency "${STREAMS}" 128
                    [ -z "${PREFIX_REUSE}" ] && m_prefix_reuse
                    [ -z "${SPEC_DRAFTED}" ] && m_spec_drafted
                    echo "    decode ${DECODE_TOKS:-?} tok/s | aggregate ${AGG_MAX:-?} | reuse ${PREFIX_REUSE:-?}x | drafted ${SPEC_DRAFTED:-?}"
                else
                    VALIDITY="FAILED"; VALIDATION_NOTE="${LAUNCH_NOTE}"
                    echo "    FAILED — ${LAUNCH_NOTE}"
                fi ;;
            3)  VALIDITY="BLOCKED"; VALIDATION_NOTE="${LAUNCH_NOTE}"
                echo "    BLOCKED — ${LAUNCH_NOTE}" ;;
            *)  VALIDITY="FAILED";  VALIDATION_NOTE="${LAUNCH_NOTE}"
                echo "    FAILED — ${LAUNCH_NOTE}" ;;
        esac

        ledger_append "${NAME}" "${ENGINE}" "${OVERRIDES}"
        cmd_render >/dev/null 2>&1 || true
    done <<< "${MATRIX}"

    cmd_render
}

case "${CMD}" in
    list)      cmd_list ;;
    render)    cmd_render ;;
    quick)     cmd_quick ;;
    audit)     cmd_audit ;;
    bandwidth) cmd_bandwidth ;;
    matrix)    cmd_matrix ;;
    all)
        # The default: everything needed to fill docs/BENCHMARKS.md.
        # Audit first — it can find a problem that makes the rest moot.
        echo ""
        echo "############################################################"
        echo "# Full benchmark run — audit, then matrix, then report"
        echo "############################################################"
        cmd_audit || echo "  (audit found a mismatch — recorded, continuing)"
        cmd_matrix
        ;;
esac
