#!/usr/bin/env bash
# =============================================================================
# Stack Health Check — spark-sovereign
# Checks Brain, GPU, OpenClaw gateway, Telegram, Whisper STT, and memory.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
keys = '$1'.split('.')
node = cfg
for k in keys:
    node = node.get(k, {})
print(node if isinstance(node, (str, int, float)) else '')
" 2>/dev/null || echo ""
}

BRAIN_PORT=$(get_field brain.port)
BRAIN_NAME=$(get_field brain.served_name)
BRAIN_HF=$(get_field brain.hf_repo)
BRAIN_CTX=$(get_field brain.max_model_len)
BRAIN_UTIL=$(get_field brain.gpu_memory_utilization)
BRAIN_KV=$(get_field brain.kv_cache_dtype)
OPENCLAW_PORT=$(get_field infrastructure.nemoclaw.ui_port)
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
WHISPER_MODEL="${WHISPER_MODEL:-small}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          spark-sovereign — Stack Health Check            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── System memory ─────────────────────────────────────────────────────────────
echo "── System Memory ───────────────────────────────────────────"
free -h | grep -E "Mem|Swap"
echo ""

# ── GPU ───────────────────────────────────────────────────────────────────────
echo "── GPU / VRAM ──────────────────────────────────────────────"
nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{
        gsub(/ /,"",$2); gsub(/ /,"",$3);
        printf "  %-28s  Util: %s%%   Temp: %s°C\n",$1,$2,$3
    }'
echo ""
echo "  Processes consuming VRAM:"
GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_gpu_memory,name \
    --format=csv,noheader,nounits 2>/dev/null || true)
if [ -z "${GPU_PROCS}" ]; then
    echo "    (none)"
else
    while IFS=',' read -r pid mib pname; do
        pid="${pid// /}"; mib="${mib// /}"; pname="${pname## }"
        gb=$(python3 -c "print(f'{int(\"${mib}\")/1024:.1f}')" 2>/dev/null || echo "?")
        proc=$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")
        printf "    PID %-8s  %-24s  %s GiB  (%s)\n" "${pid}" "${pname}" "${gb}" "${proc}"
    done <<< "${GPU_PROCS}"
fi
echo ""

# ── Docker containers ─────────────────────────────────────────────────────────
echo "── Docker Containers ───────────────────────────────────────"
ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}|{{.Status}}|{{.Image}}|{{.RunningFor}}" 2>/dev/null)
if [ -z "${ALL_CONTAINERS}" ]; then
    echo "  (none found)"
else
    printf "  %-22s %-14s %-38s %s\n" "NAME" "STATUS" "IMAGE" "RUNNING FOR"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "${ALL_CONTAINERS}" | while IFS='|' read -r name status image uptime; do
        icon="❌"; echo "${status}" | grep -q "^Up" && icon="✅"
        printf "  ${icon} %-20s %-14s %-38s %s\n" \
            "${name}" "${status:0:13}" "${image:0:37}" "${uptime}"
    done
fi
echo ""

# ── Brain ─────────────────────────────────────────────────────────────────────
echo "── Brain (vLLM) ────────────────────────────────────────────"
BRAIN_RESULT=$(curl -sf --max-time 5 "http://localhost:${BRAIN_PORT}/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
    2>/dev/null || echo "")
if [ -n "${BRAIN_RESULT}" ]; then
    printf "  ✅ Brain  (port %-5s)  model: %s\n" "${BRAIN_PORT}" "${BRAIN_RESULT}"
else
    printf "  ❌ Brain  (port %-5s)  not responding\n" "${BRAIN_PORT}"
    echo "     Fix: docker logs brain --tail 50"
fi
echo ""
echo "  HF model     : ${BRAIN_HF}"
echo "  Base URL     : http://localhost:${BRAIN_PORT}/v1"
echo "  Model ID     : ${BRAIN_NAME}"
echo "  API key      : any string  (e.g. 'local')"
echo "  Context      : ${BRAIN_CTX} tokens"
echo "  KV dtype     : ${BRAIN_KV}"
echo "  GPU util     : ${BRAIN_UTIL} (~$(python3 -c "print(round(121.69 * ${BRAIN_UTIL}))")GB reserved)"
echo ""

# ── OpenClaw gateway ──────────────────────────────────────────────────────────
echo "── OpenClaw Gateway ────────────────────────────────────────"
if command -v openclaw &>/dev/null; then
    GATEWAY_STATE=$(openclaw gateway status 2>/dev/null | grep "Runtime:" | head -1 || echo "")
    if echo "${GATEWAY_STATE}" | grep -q "running"; then
        printf "  ✅ Gateway running  (port %s)\n" "${OPENCLAW_PORT}"
    else
        printf "  ❌ Gateway not running\n"
        echo "     Fix: openclaw gateway start"
    fi

    # Telegram + session status — strip ANSI codes before parsing
    OC_STATUS=$(openclaw status 2>/dev/null | sed 's/\x1B\[[0-9;]*[mK]//g' || echo "")
    TG_LINE=$(echo "${OC_STATUS}" | grep "Telegram:" | head -1 || echo "")
    if echo "${TG_LINE}" | grep -q " ok "; then
        BOT=$(echo "${TG_LINE}" | grep -oP '\(@\S+\)' | tr -d '()')
        printf "  ✅ Telegram: connected  %s\n" "${BOT}"
    elif [ -n "${TG_LINE}" ]; then
        printf "  ⚠️  Telegram: %s\n" "${TG_LINE}"
    else
        printf "  ⚠️  Telegram: not connected — check TELEGRAM_BOT_TOKEN in .env\n"
    fi

    SESSIONS=$(echo "${OC_STATUS}" | grep "Session store" | grep -oP '\d+ entr' || echo "")
    [ -n "${SESSIONS}" ] && echo "  Sessions: ${SESSIONS}ies"

    # Telegram group policy warning
    GROUP_POLICY=$(openclaw config get channels.telegram.groupPolicy 2>/dev/null || echo "")
    GROUP_ALLOW=$(openclaw config get channels.telegram.groupAllowFrom 2>/dev/null || echo "")
    if [ "${GROUP_POLICY}" = "allowlist" ] && [ -z "${GROUP_ALLOW}" ]; then
        echo ""
        echo "  ⚠️  Telegram groupPolicy='allowlist' but groupAllowFrom is empty"
        echo "     Group messages are silently dropped."
        echo "     Fix: openclaw config set channels.telegram.groupPolicy open"
    fi
else
    # Fallback: plain HTTP probe
    OC_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
        "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")
    if [ "${OC_CODE}" = "200" ]; then
        printf "  ✅ OpenClaw responding on port %s\n" "${OPENCLAW_PORT}"
    else
        printf "  ❌ OpenClaw not responding (HTTP %s)\n" "${OC_CODE}"
        echo "     Fix: openclaw gateway start"
    fi
fi
echo ""

# ── Whisper STT ───────────────────────────────────────────────────────────────
echo "── Whisper STT ─────────────────────────────────────────────"
WHISPER_CACHE="${HOME}/.cache/whisper"
if command -v whisper &>/dev/null; then
    WHISPER_BIN="$(command -v whisper)"
    printf "  ✅ whisper CLI : %s\n" "${WHISPER_BIN}"
else
    printf "  ❌ whisper CLI : not found\n"
    echo "     Fix: bash scripts/04_voice_pipeline.sh"
fi
if [ -f "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" ]; then
    SIZE=$(du -sh "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" 2>/dev/null | cut -f1)
    printf "  ✅ model cache : %s/%s.pt  (%s)\n" "${WHISPER_CACHE}" "${WHISPER_MODEL}" "${SIZE}"
else
    printf "  ❌ model cache : %s/%s.pt not found\n" "${WHISPER_CACHE}" "${WHISPER_MODEL}"
    echo "     Fix: bash scripts/04_voice_pipeline.sh"
fi
echo "  Note: OpenClaw auto-detects whisper — no manual config needed."
echo ""

# ── Memory search ─────────────────────────────────────────────────────────────
echo "── Memory Search (embeddings) ──────────────────────────────"
if command -v openclaw &>/dev/null; then
    MEM_ENABLED=$(openclaw config get agents.defaults.memorySearch.enabled 2>/dev/null || echo "")
    MEM_PROVIDER=$(openclaw config get agents.defaults.memorySearch.provider 2>/dev/null || echo "")
    # "auto" or empty means OpenClaw tries cloud API keys — check if any are set in .env
    HAS_EMBED_KEY=false
    for var in OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY VOYAGE_API_KEY MISTRAL_API_KEY; do
        [ -n "${!var:-}" ] && HAS_EMBED_KEY=true && break
    done
    if [ "${MEM_ENABLED}" = "false" ]; then
        echo "  ℹ️  Memory search: disabled"
        echo "     Enable: openclaw config set agents.defaults.memorySearch.enabled true"
    elif [ "${MEM_ENABLED}" = "true" ] && [ -z "${MEM_PROVIDER}" ] && [ "${HAS_EMBED_KEY}" = "false" ]; then
        echo "  ⚠️  Memory search: enabled but no embedding provider ready"
        echo "     Auto mode requires an API key (OpenAI/Gemini/Voyage/Mistral) or local model."
        echo "     Fix (local, no cloud key): openclaw configure --section model"
        echo "     Fix (disable):             openclaw config set agents.defaults.memorySearch.enabled false"
        echo "     Verify:                    openclaw memory status --deep"
    elif [ -n "${MEM_PROVIDER}" ] && [ "${MEM_PROVIDER}" != "auto" ]; then
        printf "  ✅ Memory search: enabled (provider: %s)\n" "${MEM_PROVIDER}"
    else
        printf "  ✅ Memory search: enabled (provider: auto — API key found)\n"
    fi
else
    echo "  (openclaw not on PATH — skipping)"
fi
echo ""

# ── Skills ────────────────────────────────────────────────────────────────────
# openclaw doctor is interactive — don't run it here, just report from config
echo "── Skills ──────────────────────────────────────────────────"
if command -v openclaw &>/dev/null; then
    echo "  Run for full report: openclaw doctor"
    echo "  Run to auto-fix:     openclaw doctor --repair"
else
    echo "  (openclaw not on PATH — skipping)"
fi
echo ""

# ── Auto-start service ────────────────────────────────────────────────────────
echo "── Auto-Start Service ──────────────────────────────────────"
SVC_STATUS=$(systemctl is-active spark-sovereign 2>/dev/null) || SVC_STATUS="inactive"
SVC_ENABLED=$(systemctl is-enabled spark-sovereign 2>/dev/null) || SVC_ENABLED="unknown"
OC_SVC=$(systemctl --user is-active openclaw-gateway 2>/dev/null) || OC_SVC="inactive"
OC_ENABLED=$(systemctl --user is-enabled openclaw-gateway 2>/dev/null) || OC_ENABLED="unknown"

if [ "${SVC_ENABLED}" = "enabled" ]; then
    printf "  ✅ spark-sovereign.service: enabled (status: %s)\n" "${SVC_STATUS}"
    [ "${SVC_STATUS}" = "inactive" ] && echo "     Normal — oneshot, runs on boot."
else
    printf "  ❌ spark-sovereign.service: not enabled\n"
    echo "     Fix: bash scripts/01_system_prep.sh"
fi

if [ "${OC_ENABLED}" = "enabled" ]; then
    printf "  ✅ openclaw-gateway.service: enabled (status: %s)\n" "${OC_SVC}"
else
    printf "  ⚠️  openclaw-gateway.service: not enabled (%s)\n" "${OC_SVC}"
    echo "     Fix: openclaw doctor --repair"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
