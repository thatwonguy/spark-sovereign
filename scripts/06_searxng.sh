#!/usr/bin/env bash
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

docker run -d --name searxng \
    --network host \
    --restart unless-stopped \
    -v "${SEARXNG_CONFIG}:/etc/searxng" \
    -e SEARXNG_SECRET_KEY="${SECRET_KEY}" \
    "${SEARXNG_IMAGE}"

echo "    Container searxng started."
sleep 5

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
