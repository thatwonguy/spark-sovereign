#!/usr/bin/env bash
# =============================================================================
# PHASE 7 — NemoClaw Agent Runtime
# =============================================================================
# Installs NemoClaw (NVIDIA's OpenClaw wrapper with OpenShell sandboxing).
#
# CRITICAL ORDER on DGX Spark:
#   1. nemoclaw setup-spark   ← MUST run FIRST (fixes cgroup v2 for Ubuntu 24.04)
#   2. curl installer         ← standard install
#   3. nemoclaw onboard       ← interactive wizard (cannot be skipped)
#
# Sets up ONE sandbox:
#   deep  — Brain (Qwen3.5-35B-A3B, port 8000) — vision, reasoning, coding, tools
#
# Docs: https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html
# DGX Spark specific: https://docs.nvidia.com/nemoclaw/latest/get-started/dgx-spark.html
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

echo "========================================================"
echo " spark-sovereign — Phase 7: NemoClaw"
echo "========================================================"

# 0. Install uv (required for Python MCP servers: mcp-server-git, mcp-server-fetch)
if ! command -v uvx &>/dev/null; then
    echo ">>> Installing uv (required for Python MCP servers)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.cargo/bin:${PATH}"
    echo "    uv installed."
else
    echo "    uv already installed."
fi

# 1. Docker group check
if ! groups | grep -q docker; then
    echo ">>> Adding ${USER} to docker group..."
    sudo usermod -aG docker "${USER}"
    newgrp docker
fi

# 2. DGX Spark cgroup v2 fix — MUST run before installer
#    Ubuntu 24.04 uses cgroup v2. Without this, Docker defaults break
#    the OpenShell k3s sandbox and onboarding fails silently.
echo ""
echo ">>> Applying DGX Spark cgroup v2 fix (required on Ubuntu 24.04)..."
if command -v nemoclaw &>/dev/null; then
    sudo nemoclaw setup-spark || echo "    setup-spark already applied."
else
    # Pre-install: apply the Docker daemon config manually
    echo "    NemoClaw not yet installed — applying cgroup fix manually..."
    sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    sudo python3 -c "
import json, os
p = '/etc/docker/daemon.json'
d = json.load(open(p)) if os.path.exists(p) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(p,'w'), indent=2)
print('    daemon.json updated.')
"
    sudo systemctl restart docker
    echo "    Docker restarted with cgroup v2 fix."
fi

# 3. Install NemoClaw
echo ""
if ! command -v nemoclaw &>/dev/null; then
    echo ">>> Installing NemoClaw..."
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

    # Reload PATH — installer uses nvm/fnm which modifies PATH in .bashrc
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" 2>/dev/null || true
    export PATH="${HOME}/.nvm/versions/node/$(ls "${HOME}/.nvm/versions/node/" 2>/dev/null | tail -1)/bin:${PATH}" 2>/dev/null || true

    if ! command -v nemoclaw &>/dev/null; then
        echo ""
        echo "  nemoclaw command not found after install."
        echo "  This is a known PATH issue with nvm/fnm."
        echo "  Fix: run 'source ~/.bashrc' then re-run this script."
        exit 1
    fi
    echo "    NemoClaw installed: $(nemoclaw --version 2>/dev/null || echo 'ok')"
else
    echo "    NemoClaw already installed."
fi

# 4. Run setup-spark now that nemoclaw is installed (idempotent)
echo ""
echo ">>> Running nemoclaw setup-spark..."
sudo nemoclaw setup-spark || echo "    Already applied."

# 5. Install openclaw.json with env var substitution
echo ""
echo ">>> Installing ~/.openclaw/openclaw.json..."
mkdir -p ~/.openclaw

python3 - <<PYEOF
import json, os, re

repo_root = '${REPO_ROOT}'
with open(f'{repo_root}/config/openclaw.json', encoding='utf-8') as f:
    content = f.read()

def replace_env(m):
    return os.environ.get(m.group(1), m.group(0))
content = re.sub(r'\\\$\{([A-Z_]+)\}', replace_env, content)

def strip_meta(obj):
    if isinstance(obj, dict):
        return {k: strip_meta(v) for k, v in obj.items() if not k.startswith('_')}
    if isinstance(obj, list):
        return [strip_meta(i) for i in obj]
    return obj

cfg = strip_meta(json.loads(content))
dest = os.path.expanduser('~/.openclaw/openclaw.json')
with open(dest, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f'    Written: {dest}')
PYEOF

# 6. Interactive onboarding
#    NemoClaw onboard is interactive — it cannot be skipped or automated.
#    The wizard sets up the first sandbox and inference endpoint.
echo ""
echo "========================================================"
echo " NemoClaw ONBOARDING — interactive wizard"
echo ""
echo " When prompted:"
echo "   • Quickstart vs Manual    → Quickstart"
echo "   • Model provider          → Other OpenAI-compatible endpoint"
echo "     URL:   http://localhost:8000/v1"
echo "     Model: qwen35-35b-a3b"
echo "   • Communication channel   → Skip for now"
echo "     (configure Telegram in .env later)"
echo "   • Hooks                   → Enable all three"
echo "   • Sandbox name            → deep"
echo "   • Policy presets          → n  (skip — no NVIDIA API key needed)"
echo "========================================================"
echo ""
read -rp "Press Enter to start onboarding, or Ctrl+C to exit..."

nemoclaw onboard

# 7. Apply channel policy presets (only if tokens are configured in .env)
echo ""
echo ">>> Applying policy presets..."
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    nemoclaw deep policy-add telegram 2>/dev/null || true
    echo "    Telegram policy applied."
fi

# 8. Start
echo ""
nemoclaw start 2>/dev/null || true

echo ""
echo "========================================================"
echo " NemoClaw ready."
echo ""
echo " Usage:"
echo "   nemoclaw deep connect    # connect to deep sandbox"
echo "   openclaw tui             # interactive chat inside sandbox"
echo "   nemoclaw list            # all sandboxes"
echo "   nemoclaw deep logs --follow"
echo "   openshell term           # real-time sandbox monitor"
echo ""
echo " To enable Telegram: add TELEGRAM_BOT_TOKEN to .env, re-run script."
echo "========================================================"
echo ""
echo "Phase 7 complete. Proceed to: scripts/08_aider.sh"
