#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (STT) + OpenClaw Health
# =============================================================================
# 1. Installs Whisper CLI and pre-caches the model (OpenClaw auto-detects it)
# 2. Runs openclaw doctor --repair to fix Node/systemd service warnings
# 3. Reports any outstanding config issues (memory search, Telegram policy)
#
# Idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

WHISPER_MODEL="${WHISPER_MODEL:-small}"
WHISPER_CACHE="${HOME}/.cache/whisper"

echo "========================================================"
echo " spark-sovereign — Phase 4: Voice Pipeline (STT)"
echo "========================================================"
echo ""

# 1. Install openai-whisper CLI
echo ">>> Installing Whisper CLI..."
if command -v whisper &>/dev/null; then
    echo "    Already installed."
else
    pip install openai-whisper --break-system-packages --quiet
    echo "    Installed: $(command -v whisper)"
fi

# 2. Pre-cache the Whisper model
# openai-whisper stores models as .pt files in ~/.cache/whisper/ on first use.
# We trigger the download here so OpenClaw never waits on a cold fetch.
echo ">>> Pre-caching Whisper model (${WHISPER_MODEL})..."
mkdir -p "${WHISPER_CACHE}"
if [ -f "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" ]; then
    echo "    Already cached: ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
else
    echo "    Downloading to ${WHISPER_CACHE}/ (one-time, ~450MB for small)..."
    python3 -c "
import whisper
whisper.load_model('${WHISPER_MODEL}')
"
    echo "    Cached: ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
fi

WHISPER_BIN="$(command -v whisper)"
echo "    CLI : ${WHISPER_BIN}"
echo "    Model cache : ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
echo ""

# 3. Run openclaw doctor --repair
# Fixes the Node/nvm systemd service path warnings discovered during setup.
# Also restarts the gateway with the corrected service file.
echo ">>> Running openclaw doctor --repair..."
if command -v openclaw &>/dev/null; then
    openclaw doctor --repair 2>&1 | grep -E "(✓|✗|warning|error|Warning|Error|Gateway|Telegram|Memory|Skills|Repair|repair|fixed|Fixed|restart|Restart|ok|❌|⚠)" \
        | sed 's/^/    /' || true
    echo ""
else
    echo "    openclaw not found on PATH — skipping."
    echo "    Ensure OpenClaw is installed: npm install -g openclaw"
    echo ""
fi

# 4. Post-repair checks — surface any outstanding issues
echo ">>> Checking OpenClaw config..."
if command -v openclaw &>/dev/null; then

    # Telegram group policy — groupAllowFrom empty means group msgs silently dropped
    GROUP_POLICY=$(openclaw config get channels.telegram.groupPolicy 2>/dev/null || echo "")
    GROUP_ALLOW=$(openclaw config get channels.telegram.groupAllowFrom 2>/dev/null || echo "")
    if [ "${GROUP_POLICY}" = "allowlist" ] && [ -z "${GROUP_ALLOW}" ]; then
        echo ""
        echo "  ⚠️  Telegram group policy: 'allowlist' but groupAllowFrom is empty."
        echo "     All group messages are silently dropped."
        echo "     Fix (pick one):"
        echo "       openclaw config set channels.telegram.groupPolicy open"
        echo "       # OR add your group ID:"
        echo "       openclaw config set channels.telegram.groupAllowFrom '[-1001234567890]'"
    else
        echo "  ✅ Telegram group policy: ok"
    fi

    # Memory search — needs an embedding provider to function
    MEM_ENABLED=$(openclaw config get agents.defaults.memorySearch.enabled 2>/dev/null || echo "")
    MEM_PROVIDER=$(openclaw config get agents.defaults.memorySearch.provider 2>/dev/null || echo "")
    if [ "${MEM_ENABLED}" = "true" ] && [ -z "${MEM_PROVIDER}" ]; then
        echo ""
        echo "  ⚠️  Memory search is enabled but no embedding provider is configured."
        echo "     Semantic recall will not work until fixed."
        echo "     Fix — local embeddings (no cloud key needed):"
        echo "       openclaw configure --section model"
        echo "       # Or disable memory search:"
        echo "       openclaw config set agents.defaults.memorySearch.enabled false"
        echo "     Verify: openclaw memory status --deep"
    else
        echo "  ✅ Memory search: ok (provider: ${MEM_PROVIDER:-disabled})"
    fi

else
    echo "  openclaw not on PATH — skipping config checks."
fi
echo ""

# 5. Verify gateway is running
echo ">>> Verifying gateway..."
if command -v openclaw &>/dev/null; then
    GATEWAY_STATE=$(openclaw gateway status 2>/dev/null | grep "Runtime:" | head -1 || echo "")
    if echo "${GATEWAY_STATE}" | grep -q "running"; then
        echo "  ✅ Gateway running"
        openclaw status 2>/dev/null | grep -E "^(Telegram|Agents|Session)" | sed 's/^/    /' || true
    else
        echo "  ❌ Gateway not running — starting..."
        openclaw gateway start 2>/dev/null && echo "  ✅ Gateway started." || echo "  Failed — check: openclaw logs"
    fi
else
    OC_PORT=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('infrastructure', {}).get('nemoclaw', {}).get('ui_port', 18789))
" 2>/dev/null || echo "18789")
    OC_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:${OC_PORT}/" 2>/dev/null || echo "000")
    [ "${OC_CODE}" = "200" ] \
        && echo "  ✅ OpenClaw responding on port ${OC_PORT}" \
        || echo "  ❌ OpenClaw not responding on port ${OC_PORT}"
fi
echo ""

echo "========================================================"
echo " Phase 4 complete."
echo ""
echo " OpenClaw auto-detects the whisper binary — no manual"
echo " config needed. STT is active for all channels."
echo ""
echo " Test STT:"
echo "   whisper --model ${WHISPER_MODEL} --device cuda <audio_file.mp3>"
echo ""
echo " Test via Telegram:"
echo "   Send a voice note to your Telegram bot"
echo "   OpenClaw transcribes locally → Brain receives text → replies"
echo ""
echo " View live logs:"
echo "   openclaw logs --follow"
echo ""
echo " If issues remain:"
echo "   openclaw doctor --repair"
echo "   openclaw status"
echo "========================================================"
