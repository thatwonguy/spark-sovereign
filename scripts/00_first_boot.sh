#!/usr/bin/env bash
# =============================================================================
# PHASE 0 — Box Open to SSH
# =============================================================================
# This is a GUIDE script — most of Phase 0 is manual steps.
# Run it after SSH is working to install Tailscale on the Spark.
#
# The correct order is:
#   Step 1: Physical setup + first boot wizard   (manual, ~15 min)
#   Step 2: Install NVIDIA Sync on your laptop   (manual, ~5 min)
#   Step 3: Add Spark in NVIDIA Sync             (manual, ~5 min)
#   Step 4: SSH into Spark                       (via Sync Terminal)
#   Step 5: Run this script on the Spark         (automated)
# =============================================================================

set -euo pipefail

# Detect if running on the Spark or on a laptop — guide only if not on Linux
if [[ "$(uname)" != "Linux" ]]; then
    echo "This script runs ON the Spark (Linux), not on your laptop."
    echo "Follow the manual steps below first, then SSH in and re-run."
    exit 0
fi

echo "========================================================"
echo " spark-sovereign — Phase 0: Post-SSH Setup"
echo " (Physical setup and NVIDIA Sync must be done first)"
echo "========================================================"

# -----------------------------------------------------------------------------
# MANUAL STEPS — read before running anything
# -----------------------------------------------------------------------------
cat <<'MANUAL'

BEFORE RUNNING THIS SCRIPT — complete these manual steps:

────────────────────────────────────────────────────────────
STEP 1: PHYSICAL SETUP
────────────────────────────────────────────────────────────
  • There is NO power button. Plugging in power = immediate boot.
  • Connect peripherals BEFORE plugging in power.
  • Connect via wired Ethernet if possible (plug in before power).
  • Need 150mm clearance on all sides. Ambient temp < 30C.
  • If no display on USB-C/DisplayPort, switch to HDMI.

────────────────────────────────────────────────────────────
STEP 2: FIRST BOOT WIZARD (two options — choose one)
────────────────────────────────────────────────────────────
  OPTION A — Headless (no monitor required, recommended):
    • Spark creates a WiFi hotspot on boot.
    • SSID and password are on the sticker inside the box.
      Without this sticker, headless setup is blocked.
    • Connect your laptop to that hotspot SSID.
    • Browser captive portal opens automatically.
      If it does not open, navigate to the URL on the sticker.

  OPTION B — Local setup (monitor + keyboard attached):
    • Setup wizard starts automatically on the display.

  BOTH OPTIONS — wizard sequence:
    1. Language + timezone
    2. Accept Terms and Conditions
    3. Create username + password  ← WRITE THESE DOWN
    4. Select your home WiFi network + enter password
       ⚠ WPA2-Enterprise / 802.1X networks NOT supported here.
         Use a phone hotspot for first boot, configure enterprise
         WiFi manually via NetworkManager afterward.
    5. Device joins network, hotspot turns off
    6. Software downloads + installs automatically (~10 min)
       ⚠ DO NOT power off or reboot during this step.
         Cannot be resumed. May require factory reset if interrupted.
    7. Final reboot — device is ready

  Spark is now reachable at: spark-XXXX.local
  (XXXX is the hostname on the Quick Start Guide sticker)

────────────────────────────────────────────────────────────
STEP 3: INSTALL NVIDIA SYNC ON YOUR LAPTOP
────────────────────────────────────────────────────────────
  Download: https://build.nvidia.com/spark/connect-to-your-spark/sync
  Available for: macOS, Windows, Ubuntu/Debian

  After install:
    1. Open NVIDIA Sync from system tray (it auto-starts)
    2. Click Settings (gear icon, top-left) → Devices tab → Add Device
    3. Select your Spark from the discovery list, or enter:
         Hostname: spark-XXXX.local  (from Quick Start Guide)
         Port:     22
         Username: (from wizard)
         Password: (from wizard — used ONCE, then discarded)
    4. Click Add
    5. Wait 3-4 minutes for Spark to update and appear as available

  NVIDIA Sync auto-generates SSH keys and configures passwordless access.
  The password is NOT stored — SSH key auth only after first connect.

────────────────────────────────────────────────────────────
STEP 4: SSH INTO SPARK
────────────────────────────────────────────────────────────
  In NVIDIA Sync: select your device → click Terminal
  Or manually: ssh <username>@spark-XXXX.local

  Verify:
    hostname
    uname -a
    nvidia-smi   (note: "Memory-Usage: Not Supported" is NORMAL on Spark)

────────────────────────────────────────────────────────────
STEP 5: Run this script on the Spark (you are here)
────────────────────────────────────────────────────────────
  bash scripts/00_first_boot.sh
MANUAL

echo ""
read -rp "Have you completed Steps 1-4 above? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
    echo "Complete the manual steps first, then re-run."
    exit 0
fi

# -----------------------------------------------------------------------------
# Automated post-SSH setup
# -----------------------------------------------------------------------------

# Add user to docker group (eliminates need for sudo on every docker command)
echo ""
echo ">>> Adding ${USER} to docker group..."
if groups | grep -q docker; then
    echo "    Already in docker group."
else
    sudo usermod -aG docker "${USER}"
    echo "    Done. Run 'newgrp docker' or log out/in to activate."
fi

# Tailscale — for access from anywhere
# NOTE: Do NOT install Tailscale on your laptop separately.
#       NVIDIA Sync IS the Tailscale node on the laptop side.
#       Only install Tailscale here on the Spark itself.
echo ""
echo ">>> Installing Tailscale on the Spark (for remote access from anywhere)..."
if command -v tailscale &>/dev/null; then
    echo "    Tailscale already installed: $(tailscale version)"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "    Tailscale installed."
fi

echo ""
echo ">>> Starting Tailscale auth..."
sudo tailscale up
echo ""
echo "    Spark's Tailscale IP:"
tailscale ip -4

cat <<'TAILSCALE_NOTE'

────────────────────────────────────────────────────────────
TAILSCALE NOTE:
  The Tailscale client is now on the Spark.
  To connect from your laptop, use NVIDIA Sync:
    Settings → Tailscale → Enable Tailscale → Add a Device
  NVIDIA Sync handles the laptop side — do NOT install
  the Tailscale app on your laptop separately.

  To access Spark from your phone or other devices:
    Install Tailscale app → sign in to same account → done.

  IMPORTANT: To remove Spark from Tailscale later, you must
  be on the same local network (direct connection). You cannot
  unenroll over a Tailscale connection.
────────────────────────────────────────────────────────────

TAILSCALE_NOTE

echo ""
echo "Phase 0 complete."
echo "Next: bash scripts/01_system_prep.sh"
