#!/usr/bin/env bash
# =============================================================================
# Stack Health Check — spark-sovereign
# Run any time to verify all services are up and models are responding.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-localonly}"
POSTGRES_DB="${POSTGRES_DB:-agent_memory}"

get_port() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
import sys
keys = '$1'.split('.')
node = cfg
for k in keys:
    node = node.get(k, {})
print(node if isinstance(node, (str,int)) else '')
" 2>/dev/null || echo ""
}

BRAIN_PORT=$(get_port brain.port)
NANO_PORT=$(get_port subagent.port)
ASR_PORT=$(get_port asr.port)
TTS_PORT=$(get_port tts.port)
PG_PORT=$(get_port infrastructure.pgvector.port)
SEARXNG_PORT=$(get_port infrastructure.searxng.port)
UI_PORT=$(get_port infrastructure.nemoclaw.ui_port)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         spark-sovereign — Stack Health Check             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── System memory ─────────────────────────────────────────────────────────────
echo "── Memory ──────────────────────────────────────────────────"
free -h | grep -E "Mem|Swap"
echo ""

# ── GPU ───────────────────────────────────────────────────────────────────────
echo "── GPU ─────────────────────────────────────────────────────"
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu \
    --format=csv,noheader 2>/dev/null \
    | awk -F, '{printf "  %-30s  Total:%-8s Used:%-8s Free:%-8s  GPU:%s\n",$1,$2,$3,$4,$5}' \
    || echo "  nvidia-smi not available"
echo ""

# ── Model endpoints ───────────────────────────────────────────────────────────
echo "── Model Endpoints ─────────────────────────────────────────"

check_vllm() {
    local label="$1" port="$2"
    local result
    result=$(curl -sf "http://localhost:${port}/v1/models" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
        2>/dev/null || echo "")
    if [ -n "${result}" ]; then
        printf "  %-22s ✅  %s\n" "${label}:" "${result}"
    else
        printf "  %-22s ❌  not responding (port %s)\n" "${label}:" "${port}"
    fi
}

check_vllm "Brain (8000)" "${BRAIN_PORT}"
check_vllm "Nano  (8001)" "${NANO_PORT}"

echo ""

# ── Docker containers ─────────────────────────────────────────────────────────
echo "── Containers ──────────────────────────────────────────────"
for name in brain nemotron-nano pgvector searxng asr-server tts-server; do
    status=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo "not found")
    uptime=$(docker inspect -f '{{.State.StartedAt}}' "${name}" 2>/dev/null \
        | python3 -c "
import sys, datetime
s = sys.stdin.read().strip()
if s:
    try:
        t = datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
        delta = datetime.datetime.now(datetime.timezone.utc) - t
        h, rem = divmod(int(delta.total_seconds()), 3600)
        m = rem // 60
        print(f'up {h}h{m}m')
    except:
        print('')
" 2>/dev/null || echo "")
    icon="✅"; [ "${status}" != "running" ] && icon="❌"
    printf "  ${icon} %-22s %s  %s\n" "${name}:" "${status}" "${uptime}"
done
echo ""

# ── Services ──────────────────────────────────────────────────────────────────
echo "── Services ────────────────────────────────────────────────"

check_http() {
    local label="$1" url="$2"
    if curl -sf --max-time 3 "${url}" > /dev/null 2>&1; then
        printf "  ✅ %-22s %s\n" "${label}:" "${url}"
    else
        printf "  ❌ %-22s %s\n" "${label}:" "${url}"
    fi
}

check_http "SearXNG"         "http://localhost:${SEARXNG_PORT}/search?q=test&format=json"
check_http "NemoClaw UI"     "http://localhost:${UI_PORT}"
echo ""

# ── pgvector memory stats ─────────────────────────────────────────────────────
echo "── Memory DB (pgvector) ─────────────────────────────────────"
if docker inspect pgvector &>/dev/null 2>&1 && \
   [ "$(docker inspect -f '{{.State.Status}}' pgvector)" = "running" ]; then
    docker exec pgvector psql -U postgres -d "${POSTGRES_DB}" -t -q 2>/dev/null << 'SQL'
SELECT '  Lessons total:          ' || COUNT(*) FROM lessons;
SELECT '  Lessons (success):      ' || COUNT(*) FROM lessons WHERE outcome='success';
SELECT '  Lessons (failure):      ' || COUNT(*) FROM lessons WHERE outcome='failure';
SELECT '  Web cache total:        ' || COUNT(*) FROM rag_cache;
SELECT '  Web cache (verified):   ' || COUNT(*) FROM rag_cache WHERE verified=TRUE;
SQL
else
    echo "  pgvector container not running"
fi
echo ""

echo "── Logs ────────────────────────────────────────────────────"
LOG_FILE="${HOME}/.spark-sovereign/logs/spark.log"
if [ -f "${LOG_FILE}" ]; then
    SIZE=$(du -sh "${LOG_FILE}" | cut -f1)
    echo "  ${LOG_FILE} (${SIZE})"
    echo "  Last 5 lines:"
    tail -5 "${LOG_FILE}" | sed 's/^/    /'
    echo "  Full log: tail -f ${LOG_FILE}"
    echo "  Debug:    LOG_LEVEL=DEBUG python3 agent/router.py"
else
    echo "  No log file yet — written on first agent/router.py or memory.py call"
    echo "  Expected: ${LOG_FILE}"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
