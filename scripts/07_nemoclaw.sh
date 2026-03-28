#!/usr/bin/env bash
# =============================================================================
# PHASE 7 — NemoClaw Agent Runtime
# =============================================================================
# Installs NemoClaw (NVIDIA's OpenClaw wrapper with OpenShell sandboxing).
# Sets up TWO sandboxes:
#   deep  — Brain model (Qwen3.5-122B, port 8000) — vision, reasoning, coding
#   fast  — Nano model (Nemotron-Nano, port 8001)  — quick replies, sub-agents
#
# Docs: https://docs.nvidia.com/nemoclaw/latest/index.html
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
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "    uv installed."
else
    echo "    uv already installed: $(uvx --version 2>/dev/null || echo 'ok')"
fi

# 1. Install NemoClaw
if ! command -v nemoclaw &>/dev/null; then
    echo ">>> Installing NemoClaw..."
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
    echo "    NemoClaw installed."
else
    echo "    NemoClaw already installed: $(nemoclaw --version 2>/dev/null || echo 'ok')"
fi

# 2. DGX Spark-specific setup (cgroup v2 — must run after Docker restart in Phase 1)
echo ">>> Running NemoClaw DGX Spark setup..."
nemoclaw setup-spark || echo "    setup-spark already done or not needed."

# 3. Install openclaw.json
# NemoClaw onboard writes ~/.nemoclaw/config.json separately (inference endpoint).
# ~/.openclaw/openclaw.json is OpenClaw's config — MCP servers, model routing.
echo ">>> Installing ~/.openclaw/openclaw.json..."
mkdir -p ~/.openclaw

python3 - << PYEOF
import json, os, re

repo_root = os.environ.get('REPO_ROOT', '.')
with open(f'{repo_root}/config/openclaw.json', encoding='utf-8') as f:
    content = f.read()

# Substitute \${ENV_VAR} placeholders from environment
def replace_env(m):
    return os.environ.get(m.group(1), m.group(0))
content = re.sub(r'\\\$\{([A-Z_]+)\}', replace_env, content)

# Strip _comment / _note / _docs fields
cfg = json.loads(content)
def strip_meta(obj):
    if isinstance(obj, dict):
        return {k: strip_meta(v) for k, v in obj.items() if not k.startswith('_')}
    if isinstance(obj, list):
        return [strip_meta(i) for i in obj]
    return obj

cfg = strip_meta(cfg)

dest = os.path.expanduser('~/.openclaw/openclaw.json')
with open(dest, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f'    Written: {dest}')
PYEOF

# 4. Set up sandboxes via NemoClaw onboard
# "deep" sandbox → Brain (Qwen3.5-122B, port 8000) — vision + reasoning
# "fast" sandbox → Nano (port 8001) — quick tasks, sub-agents

echo ""
echo ">>> Setting up 'deep' sandbox (Brain — Qwen3.5-122B, port 8000)..."
echo "    (vision + deep reasoning + coding)"
nemoclaw onboard \
    --name deep \
    --inference-url http://localhost:8000/v1 \
    --model qwen35-122b \
    --non-interactive 2>/dev/null \
    || echo "    'deep' sandbox already exists or onboard requires interactive mode — run: nemoclaw onboard --name deep"

echo ""
echo ">>> Setting up 'fast' sandbox (Nano — Nemotron-Nano, port 8001)..."
echo "    (quick replies, sub-agents, Telegram/Slack fast responses)"
nemoclaw onboard \
    --name fast \
    --inference-url http://localhost:8001/v1 \
    --model nemotron-nano \
    --non-interactive 2>/dev/null \
    || echo "    'fast' sandbox already exists or onboard requires interactive mode — run: nemoclaw onboard --name fast"

# 5. Apply Telegram and Slack policy presets (allows outbound to those services from sandbox)
echo ""
echo ">>> Applying channel policy presets..."
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    nemoclaw deep policy-add telegram 2>/dev/null || true
    nemoclaw fast policy-add telegram 2>/dev/null || true
    echo "    Telegram policy applied to both sandboxes."
fi
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    nemoclaw deep policy-add slack 2>/dev/null || true
    nemoclaw fast policy-add slack 2>/dev/null || true
    echo "    Slack policy applied to both sandboxes."
fi

# 6. Start both sandboxes
echo ""
echo ">>> Starting sandboxes..."
nemoclaw start 2>/dev/null || true
nemoclaw deep status 2>/dev/null || true
nemoclaw fast status 2>/dev/null || true

echo ""
echo "========================================================"
echo " NemoClaw ready."
echo ""
echo " Switch between sandboxes:"
echo "   nemoclaw deep connect    # Brain — vision, coding, reasoning"
echo "   nemoclaw fast connect    # Nano  — quick replies, sub-agents"
echo ""
echo " List all sandboxes:  nemoclaw list"
echo " Monitor:             openshell term"
echo "========================================================"
echo ""
echo "Phase 7 complete. Proceed to: scripts/08_aider.sh"
