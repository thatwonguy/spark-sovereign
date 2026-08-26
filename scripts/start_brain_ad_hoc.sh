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
# YAML true -> Python True prints as 'True'; callers test for 'true'.
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

# Emit a field as compact JSON. Accepts either a YAML mapping or a JSON string.
get_json_field() {
    python3 -c "
import yaml, json
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', None)
if val is None or val == '':
    print('')
elif isinstance(val, str):
    print(''.join(val.split()))
else:
    print(json.dumps(val, separators=(',', ':')))
"
}

BRAIN_IMAGE=$(get_field brain docker_image)
BRAIN_PATH=$(get_field brain local_path)
BRAIN_NAME=$(get_field brain served_name)
BRAIN_PORT=$(get_field brain port)
# Fall back to loopback when models.yml predates bind_host, so an older config
# tightens rather than silently staying open to the whole LAN. Must match
# 03_vllm_servers.sh — a boot start and a watchdog recovery have to produce
# the same server.
BRAIN_HOST=$(get_field brain bind_host)
BRAIN_HOST="${BRAIN_HOST:-127.0.0.1}"
BRAIN_UTIL=$(get_field brain gpu_memory_utilization)
BRAIN_CTX=$(get_field brain max_model_len)
BRAIN_KV=$(get_field brain kv_cache_dtype)
BRAIN_SEQS=$(get_field brain max_num_seqs)
BRAIN_TOOL=$(get_field brain tool_call_parser)
BRAIN_REASON=$(get_field brain reasoning_parser)
BRAIN_BATCHED=$(get_field brain max_num_batched_tokens)
BRAIN_MM=$(get_field brain limit_mm_per_prompt)
BRAIN_QUANT=$(get_field brain quantization)
BRAIN_MOE_BACKEND=$(get_field brain moe_backend)
BRAIN_SPEC_CONFIG=$(get_json_field brain speculative_config)
BRAIN_PREFIX_CACHE=$(get_field brain enable_prefix_caching)
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

# shellcheck disable=SC2086
docker run -d --name brain \
    --gpus all --ipc host --network host \
    --restart no \
    ${BRAIN_EXTRA_ENV} \
    -v "${MODELS_DIR}:/models" \
    "${BRAIN_IMAGE}" \
        --model "/models/$(basename "${BRAIN_PATH}")" \
        --served-model-name "${BRAIN_NAME}" \
        --host "${BRAIN_HOST}" --port "${BRAIN_PORT}" \
        --gpu-memory-utilization "${BRAIN_UTIL}" \
        --max-model-len "${BRAIN_CTX}" \
        --kv-cache-dtype "${BRAIN_KV}" \
        ${BRAIN_BATCHED:+--max-num-batched-tokens "${BRAIN_BATCHED}"} \
        ${BRAIN_QUANT:+--quantization "${BRAIN_QUANT}"} \
        ${BRAIN_MOE_BACKEND:+--moe-backend "${BRAIN_MOE_BACKEND}"} \
        ${BRAIN_SPEC_CONFIG:+--speculative-config "${BRAIN_SPEC_CONFIG}"} \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser "${BRAIN_TOOL}" \
        ${BRAIN_REASON:+--reasoning-parser "${BRAIN_REASON}"} \
        $([ "${BRAIN_PREFIX_CACHE}" = "true" ] && echo "--enable-prefix-caching") \
        --max-num-seqs "${BRAIN_SEQS}" \
        ${BRAIN_MM:+--limit-mm-per-prompt "${BRAIN_MM}"}

echo "    brain started → http://localhost:${BRAIN_PORT}/v1"
echo "    Watch: docker logs brain -f"

# NOTE: deliberately fire-and-return — do NOT add a readiness wait here.
# Both callers already bound the wait themselves, and each needs a fast return:
#   - boot_sequence.sh treats a failed start as non-fatal, then does its own
#     bounded 12-min wait on port 8000.
#   - watchdog.sh runs every 2 min and calls this for recovery; blocking here
#     would stretch its MAX_FAILS quarantine window far past the intended ~6 min.
echo "    Brain takes 3-5 minutes to load. Watchdog owns steady-state health."
echo "    Serving model ID: ${BRAIN_NAME}"
echo ""
echo "    OpenClaw reconnects automatically ONLY if its configured model ID still"
echo "    matches '${BRAIN_NAME}'. If you changed served_name in config/models.yml,"
echo "    re-run the OpenClaw config on this machine now — it is a manual step, and"
echo "    until it is done OpenClaw is pointed at a model ID that no longer exists."
