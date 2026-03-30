#!/usr/bin/env bash
# =============================================================================
# PHASE 7 — OpenClaw Agent Runtime (standalone, no NVIDIA account required)
# =============================================================================
# Installs OpenClaw — the agentic layer that sits on top of your local Brain.
# Brain (vLLM port 8000) → OpenClaw gateway (port 18789) → all tools + memory
#
# No NVIDIA API key needed. No cloud relay. Fully local.
#
# Docs: https://docs.openclaw.ai
# vLLM provider: https://docs.openclaw.ai/providers/vllm
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

echo "========================================================"
echo " spark-sovereign — Phase 7: OpenClaw"
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

# 1. Install Node.js if missing (required for npx MCP servers)
if ! command -v node &>/dev/null; then
    echo ">>> Installing Node.js via nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    # shellcheck source=/dev/null
    export NVM_DIR="${HOME}/.nvm"
    source "${NVM_DIR}/nvm.sh"
    nvm install --lts
    nvm use --lts
    echo "    Node.js $(node --version) installed."
else
    echo "    Node.js $(node --version) already installed."
fi

# 2. Install OpenClaw
echo ""
if ! command -v openclaw &>/dev/null; then
    echo ">>> Installing OpenClaw..."
    curl -fsSL https://openclaw.ai/install.sh | bash

    # Reload PATH — installer may modify .bashrc
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" 2>/dev/null || true
    export NVM_DIR="${HOME}/.nvm"
    source "${NVM_DIR}/nvm.sh" 2>/dev/null || true

    if ! command -v openclaw &>/dev/null; then
        echo ""
        echo "  openclaw not found after install — likely a PATH issue."
        echo "  Fix: run 'source ~/.bashrc' then re-run this script."
        exit 1
    fi
    echo "    OpenClaw installed: $(openclaw --version 2>/dev/null || echo 'ok')"
else
    echo "    OpenClaw already installed: $(openclaw --version 2>/dev/null || echo 'ok')"
fi

# 3. Install openclaw.json config
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
content = re.sub(r'\$\{([A-Z_]+)\}', replace_env, content)

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

# 4. Install workspace identity files (IDENTITY.md + SOUL.md)
echo ""
echo ">>> Installing workspace identity files..."
mkdir -p ~/.openclaw/workspace
for f in IDENTITY.md SOUL.md; do
    if [ -f "${REPO_ROOT}/config/workspace/${f}" ]; then
        cp "${REPO_ROOT}/config/workspace/${f}" ~/.openclaw/workspace/"${f}"
        echo "    Written: ~/.openclaw/workspace/${f}"
    fi
done

# 5. Verify Brain is reachable before starting gateway
echo ""
echo ">>> Checking Brain is reachable at localhost:8000..."
if curl -sf http://localhost:8000/v1/models >/dev/null 2>&1; then
    echo "    Brain ready."
else
    echo "    WARNING: Brain not responding at localhost:8000."
    echo "    Make sure Brain is running before using OpenClaw."
    echo "    Start it with: bash scripts/start_brain_ad_hoc.sh"
fi

# 6. Start OpenClaw gateway
echo ""
echo ">>> Starting OpenClaw gateway..."
openclaw gateway start 2>/dev/null || openclaw gateway restart 2>/dev/null || true
sleep 2

# Verify gateway is up
if curl -sf http://localhost:18789/api/status >/dev/null 2>&1; then
    echo "    Gateway running at http://localhost:18789"
else
    echo "    Gateway may still be starting — check: openclaw gateway status"
fi

echo ""
echo "========================================================"
echo " OpenClaw ready."
echo ""
echo " Usage:"
echo "   openclaw tui              # interactive chat (terminal UI)"
echo "   openclaw gateway status   # check gateway"
echo "   openclaw gateway logs     # view logs"
echo "   openclaw gateway restart  # restart after config changes"
echo ""
echo " API endpoint:"
echo "   POST http://localhost:18789/v1/responses"
echo ""
echo " Config: ~/.openclaw/openclaw.json"
echo " Identity: ~/.openclaw/workspace/SOUL.md"
echo "========================================================"
echo ""
echo "Phase 7 complete. Proceed to: scripts/08_aider.sh"
