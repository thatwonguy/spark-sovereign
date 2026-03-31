#!/usr/bin/env bash
# =============================================================================
# Stack Health Check — spark-sovereign
# Run any time to verify Brain and OpenClaw are up.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
keys = '$1'.split('.')
node = cfg
for k in keys:
    node = node.get(k, {})
print(node if isinstance(node, (str, int)) else '')
" 2>/dev/null || echo ""
}

BRAIN_PORT=$(get_field brain.port)
BRAIN_NAME=$(get_field brain.served_name)
OPENCLAW_PORT=$(get_field infrastructure.nemoclaw.ui_port)

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

# ── Brain ─────────────────────────────────────────────────────────────────────
echo "── Brain ───────────────────────────────────────────────────"
BRAIN_RESULT=$(curl -sf --max-time 5 "http://localhost:${BRAIN_PORT}/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
    2>/dev/null || echo "")
if [ -n "${BRAIN_RESULT}" ]; then
    printf "  ✅ Brain (port %s): %s\n" "${BRAIN_PORT}" "${BRAIN_RESULT}"
else
    printf "  ❌ Brain (port %s): not responding\n" "${BRAIN_PORT}"
    echo "     Check: docker logs brain --tail 50"
fi
echo ""

# ── Brain container ───────────────────────────────────────────────────────────
echo "── Container ───────────────────────────────────────────────"
STATUS=$(docker inspect -f '{{.State.Status}}' brain 2>/dev/null || echo "not found")
UPTIME=$(docker inspect -f '{{.State.StartedAt}}' brain 2>/dev/null \
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
    except: print('')
" 2>/dev/null || echo "")
ICON="✅"; [ "${STATUS}" != "running" ] && ICON="❌"
printf "  ${ICON} brain: %s  %s\n" "${STATUS}" "${UPTIME}"
echo ""

# ── OpenClaw ──────────────────────────────────────────────────────────────────
echo "── OpenClaw ────────────────────────────────────────────────"
OC_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")
if [ "${OC_CODE}" = "200" ]; then
    printf "  ✅ OpenClaw gateway: http://localhost:%s\n" "${OPENCLAW_PORT}"
else
    printf "  ❌ OpenClaw gateway: not responding (HTTP %s)\n" "${OC_CODE}"
    echo "     Start: openclaw gateway start"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
