#!/usr/bin/env bash
# NOTE: This script is not necessary. OpenClaw's onboard setup handles
# memory and RAG — no separate pgvector instance needed.
# =============================================================================
# PHASE 5 — pgvector + RAG Memory DB
# =============================================================================
# Starts pgvector/pgvector:pg17 (pgvector 0.8.2 on PostgreSQL 17).
# Applies schema from config/pgvector/init.sql.
# Data persists to /opt/pgvector on the 4TB NVMe.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-localonly}"
POSTGRES_DB="${POSTGRES_DB:-agent_memory}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('infrastructure', {}).get('pgvector', {}).get('$1', ''))
"
}

PG_PORT=$(get_field port)
PG_DATA=$(get_field data_path)
PG_IMAGE=$(get_field image)

echo "========================================================"
echo " spark-sovereign — Phase 5: pgvector"
echo "========================================================"
echo "  Image:   ${PG_IMAGE}"
echo "  Port:    ${PG_PORT}"
echo "  Data:    ${PG_DATA}"
echo ""

sudo mkdir -p "${PG_DATA}"
sudo chown -R "$(whoami):$(whoami)" "${PG_DATA}"

docker rm -f pgvector 2>/dev/null || true

docker run -d --name pgvector \
    --network host \
    --restart unless-stopped \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -v "${PG_DATA}:/var/lib/postgresql/data" \
    "${PG_IMAGE}"

echo "    Container pgvector starting..."
sleep 8

# Apply schema
echo ">>> Applying schema from config/pgvector/init.sql..."
docker exec -i pgvector psql -U postgres -d "${POSTGRES_DB}" \
    < "${REPO_ROOT}/config/pgvector/init.sql"
echo "    Schema applied."

# Quick sanity check
echo ""
echo ">>> Verifying extensions + tables..."
docker exec pgvector psql -U postgres -d "${POSTGRES_DB}" -c "
SELECT extname, extversion FROM pg_extension WHERE extname='vector';
SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;
"

echo ""
echo "pgvector is ready at localhost:${PG_PORT}"
echo "Connection string: postgresql://postgres:${POSTGRES_PASSWORD}@localhost/${POSTGRES_DB}"
echo ""
echo "Phase 5 complete. Proceed to: scripts/06_searxng.sh"
