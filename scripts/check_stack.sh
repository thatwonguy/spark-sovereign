#!/usr/bin/env bash
# =============================================================================
# Full Stack Observability — spark-sovereign
# Shows every Docker container, every GPU process, memory, and service status.
# Prompts to kill any unexpected containers or GPU processes on the spot.
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

ask_kill() {
    local prompt="$1"
    local cmd="$2"
    read -rp "  Kill? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        eval "${cmd}" && echo "  Done." || echo "  Failed — try: sudo ${cmd}"
    else
        echo "  Skipped."
    fi
}

BRAIN_PORT=$(get_field brain.port)
BRAIN_NAME=$(get_field brain.served_name)
OPENCLAW_PORT=$(get_field infrastructure.nemoclaw.ui_port)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        spark-sovereign — Full Stack Observability        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── System memory ─────────────────────────────────────────────────────────────
echo "── System Memory ───────────────────────────────────────────"
free -h | grep -E "Mem|Swap"
echo ""

# ── GPU — all processes consuming VRAM ────────────────────────────────────────
echo "── GPU / VRAM ──────────────────────────────────────────────"
nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{
        gsub(/ /,"",$2); gsub(/ /,"",$3);
        printf "  %-28s  Util: %s%%   Temp: %s°C\n",$1,$2,$3
    }'
echo ""
echo "  All processes consuming VRAM:"

GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_gpu_memory,name \
    --format=csv,noheader,nounits 2>/dev/null || true)

if [ -z "${GPU_PROCS}" ]; then
    echo "    (none)"
else
    echo "${GPU_PROCS}" | while IFS=',' read -r pid mib pname; do
        pid="${pid// /}"; mib="${mib// /}"; pname="${pname## }"
        gb=$(python3 -c "print(f'{${mib}/1024:.1f}')" 2>/dev/null || echo "?")
        proc=$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")
        printf "    PID %-8s  %-24s  %s GiB  (%s)\n" "${pid}" "${pname}" "${gb}" "${proc}"
        # Prompt to kill anything that isn't the expected vLLM brain process
        if ! echo "${proc}" | grep -qiE "python|vllm"; then
            echo "  ⚠️  Unexpected GPU process: PID ${pid} (${proc}) using ${gb} GiB"
            ask_kill "kill PID ${pid}" "sudo kill -9 ${pid}"
        fi
    done
fi
echo ""

# ── ALL Docker containers (running + stopped) ─────────────────────────────────
echo "── Docker Containers (all) ─────────────────────────────────"
ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}|{{.Status}}|{{.Image}}|{{.RunningFor}}" 2>/dev/null)
if [ -z "${ALL_CONTAINERS}" ]; then
    echo "  (no containers found)"
else
    printf "  %-22s %-14s %-38s %s\n" "NAME" "STATUS" "IMAGE" "RUNNING FOR"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "${ALL_CONTAINERS}" | while IFS='|' read -r name status image uptime; do
        if echo "${status}" | grep -q "^Up"; then
            icon="✅"
        else
            icon="❌"
        fi
        printf "  ${icon} %-20s %-14s %-38s %s\n" \
            "${name}" "${status:0:13}" "${image:0:37}" "${uptime}"
    done
fi
echo ""

# ── Unexpected running containers ─────────────────────────────────────────────
echo "── Unexpected Running Containers ───────────────────────────"
STALE=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -v -E "^brain$" || true)
if [ -z "${STALE}" ]; then
    echo "  ✅ None — only Brain is running"
else
    echo "  ⚠️  These containers are running but not part of the current stack:"
    echo "${STALE}" | while read -r name; do
        image=$(docker inspect -f '{{.Config.Image}}' "${name}" 2>/dev/null || echo "unknown")
        printf "\n  - %-22s (%s)\n" "${name}" "${image}"
        ask_kill "stop + remove ${name}" "docker stop ${name} && docker rm ${name}"
    done
fi
echo ""

# ── Expected services ─────────────────────────────────────────────────────────
echo "── Expected Services ───────────────────────────────────────"
BRAIN_RESULT=$(curl -sf --max-time 5 "http://localhost:${BRAIN_PORT}/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
    2>/dev/null || echo "")
if [ -n "${BRAIN_RESULT}" ]; then
    printf "  ✅ Brain  (port %-5s)  model: %s\n" "${BRAIN_PORT}" "${BRAIN_RESULT}"
else
    printf "  ❌ Brain  (port %-5s)  not responding — check: docker logs brain --tail 50\n" "${BRAIN_PORT}"
fi

OC_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")
if [ "${OC_CODE}" = "200" ]; then
    printf "  ✅ OpenClaw (port %-5s)  http://localhost:%s\n" "${OPENCLAW_PORT}" "${OPENCLAW_PORT}"
else
    printf "  ❌ OpenClaw (port %-5s)  not responding — run: openclaw gateway start\n" "${OPENCLAW_PORT}"
fi
echo ""

# ── Auto-start service ────────────────────────────────────────────────────────
echo "── Auto-Start Service ──────────────────────────────────────"
SVC_STATUS=$(systemctl is-active spark-sovereign 2>/dev/null || echo "unknown")
SVC_ENABLED=$(systemctl is-enabled spark-sovereign 2>/dev/null || echo "unknown")
if [ "${SVC_STATUS}" = "active" ]; then
    printf "  ✅ spark-sovereign.service: %s (enabled: %s)\n" "${SVC_STATUS}" "${SVC_ENABLED}"
else
    printf "  ❌ spark-sovereign.service: %s (enabled: %s)\n" "${SVC_STATUS}" "${SVC_ENABLED}"
    echo "     Fix: bash scripts/01_system_prep.sh"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
