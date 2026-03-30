#!/usr/bin/env bash
# =============================================================================
# PHASE 9 — Telegram Bot (routes through OpenClaw, no NVIDIA relay)
# =============================================================================
# Installs agent/telegram_bot.py as a systemd service.
# Reads TELEGRAM_BOT_TOKEN + TELEGRAM_ALLOWED_USER_IDS from .env.
# Messages go: Telegram → this bot → OpenClaw (port 18789) → Brain + all MCP tools
# Voice: Telegram OGG → ffmpeg → ASR (8002) → OpenClaw → TTS (8003) → Telegram
# OpenClaw provides: tools, memory, web search, GitHub, SOUL.md, IDENTITY.md.
# Zero cloud relay. Your token never touches NVIDIA or any third party.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

echo "========================================================"
echo " spark-sovereign — Phase 9: Telegram Bot"
echo "========================================================"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo ""
    echo "ERROR: TELEGRAM_BOT_TOKEN not set in .env"
    echo "  1. Message @BotFather on Telegram → /newbot → copy token"
    echo "  2. Add to .env: TELEGRAM_BOT_TOKEN=7xxx:AAFxxx"
    echo "  3. Re-run this script."
    exit 1
fi

echo "  Bot token: ${TELEGRAM_BOT_TOKEN:0:12}..."
echo "  Allowed users: ${TELEGRAM_ALLOWED_USER_IDS:-all}"

# ── Extract OPENCLAW_TOKEN ─────────────────────────────────────────────────────
# Try: 1) .env already has it  2) nemoclaw credentials file  3) ask user
if [[ -z "${OPENCLAW_TOKEN:-}" ]]; then
    # nemoclaw stores auth in ~/.nemoclaw/credentials.json
    CREDS_FILE="${HOME}/.nemoclaw/credentials.json"
    if [[ -f "${CREDS_FILE}" ]]; then
        OPENCLAW_TOKEN=$(python3 -c "
import json
d = json.load(open('${CREDS_FILE}'))
# Key may be 'token', 'api_key', or nested under 'deep'
for key in ('token','api_key','apiKey'):
    if key in d:
        print(d[key]); exit()
# Try first sandbox entry
for v in d.values():
    if isinstance(v, dict):
        for key in ('token','api_key','apiKey'):
            if key in v:
                print(v[key]); exit()
" 2>/dev/null || true)
    fi
fi

if [[ -z "${OPENCLAW_TOKEN:-}" ]]; then
    echo ""
    echo "  OPENCLAW_TOKEN not found in .env or ~/.nemoclaw/credentials.json"
    echo "  To find your token:"
    echo "    cat ~/.nemoclaw/credentials.json"
    echo "  or look at the onboarding URL — it contains #token=<value>"
    echo "  Then add to .env:  OPENCLAW_TOKEN=<value>"
    echo ""
    echo "  Continuing without token (OpenClaw may reject unauthenticated requests)."
fi

if [[ -n "${OPENCLAW_TOKEN:-}" ]]; then
    echo "  OpenClaw token: ${OPENCLAW_TOKEN:0:12}..."
fi

# ── Python deps ───────────────────────────────────────────────────────────────
echo ""
echo ">>> Installing Python dependencies..."
pip install aiohttp websockets --break-system-packages --quiet
echo "    aiohttp + websockets installed."

# ── systemd service ───────────────────────────────────────────────────────────
echo ""
echo ">>> Installing spark-telegram systemd service..."

# Write env file (keeps secrets out of the unit file)
sudo mkdir -p /etc/spark-sovereign
sudo tee /etc/spark-sovereign/telegram.env > /dev/null << EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_ALLOWED_USER_IDS=${TELEGRAM_ALLOWED_USER_IDS:-}
# OpenClaw — all AI logic (tools, memory, web search, GitHub, SOUL.md) lives here
OPENCLAW_URL=http://localhost:18789
OPENCLAW_TOKEN=${OPENCLAW_TOKEN:-}
OPENCLAW_MODEL=openclaw/default
# Voice pipeline (local, no cloud)
ASR_WS=ws://localhost:8002
TTS_URL=http://localhost:8003/v1/audio/speech
EOF
sudo chmod 600 /etc/spark-sovereign/telegram.env

sudo tee /etc/systemd/system/spark-telegram.service > /dev/null << EOF
[Unit]
Description=spark-sovereign Telegram bot (OpenClaw bridge)
After=network-online.target spark-sovereign.service
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
EnvironmentFile=/etc/spark-sovereign/telegram.env
ExecStart=$(which python3) ${REPO_ROOT}/agent/telegram_bot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable spark-telegram.service
sudo systemctl restart spark-telegram.service

echo "    Service installed and started."

# ── Status ────────────────────────────────────────────────────────────────────
sleep 3
echo ""
echo ">>> Status:"
sudo systemctl status spark-telegram.service --no-pager --lines 10

echo ""
echo "========================================================"
echo " Telegram bot running (routing through OpenClaw)."
echo ""
echo " Send a message to your bot on Telegram."
echo " OpenClaw provides: tools, memory, web search, GitHub, SOUL.md."
echo ""
echo " Logs:    sudo journalctl -u spark-telegram -f"
echo " Restart: sudo systemctl restart spark-telegram"
echo " Stop:    sudo systemctl stop spark-telegram"
echo ""
echo " If the bot ignores messages, check OPENCLAW_TOKEN:"
echo "   cat ~/.nemoclaw/credentials.json"
echo "   sudo nano /etc/spark-sovereign/telegram.env"
echo "   sudo systemctl restart spark-telegram"
echo "========================================================"
echo ""
echo "Phase 9 complete."
