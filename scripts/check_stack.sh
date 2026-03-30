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
keys = '$1'.split('.')
node = cfg
for k in keys:
    node = node.get(k, {})
print(node if isinstance(node, (str,int)) else '')
" 2>/dev/null || echo ""
}

BRAIN_PORT=$(get_port brain.port)
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

# ── GPU — GB10 unified memory: show per-process allocation ────────────────────
echo "── GPU ─────────────────────────────────────────────────────"
nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{gsub(/ /,"",$2); printf "  %-28s  Utilization: %s%%\n",$1,$2}'
echo "  Process allocations:"
nvidia-smi --query-compute-apps=pid,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{
        pid=$1; mib=$2;
        gsub(/ /,"",pid); gsub(/ /,"",mib);
        gb=mib/1024;
        cmd="ps -p "pid" -o comm= 2>/dev/null"; cmd | getline name; close(cmd);
        printf "    PID %-8s %-20s %.1f GiB\n", pid, name, gb
    }' || echo "    (none)"
echo ""

# ── Model endpoints ───────────────────────────────────────────────────────────
echo "── Model Endpoints ─────────────────────────────────────────"

check_vllm() {
    local label="$1" port="$2"
    local result
    result=$(curl -sf --max-time 5 "http://localhost:${port}/v1/models" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
        2>/dev/null || echo "")
    if [ -n "${result}" ]; then
        printf "  %-22s ✅  %s\n" "${label}:" "${result}"
    else
        printf "  %-22s ❌  not responding (port %s)\n" "${label}:" "${port}"
    fi
}

check_vllm "Brain (8000)" "${BRAIN_PORT}"
echo ""

# ── Docker containers ─────────────────────────────────────────────────────────
echo "── Containers ──────────────────────────────────────────────"
for name in brain pgvector searxng asr-server tts-server; do
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

# SearXNG: check base reachability, then JSON format specifically
SEARXNG_BASE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    "http://localhost:${SEARXNG_PORT}/" 2>/dev/null || echo "000")
SEARXNG_JSON=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    "http://localhost:${SEARXNG_PORT}/search?q=test&format=json" 2>/dev/null || echo "000")

if [ "${SEARXNG_BASE}" = "200" ] && [ "${SEARXNG_JSON}" = "200" ]; then
    printf "  ✅ %-22s http://localhost:%s  (JSON enabled)\n" "SearXNG:" "${SEARXNG_PORT}"
elif [ "${SEARXNG_BASE}" = "200" ]; then
    printf "  ⚠️  %-22s running but JSON format disabled (HTTP %s)\n" "SearXNG:" "${SEARXNG_JSON}"
    echo "      Fix: add '  - json' under 'formats:' in /opt/searxng/settings.yml"
    echo "           then: docker restart searxng"
else
    printf "  ❌ %-22s not responding (HTTP %s)\n" "SearXNG:" "${SEARXNG_BASE}"
fi

# ASR/TTS: check health endpoints
for svc_info in "ASR (8002):${ASR_PORT}" "TTS (8003):${TTS_PORT}"; do
    svc_label="${svc_info%%:*}"
    svc_port="${svc_info##*:}"
    http_code=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
        "http://localhost:${svc_port}/health" 2>/dev/null || echo "000")
    if [ "${http_code}" = "200" ]; then
        printf "  ✅ %-22s http://localhost:%s/health\n" "${svc_label}:" "${svc_port}"
    else
        printf "  ❌ %-22s not responding (HTTP %s)\n" "${svc_label}:" "${svc_port}"
    fi
done

# NemoClaw: check sandbox status via CLI (not port forward)
NEMOCLAW_STATUS=$(nemoclaw list 2>/dev/null | grep -E "deep" | head -1 || echo "")
if [ -n "${NEMOCLAW_STATUS}" ]; then
    printf "  ✅ %-22s %s\n" "NemoClaw (deep):" "${NEMOCLAW_STATUS}"
    printf "     UI: openshell forward 18789 deep && open http://localhost:18789\n"
else
    printf "  ❌ %-22s sandbox not found — run scripts/07_nemoclaw.sh\n" "NemoClaw (deep):"
fi
echo ""

# ── pgvector memory stats ─────────────────────────────────────────────────────
echo "── Memory DB (pgvector) ─────────────────────────────────────"
if docker inspect pgvector &>/dev/null 2>&1 && \
   [ "$(docker inspect -f '{{.State.Status}}' pgvector)" = "running" ]; then
    docker exec pgvector psql -U postgres -d "${POSTGRES_DB}" -t -q 2>/dev/null << 'SQL'
SELECT '  Lessons total:          ' || COUNT(*) FROM lessons;
SELECT '  Lessons (success):      ' || COUNT(*) FROM lessons WHERE outcome='success';
SELECT '  Web cache entries:      ' || COUNT(*) FROM rag_cache;
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
else
    echo "  No log file yet (written on first agent call)"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
