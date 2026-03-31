#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (STT)
# =============================================================================
# Sets up local Whisper STT so OpenClaw can transcribe voice notes from
# Telegram, TUI, and all other channels.
#
# OpenClaw handles audio transcription at its own layer — no separate
# Docker containers needed. This script installs the Whisper CLI,
# pre-caches the model, and wires the config into OpenClaw.
#
# Idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

WHISPER_MODEL="${WHISPER_MODEL:-small}"
OPENCLAW_CONFIG="${HOME}/.openclaw/openclaw.json"
WHISPER_CACHE="${HOME}/.cache/whisper"

echo "========================================================"
echo " spark-sovereign — Phase 4: Voice Pipeline (STT)"
echo "========================================================"
echo "  Model:  whisper-${WHISPER_MODEL} (local, GPU-accelerated)"
echo "  Config: ${OPENCLAW_CONFIG}"
echo ""

# 1. Install openai-whisper CLI
echo ">>> Installing Whisper CLI..."
if command -v whisper &>/dev/null; then
    echo "    Already installed."
else
    pip install openai-whisper --break-system-packages --quiet
    echo "    Installed."
fi

# 2. Pre-cache the Whisper model
# openai-whisper downloads its own .pt files to ~/.cache/whisper/ on first use.
# We trigger that here so OpenClaw never waits on a cold download.
echo ">>> Pre-caching Whisper model (${WHISPER_MODEL})..."
mkdir -p "${WHISPER_CACHE}"
if [ -f "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" ]; then
    echo "    Already cached: ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
else
    echo "    Downloading to ${WHISPER_CACHE}/ (one-time, ~450MB for small)..."
    python3 -c "
import whisper
whisper.load_model('${WHISPER_MODEL}')
print('    Model cached.')
"
fi

# Resolve full path to whisper binary (used in config)
WHISPER_BIN="$(command -v whisper)"

# 3. Apply OpenClaw audio config
# ─────────────────────────────────────────────────────────────────────────────
# Two paths:
#   A) openclaw CLI is available → merge config non-interactively, then restart
#   B) openclaw CLI not found    → write/merge config directly to JSON, print
#                                  instructions for wizard or manual restart
# ─────────────────────────────────────────────────────────────────────────────

echo ">>> Configuring OpenClaw audio..."

# Build the audio block we want to inject
AUDIO_BLOCK=$(cat <<EOF
{
  "enabled": true,
  "maxBytes": 20971520,
  "echoTranscript": true,
  "models": [
    {
      "type": "cli",
      "command": "${WHISPER_BIN}",
      "args": ["--model", "${WHISPER_MODEL}", "--device", "cuda", "{{MediaPath}}"],
      "timeoutSeconds": 45
    }
  ]
}
EOF
)

# Python helper: merge audio block into existing openclaw.json (or create it)
apply_config() {
    python3 - <<PYEOF
import json, os, sys

config_path = os.path.expanduser("${OPENCLAW_CONFIG}")
os.makedirs(os.path.dirname(config_path), exist_ok=True)

# Load existing config or start fresh
if os.path.exists(config_path):
    with open(config_path) as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError:
            print("    WARNING: existing openclaw.json is not valid JSON — backing up and recreating.")
            os.rename(config_path, config_path + ".bak")
            cfg = {}
else:
    cfg = {}

# Merge audio block into tools.media.audio
audio_block = json.loads('''${AUDIO_BLOCK}''')
cfg.setdefault("tools", {}).setdefault("media", {})["audio"] = audio_block

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"    Written to {config_path}")
PYEOF
}

if command -v openclaw &>/dev/null; then
    # Path A: apply via config merge, then restart gateway
    apply_config
    echo "    Restarting OpenClaw gateway to apply changes..."
    openclaw gateway restart 2>/dev/null \
        && echo "    Gateway restarted." \
        || echo "    Gateway not running — config will apply on next start."
else
    # Path B: write config directly, show manual instructions
    apply_config

    echo ""
    echo "========================================================"
    echo " OpenClaw CLI not found on this PATH."
    echo " Config has been written. Complete setup one of two ways:"
    echo "========================================================"
    echo ""
    echo " OPTION A — Run the OpenClaw setup wizard (recommended):"
    echo ""
    echo "   openclaw configure"
    echo ""
    echo "   The wizard will ask for your vLLM endpoint. Enter:"
    echo "     Provider:       OpenAI-compatible"
    echo "     Base URL:       http://localhost:8000/v1"
    echo "     Model ID:       (from config/models.yml → brain.served_name)"
    echo "     API key:        any string (e.g. 'local')"
    echo "   Voice/STT config is already written — wizard will pick it up."
    echo ""
    echo " OPTION B — Manual config edit (if already onboarded):"
    echo ""
    echo "   File: ${OPENCLAW_CONFIG}"
    echo ""
    echo "   Add/merge this block under tools.media.audio:"
    echo ""
    cat <<JSONEOF
  "tools": {
    "media": {
      "audio": {
        "enabled": true,
        "maxBytes": 20971520,
        "echoTranscript": true,
        "models": [
          {
            "type": "cli",
            "command": "${WHISPER_BIN}",
            "args": ["--model", "${WHISPER_MODEL}", "--device", "cuda", "{{MediaPath}}"],
            "timeoutSeconds": 45
          }
        ]
      }
    }
  }
JSONEOF
    echo ""
    echo "   Then restart the gateway:"
    echo "     openclaw gateway restart"
    echo ""
fi

# 4. Verify
echo ">>> Verifying..."
echo ""
echo "  Whisper CLI : ${WHISPER_BIN}"
echo "  Model cache : ${WHISPER_CACHE}/${WHISPER_MODEL}.pt"
echo "  Config file : ${OPENCLAW_CONFIG}"
echo ""

if command -v openclaw &>/dev/null; then
    echo "  OpenClaw status:"
    openclaw status 2>/dev/null | sed 's/^/    /' || echo "    (gateway not running)"
    echo ""
    echo "  Validate config:"
    openclaw config validate 2>/dev/null | sed 's/^/    /' || true
    echo ""
fi

echo "========================================================"
echo " Phase 4 complete."
echo ""
echo " Test STT:"
echo "   whisper --model ${WHISPER_MODEL} --device cuda <audio_file.mp3>"
echo ""
echo " Test via OpenClaw:"
echo "   1. Send a voice note in Telegram (or TUI)"
echo "   2. OpenClaw transcribes locally — model receives the text"
echo "   3. Echo shows the transcript before the model reply"
echo ""
echo " View logs:"
echo "   openclaw logs --follow"
echo "========================================================"
