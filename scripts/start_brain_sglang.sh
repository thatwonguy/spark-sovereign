#!/usr/bin/env bash
# =============================================================================
# SGLang Brain launcher — the second engine, for head-to-head comparison
# =============================================================================
# Mirrors start_brain_ad_hoc.sh, but starts SGLang instead of vLLM. It exists
# because the strongest reported throughput configs for this model on this
# hardware run SGLang (DFlash2 drafters), and a comparison matrix that could
# only launch vLLM would be structurally incapable of finding that out. An
# engine excluded from the test is an engine assumed worse.
#
# What transfers and what does not:
#   MEASUREMENT is engine-agnostic. SGLang serves the same OpenAI-compatible
#   /v1 surface, so benchmark_brain.sh, benchmark_concurrency.sh, and the
#   prefix-cache TTFT test in serving_audit.sh all work against it unchanged.
#   That is what makes a fair comparison possible at all.
#
#   LAUNCH and VALIDATION are engine-specific. Flag names differ, the metrics
#   endpoint differs, and the startup log says different things. That is what
#   this script and the sglang branch of config_matrix.sh handle.
#
# REQUIRES an sglang: block in config/models.yml with a docker_image pinned to
# a build that runs on GB10 (SM121, arm64). This repo does not ship one,
# because no image has been verified here. If it is missing this script says
# so plainly and exits 3 — it does not guess an image tag, and the matrix
# records the scenario as BLOCKED rather than silently skipping it.
#
# Usage:
#   bash scripts/start_brain_sglang.sh
#   OVERRIDE_speculative_config='...' bash scripts/start_brain_sglang.sh
#
# Same OVERRIDE_<field> convention as start_brain_ad_hoc.sh, read from the
# sglang: block.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"
BRAIN_API_KEY="${BRAIN_API_KEY:-}"

get_field() {
    local ov="OVERRIDE_$2"
    if [ -n "${!ov+set}" ]; then
        printf '%s\n' "${!ov}"
        return
    fi
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

get_extra_env_flags() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
env = cfg.get('$1', {}).get('extra_env', {}) or {}
for k, v in env.items():
    print(f'-e {k}={v}')
" 2>/dev/null || true
}

SG_IMAGE=$(get_field sglang docker_image)

if [ -z "${SG_IMAGE}" ]; then
    cat <<'EOF'
ERROR: no SGLang image configured.

  config/models.yml has no `sglang:` block with a docker_image, so there is
  nothing to start. This is deliberate — no SGLang build has been verified on
  GB10 here, and guessing a tag would waste a 5-minute load to find that out.

  To enable the SGLang half of the comparison, uncomment the sglang: block in
  config/models.yml and pin an image that runs on SM121 / arm64. Then:

      bash scripts/config_matrix.sh

  Until then the matrix records every SGLang scenario as BLOCKED, with this
  reason, so the gap is visible in docs/BENCHMARKS.md rather than silently
  absent from the results.
EOF
    exit 3
fi

# The brain model files are shared between engines — same weights, same path.
SG_PATH=$(get_field brain local_path)
SG_NAME=$(get_field sglang served_name);   SG_NAME="${SG_NAME:-$(get_field brain served_name)}"
SG_PORT=$(get_field sglang port);          SG_PORT="${SG_PORT:-$(get_field brain port)}"
SG_HOST=$(get_field sglang bind_host);     SG_HOST="${SG_HOST:-127.0.0.1}"
SG_UTIL=$(get_field sglang mem_fraction_static)
SG_UTIL="${SG_UTIL:-$(get_field brain gpu_memory_utilization)}"
SG_CTX=$(get_field sglang max_model_len);  SG_CTX="${SG_CTX:-$(get_field brain max_model_len)}"
SG_QUANT=$(get_field sglang quantization)
SG_ATTN=$(get_field sglang attention_backend)
SG_SPEC_ALGO=$(get_field sglang speculative_algorithm)
SG_SPEC_STEPS=$(get_field sglang speculative_num_steps)
SG_SPEC_DRAFT=$(get_field sglang speculative_draft_model_path)
SG_TOOL=$(get_field sglang tool_call_parser)
SG_REASON=$(get_field sglang reasoning_parser)
SG_DISABLE_RADIX=$(get_field sglang disable_radix_cache)
SG_EXTRA_ENV=$(get_extra_env_flags sglang)

echo ">>> Stopping existing Brain container..."
for name in brain qwen-brain; do
    if docker ps -q --filter "name=^${name}$" | grep -q .; then
        docker stop "${name}" 2>/dev/null && echo "    stopped ${name}" || true
    fi
    docker rm -f "${name}" 2>/dev/null || true
done

echo ">>> Starting Brain (SGLang): ${SG_NAME} on port ${SG_PORT}"

# SGLang's prefix cache is the radix cache and is ON by default — the inverse
# of vLLM's flag. So the knob here is a DISABLE, and leaving it unset is the
# cached path. Worth stating because the two engines' defaults differ in the
# exact dimension this matrix is testing.
# shellcheck disable=SC2086
docker run -d --name brain \
    --gpus all --ipc host --network host \
    --restart no \
    ${BRAIN_API_KEY:+-e SGLANG_API_KEY="${BRAIN_API_KEY}"} \
    ${SG_EXTRA_ENV} \
    -v "${MODELS_DIR}:/models" \
    -v sglang-cache:/root/.cache \
    "${SG_IMAGE}" \
        python3 -m sglang.launch_server \
        --model-path "/models/$(basename "${SG_PATH}")" \
        --served-model-name "${SG_NAME}" \
        --host "${SG_HOST}" --port "${SG_PORT}" \
        --mem-fraction-static "${SG_UTIL}" \
        --context-length "${SG_CTX}" \
        --trust-remote-code \
        ${SG_QUANT:+--quantization "${SG_QUANT}"} \
        ${SG_ATTN:+--attention-backend "${SG_ATTN}"} \
        ${SG_SPEC_ALGO:+--speculative-algorithm "${SG_SPEC_ALGO}"} \
        ${SG_SPEC_STEPS:+--speculative-num-steps "${SG_SPEC_STEPS}"} \
        ${SG_SPEC_DRAFT:+--speculative-draft-model-path "${SG_SPEC_DRAFT}"} \
        ${SG_TOOL:+--tool-call-parser "${SG_TOOL}"} \
        ${SG_REASON:+--reasoning-parser "${SG_REASON}"} \
        $([ "${SG_DISABLE_RADIX}" = "true" ] && echo "--disable-radix-cache")

echo "    brain started (SGLang) → http://localhost:${SG_PORT}/v1"
echo "    Watch: docker logs brain -f"
echo ""
echo "    NOTE: this container is named 'brain', the same as the vLLM one, so"
echo "    watchdog.sh sees it and health checks keep working. But watchdog"
echo "    recovery calls start_brain_ad_hoc.sh, which starts vLLM — so a"
echo "    crash while running SGLang silently reverts the engine. Stop the"
echo "    watchdog timer for the duration of any SGLang session."
