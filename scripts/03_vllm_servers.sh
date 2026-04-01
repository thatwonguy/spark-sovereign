#!/usr/bin/env bash
# =============================================================================
# PHASE 3 — vLLM Inference Server
# =============================================================================
# Starts Brain (port 8000). All settings driven from config/models.yml.
# To swap the model: edit models.yml → re-run this script.
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

echo "========================================================"
echo " spark-sovereign — Phase 3: vLLM Inference Server"
echo "========================================================"

# Stop all GPU model containers first to free memory before starting.
echo ">>> Stopping existing GPU model containers..."
for name in brain qwen-brain nemotron-nano asr-server tts-server; do
    if docker ps -q --filter "name=^${name}$" | grep -q .; then
        docker stop "${name}" 2>/dev/null && echo "    stopped ${name}" || true
    fi
    docker rm -f "${name}" 2>/dev/null || true
done

# Remove all stopped containers and unused images to free disk space.
echo ">>> Pruning stopped containers..."
docker container prune -f

echo ">>> Pruning unused Docker images (frees old brain image from disk)..."
docker image prune -a -f

# Drop page cache to fully release unified memory held by the old model.
# Critical on DGX Spark — GPU and system share the same 128GB pool.
echo ">>> Dropping page cache to free unified memory..."
sudo sysctl -w vm.drop_caches=3
echo "    Cache cleared."
echo ""

# ── Brain ─────────────────────────────────────────────────────────────────────
BRAIN_IMAGE=$(get_field brain docker_image)
BRAIN_HF_REPO=$(get_field brain hf_repo)
BRAIN_NAME=$(get_field brain served_name)
BRAIN_PORT=$(get_field brain port)
BRAIN_UTIL=$(get_field brain gpu_memory_utilization)
BRAIN_CTX=$(get_field brain max_model_len)
BRAIN_QUANT=$(get_field brain quantization)
BRAIN_LOAD_FMT=$(get_field brain load_format)
BRAIN_SEQS=$(get_field brain max_num_seqs)
BRAIN_TOOL=$(get_field brain tool_call_parser)
BRAIN_REASON=$(get_field brain reasoning_parser)
BRAIN_EXTRA_ENV=$(get_extra_env_flags brain)

echo ""
echo ">>> Starting Brain: ${BRAIN_NAME} on port ${BRAIN_PORT}"

# shellcheck disable=SC2086
docker run -d \
    --name brain \
    --restart unless-stopped \
    --gpus all \
    --ipc host \
    --shm-size 64gb \
    -p "${BRAIN_PORT}:${BRAIN_PORT}" \
    -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
    -v "${MODELS_DIR}:/models" \
    ${BRAIN_EXTRA_ENV} \
    "${BRAIN_IMAGE}" \
        "${BRAIN_HF_REPO}" \
        --served-model-name "${BRAIN_NAME}" \
        --host 0.0.0.0 \
        --port "${BRAIN_PORT}" \
        --max-model-len "${BRAIN_CTX}" \
        --gpu-memory-utilization "${BRAIN_UTIL}" \
        --quantization "${BRAIN_QUANT}" \
        --allow-deprecated-quantization \
        --reasoning-parser "${BRAIN_REASON}" \
        --enable-auto-tool-choice \
        --tool-call-parser "${BRAIN_TOOL}" \
        --enable-prefix-caching \
        --max-num-seqs "${BRAIN_SEQS}" \
        --load-format "${BRAIN_LOAD_FMT}"

echo "    Container 'brain' started → http://localhost:${BRAIN_PORT}/v1"
echo "    Watch: docker logs brain -f"
echo ""
echo "Waiting for Brain to be ready..."
until curl -sf "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; do
    if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
        echo "ERROR: brain container exited. Check: docker logs brain"
        exit 1
    fi
    sleep 5
done

echo ""
echo "========================================================"
echo " Brain loaded and serving."
echo "  Model : ${BRAIN_NAME}"
echo "  URL   : http://localhost:${BRAIN_PORT}/v1"
echo "  Memory: util=${BRAIN_UTIL} → ~$(python3 -c "print(round(121.69 * ${BRAIN_UTIL}))")GB reserved by vLLM"
echo "========================================================"
echo ""
echo " NEXT STEP: Open OpenClaw → run the onboard setup wizard"
echo ""
echo " When the wizard asks — enter these values:"
echo ""
echo "  Provider type   : OpenAI-compatible endpoint"
echo "  Base URL        : http://localhost:${BRAIN_PORT}/v1"
echo "  Model ID        : ${BRAIN_NAME}"
echo "  API key         : unused  (any string works)"
echo "  Context window  : ${BRAIN_CTX}"
echo ""
echo " Everything else (agent name, personality, voice, memory,"
echo " Telegram, workspace) is configured inside OpenClaw's wizard."
echo "========================================================"
