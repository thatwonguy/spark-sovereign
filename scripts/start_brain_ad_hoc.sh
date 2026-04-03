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
BRAIN_EAGER=$(get_field brain enforce_eager)
BRAIN_REASON_PLUGIN=$(get_field brain reasoning_parser_plugin)
BRAIN_ASYNC=$(get_field brain async_scheduling)
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
    [ -n "${BRAIN_REASON_PLUGIN}" ] && EXTRA_ARGS+=" --reasoning-parser-plugin ${BRAIN_MODEL_PATH}/${BRAIN_REASON_PLUGIN}"
    [ -n "${BRAIN_BATCHED}" ]      && EXTRA_ARGS+=" --max-num-batched-tokens ${BRAIN_BATCHED}"
    [ -n "${BRAIN_QUANT}" ]        && EXTRA_ARGS+=" --quantization ${BRAIN_QUANT}"
    [ -n "${BRAIN_SPEC_MODEL}" ]   && EXTRA_ARGS+=" --speculative-model ${BRAIN_SPEC_MODEL}"
    [ -n "${BRAIN_SPEC_TOKENS}" ]  && EXTRA_ARGS+=" --num-speculative-tokens ${BRAIN_SPEC_TOKENS}"
    [ "${BRAIN_EAGER}" = "true" ]  && EXTRA_ARGS+=" --enforce-eager"
    [ "${BRAIN_ASYNC}" = "true" ]  && EXTRA_ARGS+=" --async-scheduling"

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
            ${BRAIN_REASON_PLUGIN:+--reasoning-parser-plugin "${BRAIN_MODEL_PATH}/${BRAIN_REASON_PLUGIN}"} \
            --max-num-seqs "${BRAIN_SEQS}" \
            $([ "${BRAIN_ASYNC}" = "true" ] && echo "--async-scheduling")
fi

echo "    brain started → http://localhost:${BRAIN_PORT}/v1"
echo "    Watch: docker logs brain -f"
echo "    Brain takes 3-5 minutes to load. OpenClaw reconnects automatically."
