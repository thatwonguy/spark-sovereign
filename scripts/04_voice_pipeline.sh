#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (STT)
# =============================================================================
# Installs the Whisper CLI and pre-caches the model.
# OpenClaw configuration is handled by the AI agent — see instructions below.
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
    echo "    Already installed: $(command -v whisper)"
else
    pip install openai-whisper --break-system-packages --quiet
    echo "    Installed: $(command -v whisper)"
fi

# 2. Pre-cache the model
# openai-whisper downloads .pt files to ~/.cache/whisper/ on first use.
# Trigger it here so the agent's first transcription isn't slow.
echo ">>> Pre-caching Whisper model (${WHISPER_MODEL})..."
mkdir -p "${WHISPER_CACHE}"
if [ -f "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" ]; then
    echo "    Already cached: ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
else
    echo "    Downloading (~450MB for small, one-time)..."
    python3 -c "import whisper; whisper.load_model('${WHISPER_MODEL}')"
    echo "    Cached: ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
fi

WHISPER_BIN="$(command -v whisper)"
BRAIN_NAME=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('brain', {}).get('served_name', 'unknown'))
" 2>/dev/null || echo "unknown")
BRAIN_CTX=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('brain', {}).get('max_model_len', 262144))
" 2>/dev/null || echo "262144")

echo ""
echo "========================================================"
echo " Phase 4 complete."
echo ""
echo " Whisper is installed. Now ask your AI agent to finish"
echo " the setup...FYI if your AI brain you selected"
echo " cannot fix itself at this point, you messed up buddy! Pick a smarter model!"
echo " Open OpenClaw TUI and send this prompt:"
echo ""
echo "────────────────────────────────────────────────────────"
cat <<PROMPT
Configure my OpenClaw setup for voice and performance:

1. Enable STT in ~/.openclaw/openclaw.json:
   tools.media.audio.enabled = true
   tools.media.audio.echoTranscript = true
   tools.media.audio.models = [{
     "type": "cli",
     "command": "${WHISPER_BIN}",
     "args": ["--model", "${WHISPER_MODEL}", "--device", "cuda", "{{MediaPath}}"],
     "timeoutSeconds": 45
   }]

2. Fix context window (currently set to 128000, should be ${BRAIN_CTX}):
   agents.defaults.models.vllm/${BRAIN_NAME}.contextWindow = ${BRAIN_CTX}

3. Reduce response latency — we need speed for end user

4. Telegram group policy - ask user about this and what they want

After making changes, run: openclaw gateway restart
Then confirm with: openclaw doctor
PROMPT
echo "────────────────────────────────────────────────────────"
echo ""
echo " Or start the TUI now:"
echo "   openclaw tui"
echo "========================================================"
