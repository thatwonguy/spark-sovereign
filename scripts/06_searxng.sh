#!/usr/bin/env bash
# NOTE: This script is not necessary. OpenClaw's onboard setup handles
# web search — no separate SearXNG instance needed.
# =============================================================================
# PHASE 6 — SearXNG Web Search
# =============================================================================
# Local, private, no-API-key web search.
# Results feed the pgvector RAG cache via agent/memory.py.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('infrastructure', {}).get('searxng', {}).get('$1', ''))
"
}

SEARXNG_PORT=$(get_field port)
SEARXNG_CONFIG=$(get_field config_path)
SEARXNG_IMAGE=$(get_field image)
SECRET_KEY="${SEARXNG_SECRET_KEY:-$(openssl rand -hex 32)}"

echo "========================================================"
echo " spark-sovereign — Phase 6: SearXNG"
echo "========================================================"
echo "  Image:  ${SEARXNG_IMAGE}"
echo "  Port:   ${SEARXNG_PORT}"
echo "  Config: ${SEARXNG_CONFIG}"
echo ""

sudo mkdir -p "${SEARXNG_CONFIG}"
sudo chown -R "$(whoami):$(whoami)" "${SEARXNG_CONFIG}"

docker rm -f searxng 2>/dev/null || true

# Start briefly to generate default settings.yml (if not already present)
if [ ! -f "${SEARXNG_CONFIG}/settings.yml" ]; then
    echo "    Generating default settings.yml..."
    docker run --rm \
        -v "${SEARXNG_CONFIG}:/etc/searxng" \
        -e SEARXNG_SECRET_KEY="${SECRET_KEY}" \
        "${SEARXNG_IMAGE}" \
        sh -c "cp /etc/searxng/settings.yml /etc/searxng/settings.yml.bak 2>/dev/null; cat /usr/local/searxng/searx/settings.yml > /etc/searxng/settings.yml" \
        2>/dev/null || true
    sleep 2
fi

# Enable JSON format (required for agent/memory.py RAG queries)
SETTINGS="${SEARXNG_CONFIG}/settings.yml"
if [ -f "${SETTINGS}" ]; then
    python3 - <<PYEOF
import re
with open('${SETTINGS}') as f:
    txt = f.read()
# Add json to formats list if not already present
if '- json' not in txt:
    txt = re.sub(r'(formats:\s*\n(\s+- html\b.*\n?))', r'\1\2  - json\n', txt)
    # fallback: append formats block if pattern didn't match
    if '- json' not in txt:
        txt = txt.rstrip() + '\nsearch:\n  formats:\n    - html\n    - json\n'
    with open('${SETTINGS}', 'w') as f:
        f.write(txt)
    print('    JSON format enabled in settings.yml')
else:
    print('    JSON format already enabled.')
PYEOF
fi

docker run -d --name searxng \
    -p "${SEARXNG_PORT}:8080" \
    --restart unless-stopped \
    -v "${SEARXNG_CONFIG}:/etc/searxng" \
    -e SEARXNG_SECRET_KEY="${SECRET_KEY}" \
    "${SEARXNG_IMAGE}"

echo "    Container searxng started."

# Wait for it to be ready
echo "    Waiting for SearXNG to be ready..."
until curl -sf "http://localhost:${SEARXNG_PORT}/" >/dev/null 2>&1; do
    sleep 3
done

# Smoke test
echo ""
echo ">>> Smoke test..."
RESULT=$(curl -sf "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['results'][0].get('title','no title'))" \
    2>/dev/null || echo "still starting — check again in 10s")
echo "    First result: ${RESULT}"

echo ""
echo "SearXNG is at: http://localhost:${SEARXNG_PORT}"
echo "JSON API:      http://localhost:${SEARXNG_PORT}/search?q=<query>&format=json"
echo ""
echo "Phase 6 complete. Proceed to: scripts/07_nemoclaw.sh"
