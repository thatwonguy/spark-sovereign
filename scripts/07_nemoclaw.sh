#!/usr/bin/env bash
# =============================================================================
# PHASE 7 — NemoClaw Agent Runtime
# =============================================================================
# Installs NemoClaw + OpenClaw, applies config/openclaw.json,
# and starts the agent UI on port 18789.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('infrastructure', {}).get('nemoclaw', {}).get('$1', ''))
"
}

UI_PORT=$(get_field ui_port)

echo "========================================================"
echo " spark-sovereign — Phase 7: NemoClaw"
echo "========================================================"

# Install NemoClaw (DGX Spark native — handles cgroup v2)
if ! command -v nemoclaw &>/dev/null; then
    echo ">>> Installing NemoClaw..."
    curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
    echo "    NemoClaw installed."
else
    echo "    NemoClaw already installed."
fi

# Build openclaw.json with env var substitution
echo ">>> Generating ~/.openclaw/openclaw.json..."
mkdir -p ~/.openclaw

python3 - << 'PYEOF'
import json, os, re

with open(os.environ.get('REPO_ROOT', '.') + '/config/openclaw.json') as f:
    content = f.read()

# Substitute ${ENV_VAR} placeholders
def replace_env(m):
    return os.environ.get(m.group(1), m.group(0))

content = re.sub(r'\$\{([A-Z_]+)\}', replace_env, content)

# Remove _comment fields
cfg = json.loads(content)
def strip_comments(obj):
    if isinstance(obj, dict):
        return {k: strip_comments(v) for k, v in obj.items() if not k.startswith('_')}
    if isinstance(obj, list):
        return [strip_comments(i) for i in obj]
    return obj

cfg = strip_comments(cfg)

dest = os.path.expanduser('~/.openclaw/openclaw.json')
with open(dest, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f'    Written to {dest}')
PYEOF

echo ""
echo ">>> Restarting NemoClaw..."
nemoclaw restart 2>/dev/null || nemoclaw start

echo ""
echo "NemoClaw is running."
echo "  UI:       http://localhost:${UI_PORT}"
echo "  Brain:    http://localhost:8000/v1 (qwen35-122b)"
echo "  Sub-agent: http://localhost:8001/v1 (nemotron-nano)"
echo ""
echo "Phase 7 complete. Proceed to: scripts/08_aider.sh"
