#!/usr/bin/env bash
# =============================================================================
# Ad-hoc Brain restart — stops any existing Brain container, then starts
# a fresh one with all settings read from config/models.yml.
#
# Called by: boot_sequence.sh on every boot
# Manual use: run this any time to restart Brain (after a model swap, OOM, etc.)
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
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
BRAIN_BATCHED=$(get_field brain max_num_batched_tokens)
BRAIN_QUANT=$(get_field brain quantization)
BRAIN_SPEC_MODEL=$(get_field brain speculative_model)
BRAIN_SPEC_TOKENS=$(get_field brain num_speculative_tokens)
BRAIN_ENTRYPOINT=$(get_field brain entrypoint_mode)
BRAIN_EXTRA_ENV=$(get_extra_env_flags brain)

# Stop any existing Brain container before starting fresh.
echo ">>> Stopping existing Brain container..."
for name in brain qwen-brain; do
    if docker ps -q --filter "name=^${name}$" | grep -q .; then
        docker stop "${name}" 2>/dev/null && echo "    stopped ${name}" || true
    fi
    docker rm -f "${name}" 2>/dev/null || true
done

echo ">>> Starting Brain: ${BRAIN_NAME} on port ${BRAIN_PORT}"

# Build the model argument based on entrypoint style.
# Avarok images use: serve <model> [flags]
# Official vLLM images use: --model <path> [flags]
BRAIN_MODEL_PATH="/models/$(basename "${BRAIN_PATH}")"
if [ "${BRAIN_ENTRYPOINT}" = "serve" ]; then
    MODEL_ARGS="serve ${BRAIN_MODEL_PATH}"
else
    MODEL_ARGS="--model ${BRAIN_MODEL_PATH}"
fi

# shellcheck disable=SC2086
docker run -d --name brain \
    --gpus all --ipc host --network host \
    --restart no \
    ${BRAIN_EXTRA_ENV} \
    -v "${MODELS_DIR}:/models" \
    "${BRAIN_IMAGE}" \
        ${MODEL_ARGS} \
        --served-model-name "${BRAIN_NAME}" \
        --host 0.0.0.0 --port "${BRAIN_PORT}" \
        --gpu-memory-utilization "${BRAIN_UTIL}" \
        --max-model-len "${BRAIN_CTX}" \
        --kv-cache-dtype "${BRAIN_KV}" \
        ${BRAIN_BATCHED:+--max-num-batched-tokens "${BRAIN_BATCHED}"} \
        ${BRAIN_QUANT:+--quantization "${BRAIN_QUANT}"} \
        ${BRAIN_SPEC_MODEL:+--speculative-model "${BRAIN_SPEC_MODEL}"} \
        ${BRAIN_SPEC_TOKENS:+--num-speculative-tokens "${BRAIN_SPEC_TOKENS}"} \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser "${BRAIN_TOOL}" \
        --reasoning-parser "${BRAIN_REASON}" \
        --enable-prefix-caching \
        --max-num-seqs "${BRAIN_SEQS}"

echo "    brain started → http://localhost:${BRAIN_PORT}/v1"
echo "    Watch: docker logs brain -f"
echo "    Brain takes 3-5 minutes to load. OpenClaw reconnects automatically."
