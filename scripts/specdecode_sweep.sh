#!/usr/bin/env bash
# =============================================================================
# SPEC-DECODE SWEEP — find the num_speculative_tokens that actually pays
# =============================================================================
# config/models.yml ships '{"method":"mtp","num_speculative_tokens":5}'. That 5
# was never measured against anything; the value the community day-zero recipe
# for this model used is 2. More draft tokens is not monotonically better:
# every REJECTED draft token still costs its share of a verification pass, so
# an over-aggressive draft length can be slower than no speculation at all.
#
# This restarts Brain once per candidate value, benchmarks it, and prints one
# table. Run it, read the table, then set the winner in config/models.yml by
# hand. This script deliberately does NOT edit models.yml — the repo's rule is
# that models.yml is the source of truth a human owns.
#
#   *** THIS TAKES BRAIN DOWN, REPEATEDLY. ***
#   Roughly 4-6 min of model load per candidate plus benchmark time, so the
#   default 4-candidate sweep is ~30 min during which OpenClaw has no brain.
#   Do not run it while you are relying on the box.
#
# Candidates are METHOD:TOKENS pairs, not just token counts, because MTP is
# not the only drafter available and was never compared against the others:
#
#   mtp:N     the checkpoint's own multi-token-prediction heads. What we ship.
#   ngram:N   prompt-lookup decoding. Needs NO drafter and NO extra weights —
#             it proposes continuations by finding repeats of the current
#             suffix earlier in the context. Costs almost nothing to try and
#             is unusually strong on CODE, where the model reproduces long
#             verbatim spans from files already in context. This is a real
#             lever that the first pass at this analysis overlooked entirely.
#   off       no speculation. The control.
#
# Usage:
#   bash scripts/specdecode_sweep.sh                        # the default set
#   VALUES="mtp:2 ngram:5 off" bash scripts/specdecode_sweep.sh
#   RUNS=5 bash scripts/specdecode_sweep.sh                 # more runs each
#   PROMPT="<a real prompt from your workload>" bash scripts/specdecode_sweep.sh
#
# ON THE PROMPT: acceptance rate is workload-dependent, and n-gram especially
# so. The default benchmark prompt writes fresh prose and code from nothing,
# which is close to the WORST case for prompt-lookup. If your actual use is
# agentic coding over files already in context, benchmark THAT — export PROMPT
# with something representative or the table will understate ngram badly.
#
# Always include the `off` control: without it you cannot distinguish a working
# drafter from a fast baseline. If nothing beats the control, speculation is
# not earning its complexity here and dropping speculative_config is a
# legitimate, honest outcome.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true
BRAIN_API_KEY="${BRAIN_API_KEY:-}"

VALUES="${VALUES:-mtp:5 mtp:3 mtp:2 ngram:5 ngram:3 off}"
RUNS="${RUNS:-3}"
MAX_TOKENS="${MAX_TOKENS:-256}"
PROMPT="${PROMPT:-}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"   # 15 min; load is normally 4-5 (LESSONS #14)

# Results land OUTSIDE the repo by default. They used to be written to the repo
# root, which put an untracked file holding container-log excerpts one
# `git add -A` away from being published. Nothing in a results file is supposed
# to be secret — the probe redacts credentials before they are captured — but
# "not supposed to be" is a weaker guarantee than "not in the working tree".
# The repo-root name is gitignored too, for anyone who overrides RESULTS.
RESULTS="${RESULTS:-${TMPDIR:-/tmp}/spark-sovereign-sweep-$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p "$(dirname "${RESULTS}")" 2>/dev/null || true

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

echo ""
echo "============================================================"
echo " Spec-Decode Sweep"
echo "============================================================"
echo "  Candidates : ${VALUES}"
echo "  Benchmark  : ${RUNS} runs x ${MAX_TOKENS} tokens each"
echo "  Results    : ${RESULTS}"
echo ""
echo "  Brain will be restarted once per candidate. Expect ~$(echo "${VALUES}" | wc -w)"
echo "  model loads of 4-6 min each. OpenClaw is down for the duration."
echo ""
read -r -p "  Continue? [y/N] " CONFIRM
case "${CONFIRM}" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "  Aborted."; exit 0 ;;
esac

# -- Keep the watchdog out of the way ----------------------------------------
# spark-watchdog.timer polls every 2 min and restarts Brain from models.yml
# whenever the port is silent past its grace window. During a sweep that would
# race our own restarts and quietly replace an override candidate with the
# committed config — producing a results table that is simply wrong.
# Stopped for the duration, restored on ANY exit path including Ctrl-C.
WATCHDOG_WAS_ACTIVE=0
if command -v systemctl >/dev/null 2>&1 \
   && systemctl is-active --quiet spark-watchdog.timer 2>/dev/null; then
    WATCHDOG_WAS_ACTIVE=1
    echo ""
    echo ">>> Stopping spark-watchdog.timer for the sweep..."
    sudo systemctl stop spark-watchdog.timer || {
        echo "    ERROR: could not stop the watchdog timer."
        echo "    It would race the sweep and corrupt the results. Aborting."
        exit 1
    }
fi

restore_watchdog() {
    if [ "${WATCHDOG_WAS_ACTIVE}" = "1" ]; then
        echo ""
        echo ">>> Restoring spark-watchdog.timer..."
        sudo systemctl start spark-watchdog.timer \
            || echo "    WARN: failed to restart the timer — start it manually."
    fi
}
trap restore_watchdog EXIT INT TERM

# -- Restart Brain with an overridden speculative_config ----------------------
# SPEC_CONFIG_OVERRIDE is read by start_brain_ad_hoc.sh, which is the same
# launcher boot and watchdog recovery use. Going through it rather than a
# bespoke `docker run` here is deliberate: a sweep that measured a
# differently-assembled server would not tell us anything about production.
restart_with() {
    local spec="$1"
    echo ""
    echo ">>> Restarting Brain with speculative_config: ${spec:-<none>}"
    SPEC_CONFIG_OVERRIDE="${spec}" bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh" \
        >/dev/null 2>&1 || { echo "    ERROR: start failed."; return 1; }

    local waited=0
    printf "    waiting for readiness"
    until curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
            "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; do
        if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
            echo ""
            echo "    ERROR: brain container exited. docker logs brain --tail 50"
            return 1
        fi
        if [ "${waited}" -ge "${READY_TIMEOUT}" ]; then
            echo ""
            echo "    ERROR: not ready after ${READY_TIMEOUT}s."
            return 1
        fi
        sleep 10
        waited=$((waited + 10))
        printf "."
    done
    echo " up (${waited}s)"
    return 0
}

: > "${RESULTS}"
{
    echo "spec-decode sweep — $(date -Iseconds)"
    echo "model: ${BRAIN_NAME}   runs: ${RUNS} x ${MAX_TOKENS} tokens"
    echo ""
} >> "${RESULTS}"

# Build the --speculative-config JSON for one METHOD:TOKENS candidate.
# Bare integers are accepted as mtp:N so older invocations keep working.
spec_json_for() {
    local cand="$1" method tokens
    case "${cand}" in
        off) echo ""; return ;;
        *:*) method="${cand%%:*}"; tokens="${cand##*:}" ;;
        *)   method="mtp";         tokens="${cand}" ;;
    esac
    # Token count is interpolated into JSON that becomes a container argument.
    # Constrain it to digits so a malformed VALUES entry fails here, loudly,
    # rather than producing a nonsense config that vLLM then has to reject.
    case "${tokens}" in
        ''|*[!0-9]*) echo "UNSUPPORTED"; return ;;
    esac
    case "${method}" in
        mtp)
            echo "{\"method\":\"mtp\",\"num_speculative_tokens\":${tokens}}"
            ;;
        ngram)
            # prompt_lookup_max bounds how long a matched suffix may be. 4 is
            # the common default; longer matches are rarer but pay more when
            # they hit. Tune it separately once a method has been chosen.
            echo "{\"method\":\"ngram\",\"num_speculative_tokens\":${tokens},\"prompt_lookup_max\":4}"
            ;;
        *)
            echo "UNSUPPORTED"
            ;;
    esac
}

for v in ${VALUES}; do
    SPEC=$(spec_json_for "${v}")
    if [ "${SPEC}" = "UNSUPPORTED" ]; then
        echo ""
        echo "  SKIP ${v}: unknown method. Use mtp:N, ngram:N, or off."
        continue
    fi

    echo ""
    echo "============================================================"
    echo " Candidate: ${v}"
    echo "   speculative_config: ${SPEC:-<none — control>}"
    echo "============================================================"

    if ! restart_with "${SPEC}"; then
        # A method the running vLLM build does not implement fails HERE, at
        # startup, not silently at runtime — which is the useful direction.
        echo "  FAILED to bring Brain up for candidate ${v}."
        echo "  If this is a method rather than a token count, the build may"
        echo "  not support it: docker logs brain --tail 50"
        echo "${v}  FAILED TO START" >> "${RESULTS}"
        continue
    fi

    # A cold server's first tokens include CUDA-graph capture and cache warmup.
    # Benchmarking that measures startup, not steady state — so throw one away.
    echo "    warmup run (discarded)..."
    RUNS=1 MAX_TOKENS=64 bash "${REPO_ROOT}/scripts/benchmark_brain.sh" >/dev/null 2>&1 || true

    echo ""
    # PROMPT is passed through the environment rather than as a command
    # prefix: a realistic benchmark prompt contains spaces, and an unquoted
    # ${PROMPT:+...} prefix would word-split it into garbage.
    if [ -n "${PROMPT}" ]; then
        BENCH=$(RUNS="${RUNS}" MAX_TOKENS="${MAX_TOKENS}" PROMPT="${PROMPT}" \
                bash "${REPO_ROOT}/scripts/benchmark_brain.sh" 2>&1)
    else
        BENCH=$(RUNS="${RUNS}" MAX_TOKENS="${MAX_TOKENS}" \
                bash "${REPO_ROOT}/scripts/benchmark_brain.sh" 2>&1)
    fi
    echo "${BENCH}"

    PROBE=$(bash "${REPO_ROOT}/scripts/specdecode_probe.sh" 2>&1 || true)

    {
        echo "------------------------------------------------------------"
        echo "candidate: ${v}   config: ${SPEC:-<none — control>}"
        echo "${BENCH}"        | grep -iE "tok/s|ttft|median" || true
        echo "${PROBE}"        | grep -iE "acceptance rate|accepted per step|implied speedup|ZERO DRAFT" || true
        echo ""
    } >> "${RESULTS}"
done

# -- Put production back exactly as models.yml describes ---------------------
# The loop leaves Brain running whatever the LAST candidate was, which is
# almost never the winner. Restoring here means an interrupted or forgotten
# sweep cannot silently leave the box serving an experimental config.
echo ""
echo "============================================================"
echo ">>> Restoring Brain from config/models.yml..."
restart_with "$(get_field brain speculative_config)" || \
    echo "    WARN: restore failed — run scripts/start_brain_ad_hoc.sh yourself."

echo ""
echo "============================================================"
echo " Sweep complete. Full table: ${RESULTS}"
echo "============================================================"
cat "${RESULTS}"
echo ""
echo " Reading it:"
echo "   - Compare every candidate against the 'off' control."
echo "   - A candidate that does not clearly beat 'off' is not earning its"
echo "     complexity. Deleting speculative_config is a legitimate outcome."
echo "   - If mtp and ngram both fail to beat the control, the drafters are"
echo "     not the constraint. Run scripts/bandwidth_probe.sh next: it says"
echo "     whether the box is genuinely at its bandwidth ceiling or whether"
echo "     the serving path is moving more bytes than the weights occupy."
echo "   - Acceptance is workload-dependent. A poor ngram result against the"
echo "     default prompt does NOT generalise to your agentic coding load —"
echo "     re-run with PROMPT set to something representative before ruling"
echo "     it out."
echo ""
echo " Set the winner by hand in config/models.yml, then:"
echo "   bash scripts/start_brain_ad_hoc.sh"
