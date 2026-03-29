#!/usr/bin/env bash
# =============================================================================
# Ad-hoc Brain restart — restarts qwen-brain only, leaves all other
# containers (nemotron-nano, pgvector, searxng, etc.) untouched.
#
# Use this when Brain needs fixing without waiting for Nano to reload.
# For a full stack restart use scripts/03_vllm_servers.sh instead.
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
BRAIN_EXTRA_ENV=$(get_extra_env_flags brain)

echo ">>> Restarting Brain only: ${BRAIN_NAME} on port ${BRAIN_PORT}"

docker rm -f qwen-brain 2>/dev/null || true

# shellcheck disable=SC2086
docker run -d --name qwen-brain \
    --gpus all --ipc host --network host \
    --restart unless-stopped \
    --entrypoint "" \
    ${BRAIN_EXTRA_ENV} \
    -v "${MODELS_DIR}:/models" \
    "${BRAIN_IMAGE}" \
    /opt/venv/bin/vllm serve "/models/$(basename "${BRAIN_PATH}")" \
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
        --max-num-batched-tokens "${BRAIN_BATCHED}" \
        --max-num-seqs "${BRAIN_SEQS}"

echo "    qwen-brain started → http://localhost:${BRAIN_PORT}/v1"
echo "    Watch: docker logs qwen-brain -f"
