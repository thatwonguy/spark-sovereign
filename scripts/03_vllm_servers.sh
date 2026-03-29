#!/usr/bin/env bash
# =============================================================================
# PHASE 3 — vLLM Inference Servers
# =============================================================================
# Starts Brain (port 8000) and Sub-agent (port 8001) containers.
# All settings driven from config/models.yml.
# To swap a model: edit models.yml → restart with this script.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"

# Helper: read field from models.yml
get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
print(val if val is not None else '')
"
}

# Build --env flags from models.yml extra_env dict
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

echo "========================================================"
echo " spark-sovereign — Phase 3: vLLM Inference Servers"
echo "========================================================"

# ── Brain model ──────────────────────────────────────────────────────────────
BRAIN_IMAGE=$(get_field brain docker_image)
BRAIN_PATH=$(get_field brain local_path)
BRAIN_NAME=$(get_field brain served_name)
BRAIN_PORT=$(get_field brain port)
BRAIN_UTIL=$(get_field brain gpu_memory_utilization)
BRAIN_CTX=$(get_field brain max_model_len)
BRAIN_KV=$(get_field brain kv_cache_dtype)
BRAIN_SEQS=$(get_field brain max_num_seqs)
BRAIN_TOOL=$(get_field brain tool_call_parser)
BRAIN_REASON=$(get_field brain reasoning_parser)
BRAIN_EXTRA_ENV=$(get_extra_env_flags brain)

echo ""
echo ">>> Starting Brain: ${BRAIN_NAME} on port ${BRAIN_PORT}"

# Remove current and any legacy container names from previous model swaps
docker rm -f brain qwen-brain 2>/dev/null || true

# shellcheck disable=SC2086
docker run -d --name brain \
    --gpus all --ipc host --network host \
    --restart no \
    ${BRAIN_EXTRA_ENV} \
    -v "${MODELS_DIR}:/models" \
    "${BRAIN_IMAGE}" \
    vllm serve "/models/$(basename "${BRAIN_PATH}")" \
        --served-model-name "${BRAIN_NAME}" \
        --host 0.0.0.0 --port "${BRAIN_PORT}" \
        --gpu-memory-utilization "${BRAIN_UTIL}" \
        --max-model-len "${BRAIN_CTX}" \
        --kv-cache-dtype "${BRAIN_KV}" \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser "${BRAIN_TOOL}" \
        --reasoning-parser "${BRAIN_REASON}" \
        --enable-prefix-caching \
        --max-num-seqs "${BRAIN_SEQS}"

echo "    Container 'brain' started → http://localhost:${BRAIN_PORT}/v1"

# ── Sub-agent model ───────────────────────────────────────────────────────────
NANO_IMAGE=$(get_field subagent docker_image)
NANO_PATH=$(get_field subagent local_path)
NANO_NAME=$(get_field subagent served_name)
NANO_PORT=$(get_field subagent port)
NANO_UTIL=$(get_field subagent gpu_memory_utilization)
NANO_CTX=$(get_field subagent max_model_len)
NANO_KV=$(get_field subagent kv_cache_dtype)
NANO_SEQS=$(get_field subagent max_num_seqs)
NANO_TOOL=$(get_field subagent tool_call_parser)
NANO_REASON=$(get_field subagent reasoning_parser)
NANO_PLUGIN=$(get_field subagent reasoning_parser_plugin)

echo ""
echo ">>> Starting Sub-agent: ${NANO_NAME} on port ${NANO_PORT}"

docker rm -f nemotron-nano 2>/dev/null || true

# Mount plugin file if it exists in the model directory
PLUGIN_MOUNT=""
PLUGIN_FLAG=""
if [ -n "${NANO_PLUGIN}" ]; then
    PLUGIN_SRC="${MODELS_DIR}/$(basename "${NANO_PATH}")/${NANO_PLUGIN}"
    if [ -f "${PLUGIN_SRC}" ]; then
        PLUGIN_MOUNT="-v ${PLUGIN_SRC}:/workspace/${NANO_PLUGIN}"
        PLUGIN_FLAG="--reasoning-parser-plugin /workspace/${NANO_PLUGIN}"
        echo "    Plugin found: ${PLUGIN_SRC}"
    else
        echo "    Plugin ${NANO_PLUGIN} not found in model dir — skipping reasoning-parser-plugin"
    fi
fi

docker run -d --name nemotron-nano \
    --gpus all --ipc host --network host \
    --restart no \
    -v "${MODELS_DIR}:/models" \
    ${PLUGIN_MOUNT} \
    "${NANO_IMAGE}" \
    vllm serve "/models/$(basename "${NANO_PATH}")" \
        --served-model-name "${NANO_NAME}" \
        --host 0.0.0.0 --port "${NANO_PORT}" \
        --gpu-memory-utilization "${NANO_UTIL}" \
        --max-model-len "${NANO_CTX}" \
        --kv-cache-dtype "${NANO_KV}" \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser "${NANO_TOOL}" \
        --reasoning-parser "${NANO_REASON}" \
        ${PLUGIN_FLAG} \
        --enable-prefix-caching \
        --max-num-seqs "${NANO_SEQS}"

echo "    Container 'nemotron-nano' started → http://localhost:${NANO_PORT}/v1"

# ── Memory summary ────────────────────────────────────────────────────────────
echo ""
echo "Memory allocation:"

brain_gb="$(python3 - "${BRAIN_UTIL:-0.60}" <<'PY'
import sys
try:
    util = float(sys.argv[1])
except Exception:
    util = 0.60
print(round(128 * util))
PY
)"

nano_gb="$(python3 - "${NANO_UTIL:-0.18}" <<'PY'
import sys
try:
    util = float(sys.argv[1])
except Exception:
    util = 0.18
print(round(128 * util))
PY
)"

echo "  Brain   util=${BRAIN_UTIL:-0.40} → ~${brain_gb} GB"
echo "  Nano    util=${NANO_UTIL:-0.18} → ~${nano_gb} GB"
echo ""
echo "Waiting for models to load (checking every 15s)..."

for i in $(seq 1 20); do
    sleep 15
    B_STATUS=$(curl -sf "http://localhost:${BRAIN_PORT}/v1/models" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print('OK' if d['data'] else 'LOADING')" \
        2>/dev/null || echo "LOADING")
    N_STATUS=$(curl -sf "http://localhost:${NANO_PORT}/v1/models" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print('OK' if d['data'] else 'LOADING')" \
        2>/dev/null || echo "LOADING")
    echo "  [${i}/20] Brain=${B_STATUS}  Nano=${N_STATUS}"
    if [ "${B_STATUS}" = "OK" ] && [ "${N_STATUS}" = "OK" ]; then
        echo ""
        echo "Both models loaded and serving."
        break
    fi
done

echo ""
echo "Phase 3 complete. Proceed to: scripts/04_voice_pipeline.sh"
