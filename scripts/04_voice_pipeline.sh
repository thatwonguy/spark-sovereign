#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (STT)
# =============================================================================
# Installs the Whisper CLI and pre-caches the model so OpenClaw can
# transcribe voice notes from Telegram, TUI, and all channels.
#
# OpenClaw auto-detects the whisper binary — no manual config needed.
# Voice is fully configured through the OpenClaw onboard wizard.
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

# 3. Confirm whisper is on PATH and model is ready
WHISPER_BIN="$(command -v whisper)"
echo ""
echo "  Whisper CLI : ${WHISPER_BIN}"
echo "  Model cache : ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
echo ""

echo "========================================================"
echo " Phase 4 complete."
echo ""
echo " OpenClaw auto-detects the whisper binary — no config file"
echo " edits needed. Voice is activated through the onboard wizard:"
echo ""
echo "   openclaw configure"
echo ""
echo "   When prompted for your inference endpoint, enter:"
echo "     Provider  : OpenAI-compatible"
echo "     Base URL  : http://localhost:8000/v1"
echo "     Model ID  : $(python3 -c "import yaml; print(yaml.safe_load(open('${REPO_ROOT}/config/models.yml'))['brain']['served_name'])" 2>/dev/null || echo "(see config/models.yml → brain.served_name)")"
echo "     API key   : any string  (e.g. 'local')"
echo ""
echo " Once onboarded, test STT by sending a Telegram voice note."
echo " OpenClaw will transcribe it locally and echo the transcript"
echo " before passing the text to Brain."
echo ""
echo " Manual CLI test:"
echo "   whisper --model ${WHISPER_MODEL} --device cuda <audio_file.mp3>"
echo ""
echo " View OpenClaw logs:"
echo "   openclaw logs --follow"
echo "========================================================"
