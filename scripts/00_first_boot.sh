#!/usr/bin/env bash
# =============================================================================
# PHASE 0 — First Boot + NVIDIA Sync Setup
# =============================================================================
# Run this ONCE on first power-on using a monitor + keyboard attached to Spark.
# After this phase, all subsequent interaction is remote via NVIDIA Sync / SSH.
# =============================================================================

set -euo pipefail

echo "========================================================"
echo " spark-sovereign — Phase 0: First Boot"
echo "========================================================"

# 0a. FIRST BOOT (captive portal — manual step)
cat <<'MANUAL'
────────────────────────────────────────────────────────────
MANUAL STEP (captive portal — do this before running script):

  1. On first boot, Spark creates a WiFi hotspot.
  2. Connect your laptop to the SSID printed on the Quick Start Guide.
  3. Browser opens captive portal → follow prompts.
  4. Create username + password → join your home network.
  5. Hotspot turns off. Spark is now on your LAN.

  Then SSH in: ssh <your-username>@spark-XXXX.local
────────────────────────────────────────────────────────────
MANUAL

# 0b. NVIDIA Sync laptop install (informational)
cat <<'MANUAL'
────────────────────────────────────────────────────────────
INSTALL NVIDIA SYNC ON YOUR LAPTOP (macOS or Windows):

  Download: https://build.nvidia.com/spark/connect-to-your-spark/sync

  After install:
    1. Open NVIDIA Sync from system tray.
    2. Click Add Device → enter spark-XXXX.local, username, password.
    3. NVIDIA Sync auto-generates SSH keys + configures passwordless access.
    4. One-click to connect, launch VS Code, open terminal.
────────────────────────────────────────────────────────────
MANUAL

# 0c. Tailscale — global encrypted access from anywhere
echo ""
echo ">>> Installing Tailscale for remote access..."

if command -v tailscale &>/dev/null; then
    echo "    Tailscale already installed."
else
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo ""
echo ">>> Starting Tailscale (will open browser for auth)..."
sudo tailscale up

echo ""
echo ">>> Your Tailscale IP:"
tailscale ip -4

cat <<'INFO'

────────────────────────────────────────────────────────────
TAILSCALE SETUP COMPLETE.

  From anywhere (phone, coffee shop, Italy):
    ssh <username>@<tailscale-ip>

  In NVIDIA Sync: Settings → Tailscale → enable integration
  for one-click remote access from the Sync UI.
────────────────────────────────────────────────────────────
INFO

echo ""
echo "Phase 0 complete. Proceed to: scripts/01_system_prep.sh"
