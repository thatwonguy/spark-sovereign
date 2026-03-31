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
print(node if isinstance(node, (str, int, float)) else '')
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
BRAIN_HF=$(get_field brain.hf_repo)
BRAIN_CTX=$(get_field brain.max_model_len)
BRAIN_UTIL=$(get_field brain.gpu_memory_utilization)
BRAIN_KV=$(get_field brain.kv_cache_dtype)
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
    UNEXPECTED_PIDS=()
    while IFS=',' read -r pid mib pname; do
        pid="${pid// /}"; mib="${mib// /}"; pname="${pname## }"
        gb=$(python3 -c "print(f'{int(\"${mib}\")/1024:.1f}')" 2>/dev/null || echo "?")
        proc=$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")
        printf "    PID %-8s  %-24s  %s GiB  (%s)\n" "${pid}" "${pname}" "${gb}" "${proc}"
        if ! echo "${proc}" | grep -qiE "python|vllm"; then
            UNEXPECTED_PIDS+=("${pid}:${proc}:${gb}")
        fi
    done <<< "${GPU_PROCS}"

    if [ "${#UNEXPECTED_PIDS[@]}" -gt 0 ]; then
        echo ""
        echo "  ⚠️  Unexpected processes consuming VRAM:"
        for entry in "${UNEXPECTED_PIDS[@]}"; do
            IFS=':' read -r pid proc gb <<< "${entry}"
            printf "    - PID %-8s  %-20s  %s GiB\n" "${pid}" "${proc}" "${gb}"
        done
        echo ""
        read -rp "  Kill all unexpected GPU processes? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            for entry in "${UNEXPECTED_PIDS[@]}"; do
                pid="${entry%%:*}"
                sudo kill -9 "${pid}" 2>/dev/null && echo "  Killed PID ${pid}" || echo "  Failed: PID ${pid}"
            done
        else
            echo "  Skipped."
        fi
    fi
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

    # Prompt to remove stopped containers (wasting disk)
    STOPPED=$(docker ps -a --filter "status=exited" --filter "status=created" \
        --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "${STOPPED}" ]; then
        echo ""
        echo "  ⚠️  Stopped containers on disk (wasting space, not needed):"
        echo "${STOPPED}" | while read -r name; do
            size=$(docker inspect --format='{{.SizeRw}}' "${name}" 2>/dev/null \
                | awk '{printf "%.0f MB", $1/1024/1024}' || echo "unknown size")
            printf "    - %-28s (%s)\n" "${name}" "${size}"
        done
        echo ""
        read -rp "  Remove all stopped containers? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            echo "${STOPPED}" | xargs docker rm 2>/dev/null && echo "  Removed." || echo "  Some removals failed."
        else
            echo "  Skipped."
        fi
    fi
fi
echo ""

# ── Unexpected running containers (wasting VRAM) ──────────────────────────────
echo "── Unexpected Running Containers ───────────────────────────"
STALE=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -v -E "^brain$" || true)
if [ -z "${STALE}" ]; then
    echo "  ✅ None — only Brain is running"
else
    echo "  ⚠️  Running but not part of the current stack (wasting VRAM):"
    echo "${STALE}" | while read -r name; do
        image=$(docker inspect -f '{{.Config.Image}}' "${name}" 2>/dev/null || echo "unknown")
        printf "    - %-28s (%s)\n" "${name}" "${image}"
    done
    echo ""
    read -rp "  Stop + remove all unexpected running containers? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        echo "${STALE}" | xargs -I{} sh -c 'docker stop {} && docker rm {}' \
            && echo "  Stopped and removed." || echo "  Some failed."
    else
        echo "  Skipped."
    fi
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

# ── Brain details + OpenClaw onboarding reference ─────────────────────────────
echo "── Brain Info (use these in OpenClaw wizard) ───────────────"
echo "  HF model        : ${BRAIN_HF}"
echo "  Served name     : ${BRAIN_NAME}"
echo "  Base URL        : http://localhost:${BRAIN_PORT}/v1"
echo "  Model ID        : ${BRAIN_NAME}"
echo "  API key         : unused  (any string works)"
echo "  Context window  : ${BRAIN_CTX}"
echo "  KV cache dtype  : ${BRAIN_KV}"
echo "  GPU mem util    : ${BRAIN_UTIL} (~$(python3 -c "print(round(121.69 * ${BRAIN_UTIL}))")GB reserved)"
echo ""

# ── Auto-start service ────────────────────────────────────────────────────────
echo "── Auto-Start Service ──────────────────────────────────────"
SVC_STATUS=$(systemctl is-active spark-sovereign 2>/dev/null) || SVC_STATUS="inactive"
SVC_ENABLED=$(systemctl is-enabled spark-sovereign 2>/dev/null) || SVC_ENABLED="unknown"
if [ "${SVC_ENABLED}" = "enabled" ]; then
    printf "  ✅ spark-sovereign.service: enabled (status: %s)\n" "${SVC_STATUS}"
    if [ "${SVC_STATUS}" = "inactive" ]; then
        echo "     Normal — oneshot service runs on boot. Brain was started manually this session."
    fi
else
    printf "  ❌ spark-sovereign.service: not enabled (status: %s)\n" "${SVC_STATUS}"
    echo "     Fix: bash scripts/01_system_prep.sh"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
