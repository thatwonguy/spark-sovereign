#!/usr/bin/env bash
# NOTE: This script is not necessary. Telegram integration is handled by
# OpenClaw's onboard channels setup — no separate bot service needed.
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
echo "  OpenClaw gateway: http://localhost:18789 (no auth — loopback mode)"

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
# Gateway runs in loopback/no-auth mode — no token needed
OPENCLAW_URL=http://localhost:18789
OPENCLAW_MODEL=openclaw
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
echo " If the bot ignores messages, check OpenClaw gateway:"
echo "   openclaw gateway status"
echo "   openclaw gateway logs"
echo "========================================================"
echo ""
echo "Phase 9 complete."
