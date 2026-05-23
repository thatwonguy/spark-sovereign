#!/usr/bin/env bash
# =============================================================================
# spark-sovereign watchdog — idempotent steady-state health check.
# Triggered every 2 min by spark-watchdog.timer.
#
# Rules:
#   - Healthy services are not touched.
#   - Unhealthy services get ONE recovery attempt per tick.
#   - After MAX_FAILS consecutive failed recoveries, service is quarantined
#     (watchdog stops trying until it recovers on its own or admin clears).
#   - One tick = one pass over all services, then exit.
# =============================================================================

set -uo pipefail   # NOTE: no -e — one service's failure must not skip others.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

STATE_DIR="${STATE_DIR:-/var/lib/spark-sovereign/state}"
MAX_FAILS="${WATCHDOG_MAX_FAILS:-3}"
BRAIN_PORT="${BRAIN_PORT:-8000}"
BRAIN_LOAD_GRACE_SECONDS="${BRAIN_LOAD_GRACE_SECONDS:-600}"  # 10 min

mkdir -p "${STATE_DIR}" 2>/dev/null || true

log() { echo "[watchdog] $*"; }

# Per-tick status summary — one heartbeat line at the end.
TICK_STATUS=""
record_status() { TICK_STATUS+="$1=$2 "; }

# ── State helpers ────────────────────────────────────────────────────────────
get_fails()      { local f="${STATE_DIR}/$1.fails"; [ -f "${f}" ] && cat "${f}" || echo 0; }
set_fails()      { echo "$2" > "${STATE_DIR}/$1.fails"; }
is_quarantined() { [ -f "${STATE_DIR}/$1.quarantined" ]; }
quarantine()     { touch "${STATE_DIR}/$1.quarantined"; log "QUARANTINED $1 — manual clear: sudo rm ${STATE_DIR}/$1.quarantined"; }
mark_healthy()   { set_fails "$1" 0; rm -f "${STATE_DIR}/$1.quarantined" 2>/dev/null; }

# ── Docker helpers ───────────────────────────────────────────────────────────
container_exists()   { docker inspect "$1" >/dev/null 2>&1; }
container_running()  { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
container_age_secs() {
    local started; started=$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null) || { echo 0; return; }
    local epoch;   epoch=$(date -d "${started}" +%s 2>/dev/null) || { echo 0; return; }
    echo $(( $(date +%s) - epoch ))
}

# ── Recovery dispatch ────────────────────────────────────────────────────────
attempt_recovery() {
    local svc="$1" action="$2"
    if is_quarantined "${svc}"; then
        log "${svc} is quarantined — skipping (admin must clear)"
        return
    fi
    local n; n=$(get_fails "${svc}")
    n=$((n + 1))
    set_fails "${svc}" "${n}"
    log "${svc} unhealthy — recovery attempt ${n}/${MAX_FAILS}"
    eval "${action}" 2>&1 | sed "s|^|[watchdog:${svc}] |" || log "${svc} recovery command exited non-zero"
    if [ "${n}" -ge "${MAX_FAILS}" ]; then
        quarantine "${svc}"
        record_status "${svc}" "quarantined"
    else
        record_status "${svc}" "recovering(${n}/${MAX_FAILS})"
    fi
}

# ── Service checks ───────────────────────────────────────────────────────────
check_container() {
    # check_container <name> <restart-cmd>
    # Skips if container doesn't exist at all (nothing to restart).
    local name="$1" action="$2"
    if ! container_exists "${name}"; then
        record_status "${name}" "absent"
        return
    fi
    if container_running "${name}"; then
        mark_healthy "${name}"
        record_status "${name}" "up"
        return
    fi
    attempt_recovery "${name}" "${action}"
}

check_brain() {
    # Brain takes minutes to load. Tolerate "container up but port silent"
    # for BRAIN_LOAD_GRACE_SECONDS after container start.
    if ! container_exists brain; then
        attempt_recovery brain "bash '${REPO_ROOT}/scripts/start_brain_ad_hoc.sh'"
        return
    fi
    if ! container_running brain; then
        attempt_recovery brain "bash '${REPO_ROOT}/scripts/start_brain_ad_hoc.sh'"
        return
    fi
    local age; age=$(container_age_secs brain)
    if curl -sf --max-time 5 "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; then
        mark_healthy brain
        record_status brain "up"
        return
    fi
    if [ "${age}" -lt "${BRAIN_LOAD_GRACE_SECONDS}" ]; then
        log "brain still in load window (${age}s/${BRAIN_LOAD_GRACE_SECONDS}s) — not touching"
        record_status brain "loading(${age}s)"
        return
    fi
    attempt_recovery brain "bash '${REPO_ROOT}/scripts/start_brain_ad_hoc.sh'"
}

check_openclaw() {
    if ! command -v openclaw >/dev/null 2>&1; then
        record_status openclaw "absent"
        return
    fi
    if openclaw gateway status 2>/dev/null | grep -qi "running"; then
        mark_healthy openclaw
        record_status openclaw "up"
        return
    fi
    attempt_recovery openclaw "openclaw gateway start"
}

# ── Tick ─────────────────────────────────────────────────────────────────────
check_container searxng    "docker start searxng"
check_brain
check_container asr-server "docker start asr-server"
check_container tts-server "docker start tts-server"
check_openclaw

log "tick ${TICK_STATUS}"
exit 0
