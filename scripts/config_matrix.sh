#!/usr/bin/env bash
# =============================================================================
# CONFIG MATRIX — systematically determine what actually works on this box
# =============================================================================
#
#   *** AD-HOC ONLY. NOT PART OF ANY SEQUENCE. ***
#
#   Nothing calls this script. It is not in boot_sequence.sh, not in
#   watchdog.sh, not in the numbered 00-04 setup path, and it must never be
#   added to them. It takes Brain down repeatedly for hours and is run by a
#   human who has decided to spend that time. Deliberately unnumbered so it
#   cannot be mistaken for a setup step.
#
# WHAT IT DOES, per configuration:
#   1. CHECK    — resolve the parameter set, skip if already measured
#   2. LAUNCH   — start Brain through the SAME launcher production uses
#   3. VALIDATE — confirm the parameters ACTUALLY TOOK EFFECT
#   4. MEASURE  — throughput, TTFT, prefix-cache reuse, spec-decode acceptance
#   5. RECORD   — append a row, regenerate docs/BENCHMARKS.md
#
# Step 3 is the reason this exists rather than a for-loop around a benchmark.
# vLLM accepts flags it then silently ignores — that is the documented failure
# mode for prefix caching on this model. A benchmark of a config that did not
# apply produces a real number attributed to the wrong cause, which is worse
# than no number at all, because it looks like evidence. Every run is stamped
# VALID / PARTIAL / INVALID, and only VALID runs are ranked.
#
# RESUMABLE. Each configuration costs a 4-6 min model load plus benchmark
# time, so a full matrix runs for hours. Results append to a JSONL ledger and
# already-measured configurations are skipped on re-run. Ctrl-C is safe: the
# ledger is durable and production config is restored on every exit path.
#
# OUTPUT — docs/BENCHMARKS.md, written for a future reader (including an LLM)
# who was not present for any of this. It records what was tested, what the
# result was, whether the run was trustworthy, and what to actually use. The
# JSONL beside it is the raw ledger the Markdown is regenerated from; edit
# neither by hand.
#
# Usage:
#   bash scripts/config_matrix.sh                  # default matrix, resumes
#   bash scripts/config_matrix.sh --list           # show the matrix, run nothing
#   bash scripts/config_matrix.sh --only baseline,attn-flashinfer
#   bash scripts/config_matrix.sh --redo           # ignore the ledger, re-measure
#   RUNS=5 bash scripts/config_matrix.sh           # more benchmark runs each
#
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true
BRAIN_API_KEY="${BRAIN_API_KEY:-}"

LEDGER="${LEDGER:-${REPO_ROOT}/docs/benchmarks.jsonl}"
REPORT="${REPORT:-${REPO_ROOT}/docs/BENCHMARKS.md}"
RUNS="${RUNS:-3}"
MAX_TOKENS="${MAX_TOKENS:-256}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"
CONCURRENCY_STREAMS="${CONCURRENCY_STREAMS:-1 4 8}"

ONLY=""
REDO=0
LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --redo) REDO=1; shift ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1"; exit 1 ;;
    esac
done

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
if isinstance(val, bool):
    val = str(val).lower()
print(val if val is not None else '')
"
}

BRAIN_PORT=$(get_field brain port)
BRAIN_NAME=$(get_field brain served_name)

# =============================================================================
# THE MATRIX
# =============================================================================
# Format:  name | engine | space-separated OVERRIDE_field=value pairs
#
# ONE FACTOR AT A TIME from the baseline, deliberately, not a full cross
# product. A full product of 5 parameters is hundreds of hours of model loads
# and still would not tell you WHICH factor moved the number. OFAT attributes
# cause. The exceptions are the pairs marked INTERACTION, included because
# those two settings are known to trade against each other and testing them
# separately would be misleading.
#
# An empty value UNSETS the field (e.g. speculative_config= means no
# speculation), which is distinct from not naming the field at all.
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
INTERACTION-triton-fp8kv-util080|vllm|OVERRIDE_attention_backend=TRITON_ATTN OVERRIDE_gpu_memory_utilization=0.80
sglang-baseline|sglang|
sglang-radix-off|sglang|OVERRIDE_disable_radix_cache=true
EOF
)

if [ "${LIST_ONLY}" = "1" ]; then
    echo ""
    echo "Configurations in the matrix:"
    echo "${MATRIX}" | while IFS='|' read -r name engine overrides; do
        [ -z "${name}" ] && continue
        printf "  %-32s %-7s %s\n" "${name}" "[${engine}]" "${overrides:-<models.yml as committed>}"
    done
    echo ""
    echo "Already measured (in ${LEDGER}):"
    if [ -f "${LEDGER}" ]; then
        python3 -c "
import json,sys
for line in open('${LEDGER}', encoding='utf-8'):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    print(f\"  {r.get('name','?'):<32} {r.get('validity','?'):<8} {r.get('decode_toks','?')} tok/s\")
"
    else
        echo "  (none yet)"
    fi
    exit 0
fi

# =============================================================================
# Watchdog containment
# =============================================================================
# spark-watchdog.timer restarts Brain from models.yml whenever the port is
# silent past its grace window. Mid-matrix that would replace the configuration
# under test with the committed one and attribute the resulting numbers to the
# wrong config — silently. Worse for the SGLang scenarios: watchdog recovery
# calls start_brain_ad_hoc.sh, which starts vLLM, so a crash would swap the
# ENGINE out from under a measurement.
WATCHDOG_WAS_ACTIVE=0
if command -v systemctl >/dev/null 2>&1 \
   && systemctl is-active --quiet spark-watchdog.timer 2>/dev/null; then
    WATCHDOG_WAS_ACTIVE=1
fi

restore_everything() {
    echo ""
    echo ">>> Restoring production configuration from config/models.yml..."
    ( unset "${!OVERRIDE_@}" 2>/dev/null || true
      bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh" >/dev/null 2>&1 ) \
        || echo "    WARN: restore failed — run scripts/start_brain_ad_hoc.sh yourself."
    if [ "${WATCHDOG_WAS_ACTIVE}" = "1" ]; then
        echo ">>> Restarting spark-watchdog.timer..."
        sudo systemctl start spark-watchdog.timer \
            || echo "    WARN: could not restart the timer — start it manually."
    fi
    echo ">>> Report: ${REPORT}"
}

# =============================================================================
# Per-configuration steps
# =============================================================================

# 2. LAUNCH — through the engine's real launcher, never a bespoke docker run.
launch() {
    local engine="$1" overrides="$2" launcher
    case "${engine}" in
        vllm)   launcher="${REPO_ROOT}/scripts/start_brain_ad_hoc.sh" ;;
        sglang) launcher="${REPO_ROOT}/scripts/start_brain_sglang.sh" ;;
        *)      echo "unknown engine ${engine}"; return 4 ;;
    esac

    # Overrides are exported into a subshell only, so nothing leaks between
    # configurations or outlives the script.
    (
        for kv in ${overrides}; do
            export "${kv?}"
        done
        bash "${launcher}"
    ) >/tmp/launch.$$ 2>&1
    local rc=$?
    if [ ${rc} -eq 3 ]; then
        LAUNCH_NOTE=$(grep -m1 "ERROR:" /tmp/launch.$$ || echo "engine not configured")
        rm -f /tmp/launch.$$
        return 3
    fi
    if [ ${rc} -ne 0 ]; then
        LAUNCH_NOTE=$(tail -3 /tmp/launch.$$ | tr '\n' ' ')
        rm -f /tmp/launch.$$
        return 1
    fi
    rm -f /tmp/launch.$$

    local waited=0
    printf "    loading"
    until curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
            "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; do
        if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
            echo ""
            LAUNCH_NOTE="container exited during load: $(docker logs brain 2>&1 | tail -2 | tr '\n' ' ')"
            return 1
        fi
        if [ "${waited}" -ge "${READY_TIMEOUT}" ]; then
            echo ""
            LAUNCH_NOTE="not ready after ${READY_TIMEOUT}s"
            return 1
        fi
        sleep 10; waited=$((waited + 10)); printf "."
    done
    echo " up (${waited}s)"
    return 0
}

# 3. VALIDATE — did the parameters actually take effect?
# Returns a validity verdict and a human-readable note. This is what separates
# a measurement from a number.
validate() {
    local overrides="$1"
    VALIDATION_NOTE=""
    local problems=0 checks=0

    local logs; logs=$(docker logs brain 2>&1 | head -600 || echo "")

    for kv in ${overrides}; do
        local field="${kv%%=*}"; field="${field#OVERRIDE_}"
        local want="${kv#*=}"
        checks=$((checks + 1))
        case "${field}" in
            enable_prefix_caching)
                # Measured, not read: the flag can be accepted and inert.
                local sp; sp=$(measure_prefix_cache)
                local on; on=$(python3 -c "print('yes' if ${sp:-0} >= 1.8 else 'no')")
                local want_on="yes"; [ "${want}" = "false" ] && want_on="no"
                if [ "${on}" != "${want_on}" ]; then
                    VALIDATION_NOTE+="prefix_caching requested=${want} observed_reuse=${on}(${sp}x); "
                    problems=$((problems + 1))
                fi
                ;;
            attention_backend)
                if [ -n "${want}" ] && ! echo "${logs}" | grep -qi "${want%%_*}"; then
                    VALIDATION_NOTE+="attention_backend=${want} not confirmed in log; "
                    problems=$((problems + 1))
                fi
                ;;
            kv_cache_dtype)
                if [ "${want}" = "fp8" ] && ! echo "${logs}" | grep -qiE "kv.cache.dtype.*fp8"; then
                    VALIDATION_NOTE+="kv_cache_dtype=fp8 not confirmed in log; "
                    problems=$((problems + 1))
                fi
                ;;
            speculative_config)
                local drafted; drafted=$(spec_drafted_tokens)
                if [ -z "${want}" ]; then
                    [ "${drafted:-0}" != "0" ] && {
                        VALIDATION_NOTE+="speculation requested OFF but ${drafted} tokens drafted; "
                        problems=$((problems + 1)); }
                else
                    [ "${drafted:-0}" = "0" ] && {
                        VALIDATION_NOTE+="speculation configured but ZERO tokens drafted; "
                        problems=$((problems + 1)); }
                fi
                ;;
        esac
    done

    # Always check the advertised context is reachable, every run.
    local kvtok
    kvtok=$(echo "${logs}" | grep -ioE "GPU KV cache size: *[0-9,]+" | grep -oE "[0-9,]+" | tr -d ',' | head -1)
    local ctx; ctx=$(get_field brain max_model_len)
    if [ -n "${kvtok}" ] && [ -n "${ctx}" ] && [ "${kvtok}" -lt "${ctx}" ]; then
        VALIDATION_NOTE+="KV cache holds ${kvtok} tokens < advertised max_model_len ${ctx}; "
        problems=$((problems + 1))
    fi
    KV_TOKENS="${kvtok:-}"

    if [ "${problems}" = "0" ]; then
        VALIDITY="VALID"
        VALIDATION_NOTE="all ${checks} requested parameter(s) confirmed in effect"
    elif [ "${problems}" -lt "$((checks + 1))" ]; then
        VALIDITY="PARTIAL"
    else
        VALIDITY="INVALID"
    fi
}

# Prefix-cache reuse ratio: same long prefix, different tails, compare TTFT.
measure_prefix_cache() {
    BASE="http://localhost:${BRAIN_PORT}" BRAIN_NAME="${BRAIN_NAME}" \
    BRAIN_API_KEY="${BRAIN_API_KEY}" python3 - <<'PYEOF' 2>/dev/null || echo ""
import json, os, time, urllib.request
base, model, key = os.environ["BASE"], os.environ["BRAIN_NAME"], os.environ["BRAIN_API_KEY"]
prefix = ("Review this module.\n\n" + "\n".join(
    f"def function_{i}(a, b):\n    return a * {i} + b\n" for i in range(400)))
def ask(tail):
    body = {"model": model, "max_tokens": 8, "stream": True, "temperature": 0,
            "messages": [{"role": "user", "content": prefix + "\n\n" + tail}]}
    req = urllib.request.Request(f"{base}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            s = raw.decode("utf-8", "replace").strip()
            if s.startswith("data: ") and s[6:] != "[DONE]":
                try: c = json.loads(s[6:])
                except Exception: continue
                if c.get("choices"):
                    d = c["choices"][0].get("delta") or {}
                    if d.get("content") or d.get("reasoning") or d.get("reasoning_content"):
                        return time.perf_counter() - t0
    return time.perf_counter() - t0
cold = ask("Summarise function_1."); warm = ask("Summarise function_2.")
print(f"{cold/warm:.2f}" if warm > 0 else "")
PYEOF
}

# Draft tokens emitted during one generation — the spec-decode liveness check.
spec_drafted_tokens() {
    local before after
    before=$(curl -sf --max-time 10 "http://localhost:${BRAIN_PORT}/metrics" 2>/dev/null \
             | grep -E "^vllm:spec_decode_num_draft_tokens" | awk '{s+=$2} END{print s+0}')
    curl -sf --max-time 300 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
        -H "Content-Type: application/json" \
        -X POST "http://localhost:${BRAIN_PORT}/v1/chat/completions" \
        -d "{\"model\":\"${BRAIN_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a quicksort in Python.\"}],\"max_tokens\":128}" \
        >/dev/null 2>&1
    after=$(curl -sf --max-time 10 "http://localhost:${BRAIN_PORT}/metrics" 2>/dev/null \
            | grep -E "^vllm:spec_decode_num_draft_tokens" | awk '{s+=$2} END{print s+0}')
    python3 -c "print(int(${after:-0} - ${before:-0}))" 2>/dev/null || echo 0
}

# 4. MEASURE
measure() {
    local bench
    bench=$(RUNS="${RUNS}" MAX_TOKENS="${MAX_TOKENS}" \
            bash "${REPO_ROOT}/scripts/benchmark_brain.sh" 2>&1)
    DECODE_TOKS=$(echo "${bench}" | grep -ioE '[0-9]+\.[0-9]+ tok/s' | head -1 | grep -oE '[0-9.]+')
    TTFT_MS=$(echo "${bench}" | grep -ioE '[0-9]+(\.[0-9]+)? ?ms' | head -1 | grep -oE '[0-9.]+')

    local conc
    conc=$(STREAMS="${CONCURRENCY_STREAMS}" MAX_TOKENS=128 \
           bash "${REPO_ROOT}/scripts/benchmark_concurrency.sh" 2>&1)
    AGG_MAX=$(echo "${conc}" | grep -oE '^\s+[0-9]+\s+[0-9]+\.[0-9]+ tok/s' \
              | grep -oE '[0-9]+\.[0-9]+' | sort -g | tail -1)
    PREFIX_SPEEDUP=$(measure_prefix_cache)
    SPEC_DRAFTED=$(spec_drafted_tokens)
}

# =============================================================================
# Main loop
# =============================================================================
mkdir -p "$(dirname "${LEDGER}")"
touch "${LEDGER}"

already_done() {
    [ "${REDO}" = "1" ] && return 1
    grep -q "\"name\": \"$1\"" "${LEDGER}" 2>/dev/null
}

echo ""
echo "============================================================"
echo " Config Matrix — ad-hoc, not part of any sequence"
echo "============================================================"
echo "  Ledger : ${LEDGER}"
echo "  Report : ${REPORT}"
echo "  Runs   : ${RUNS} x ${MAX_TOKENS} tokens per configuration"
echo ""
echo "  Brain will be restarted once per configuration and is DOWN"
echo "  throughout. Expect hours. Ctrl-C is safe — progress is kept"
echo "  and production config is restored on exit."
echo ""
read -r -p "  Continue? [y/N] " CONFIRM
case "${CONFIRM}" in [yY]|[yY][eE][sS]) ;; *) echo "  Aborted."; exit 0 ;; esac

if [ "${WATCHDOG_WAS_ACTIVE}" = "1" ]; then
    echo ""
    echo ">>> Stopping spark-watchdog.timer for the duration..."
    sudo systemctl stop spark-watchdog.timer || {
        echo "    ERROR: could not stop the watchdog. It would race the matrix"
        echo "    and misattribute results. Aborting."
        exit 1
    }
fi
trap restore_everything EXIT INT TERM

while IFS='|' read -r NAME ENGINE OVERRIDES; do
    [ -z "${NAME}" ] && continue
    if [ -n "${ONLY}" ] && ! echo ",${ONLY}," | grep -q ",${NAME},"; then continue; fi
    if already_done "${NAME}"; then
        echo ""
        echo "SKIP ${NAME} — already in the ledger (--redo to re-measure)"
        continue
    fi

    echo ""
    echo "============================================================"
    echo " ${NAME}   [${ENGINE}]"
    echo "   ${OVERRIDES:-<models.yml as committed>}"
    echo "============================================================"

    VALIDITY=""; VALIDATION_NOTE=""; LAUNCH_NOTE=""
    DECODE_TOKS=""; TTFT_MS=""; AGG_MAX=""; PREFIX_SPEEDUP=""; SPEC_DRAFTED=""; KV_TOKENS=""

    launch "${ENGINE}" "${OVERRIDES}"
    case $? in
        0) validate "${OVERRIDES}"
           echo "    validity: ${VALIDITY} — ${VALIDATION_NOTE}"
           measure
           echo "    decode: ${DECODE_TOKS:-?} tok/s   prefix-reuse: ${PREFIX_SPEEDUP:-?}x   drafted: ${SPEC_DRAFTED:-?}"
           ;;
        3) VALIDITY="BLOCKED"; VALIDATION_NOTE="${LAUNCH_NOTE}"
           echo "    BLOCKED — ${LAUNCH_NOTE}" ;;
        *) VALIDITY="FAILED";  VALIDATION_NOTE="${LAUNCH_NOTE}"
           echo "    FAILED — ${LAUNCH_NOTE}" ;;
    esac

    NAME="${NAME}" ENGINE="${ENGINE}" OVERRIDES="${OVERRIDES}" \
    VALIDITY="${VALIDITY}" VALIDATION_NOTE="${VALIDATION_NOTE}" \
    DECODE_TOKS="${DECODE_TOKS}" TTFT_MS="${TTFT_MS}" AGG_MAX="${AGG_MAX}" \
    PREFIX_SPEEDUP="${PREFIX_SPEEDUP}" SPEC_DRAFTED="${SPEC_DRAFTED}" \
    KV_TOKENS="${KV_TOKENS}" RUNS="${RUNS}" MAX_TOKENS="${MAX_TOKENS}" \
    python3 -c "
import json, os, datetime
def num(k):
    v = os.environ.get(k, '')
    try: return float(v)
    except (TypeError, ValueError): return None
rec = {
    'name': os.environ['NAME'],
    'engine': os.environ['ENGINE'],
    'overrides': os.environ['OVERRIDES'].strip(),
    'validity': os.environ['VALIDITY'],
    'note': os.environ['VALIDATION_NOTE'].strip(),
    'decode_toks': num('DECODE_TOKS'),
    'ttft_ms': num('TTFT_MS'),
    'aggregate_toks': num('AGG_MAX'),
    'prefix_reuse_x': num('PREFIX_SPEEDUP'),
    'spec_drafted': num('SPEC_DRAFTED'),
    'kv_cache_tokens': num('KV_TOKENS'),
    'runs': int(os.environ['RUNS']), 'max_tokens': int(os.environ['MAX_TOKENS']),
    'measured_at': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
}
with open('${LEDGER}', 'a', encoding='utf-8') as f:
    f.write(json.dumps(rec) + '\n')
"
    bash "${REPO_ROOT}/scripts/render_benchmarks.sh" >/dev/null 2>&1 || true
done <<< "${MATRIX}"

bash "${REPO_ROOT}/scripts/render_benchmarks.sh"
echo ""
echo "============================================================"
echo " Matrix complete. Report: ${REPORT}"
echo "============================================================"
