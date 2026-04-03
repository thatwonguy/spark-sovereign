#!/usr/bin/env bash
# =============================================================================
# PHASE 3 — vLLM Inference Server
# =============================================================================
# Starts Brain. All settings driven from config/models.yml.
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

# ── Brain ─────────────────────────────────────────────────────────────────────
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
BRAIN_MM=$(get_field brain limit_mm_per_prompt)
BRAIN_QUANT=$(get_field brain quantization)
BRAIN_SPEC_MODEL=$(get_field brain speculative_model)
BRAIN_SPEC_TOKENS=$(get_field brain num_speculative_tokens)
BRAIN_EAGER=$(get_field brain enforce_eager)
BRAIN_ENTRYPOINT=$(get_field brain entrypoint_mode)
BRAIN_EXTRA_ENV=$(get_extra_env_flags brain)

echo ""
echo ">>> Starting Brain: ${BRAIN_NAME} on port ${BRAIN_PORT}"

BRAIN_MODEL_PATH="/models/$(basename "${BRAIN_PATH}")"

if [ "${BRAIN_ENTRYPOINT}" = "serve" ]; then
    # ── Avarok image ──────────────────────────────────────────────────────────
    # Avarok entrypoint reads: MODEL, PORT, HOST, MAX_MODEL_LEN, GPU_MEMORY_UTIL,
    # MAX_NUM_SEQS as env vars. All other vLLM flags go into VLLM_EXTRA_ARGS.
    EXTRA_ARGS=""
    EXTRA_ARGS+=" --kv-cache-dtype ${BRAIN_KV}"
    EXTRA_ARGS+=" --trust-remote-code"
    EXTRA_ARGS+=" --enable-auto-tool-choice"
    EXTRA_ARGS+=" --tool-call-parser ${BRAIN_TOOL}"
    EXTRA_ARGS+=" --reasoning-parser ${BRAIN_REASON}"
    [ -n "${BRAIN_BATCHED}" ]      && EXTRA_ARGS+=" --max-num-batched-tokens ${BRAIN_BATCHED}"
    [ -n "${BRAIN_QUANT}" ]        && EXTRA_ARGS+=" --quantization ${BRAIN_QUANT}"
    [ -n "${BRAIN_SPEC_MODEL}" ]   && EXTRA_ARGS+=" --speculative-model ${BRAIN_SPEC_MODEL}"
    [ -n "${BRAIN_SPEC_TOKENS}" ]  && EXTRA_ARGS+=" --num-speculative-tokens ${BRAIN_SPEC_TOKENS}"
    [ "${BRAIN_EAGER}" = "true" ]  && EXTRA_ARGS+=" --enforce-eager"
    [ -n "${BRAIN_MM}" ]           && EXTRA_ARGS+=" --limit-mm-per-prompt ${BRAIN_MM}"

    # shellcheck disable=SC2086
    docker run -d --name brain \
        --gpus all --ipc host --network host \
        --restart no \
        -e MODEL="${BRAIN_MODEL_PATH}" \
        -e PORT="${BRAIN_PORT}" \
        -e MAX_MODEL_LEN="${BRAIN_CTX}" \
        -e GPU_MEMORY_UTIL="${BRAIN_UTIL}" \
        -e MAX_NUM_SEQS="${BRAIN_SEQS}" \
        -e VLLM_EXTRA_ARGS="${EXTRA_ARGS}" \
        ${BRAIN_EXTRA_ENV} \
        -v "${MODELS_DIR}:/models" \
        "${BRAIN_IMAGE}"
else
    # ── Standard vLLM image ───────────────────────────────────────────────────
    # shellcheck disable=SC2086
    docker run -d --name brain \
        --gpus all --ipc host --network host \
        --restart no \
        ${BRAIN_EXTRA_ENV} \
        -v "${MODELS_DIR}:/models" \
        "${BRAIN_IMAGE}" \
            --model "${BRAIN_MODEL_PATH}" \
            --served-model-name "${BRAIN_NAME}" \
            --host 0.0.0.0 --port "${BRAIN_PORT}" \
            --gpu-memory-utilization "${BRAIN_UTIL}" \
            --max-model-len "${BRAIN_CTX}" \
            --kv-cache-dtype "${BRAIN_KV}" \
            ${BRAIN_BATCHED:+--max-num-batched-tokens "${BRAIN_BATCHED}"} \
            ${BRAIN_QUANT:+--quantization "${BRAIN_QUANT}"} \
            ${BRAIN_SPEC_MODEL:+--speculative-model "${BRAIN_SPEC_MODEL}"} \
            ${BRAIN_SPEC_TOKENS:+--num-speculative-tokens "${BRAIN_SPEC_TOKENS}"} \
            $([ "${BRAIN_EAGER}" = "true" ] && echo "--enforce-eager") \
            --trust-remote-code \
            --enable-auto-tool-choice \
            --tool-call-parser "${BRAIN_TOOL}" \
            --reasoning-parser "${BRAIN_REASON}" \
            --max-num-seqs "${BRAIN_SEQS}" \
            ${BRAIN_MM:+--limit-mm-per-prompt "${BRAIN_MM}"}
fi

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
echo "  Memory: util=${BRAIN_UTIL} → ~$(python3 -c "print(round(121.69 * ${BRAIN_UTIL}))")GB reserved by vLLM (~40GB weights + KV cache)"
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
