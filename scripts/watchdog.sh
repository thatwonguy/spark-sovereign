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
# 20 min. Was 10, which the Flash-Next mmap build exceeds: it measured ~14 min
# from engine init to startup complete (16:14:02 -> 16:28:18), so a recovery
# would have killed it mid-load and restarted into the same wall until
# MAX_FAILS quarantined it. The 27B loads in well under this either way.
BRAIN_LOAD_GRACE_SECONDS="${BRAIN_LOAD_GRACE_SECONDS:-1200}"

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
    # Header is sent unconditionally: vLLM ignores it when --api-key is unset.
    # Without it, a keyed Brain answers 401 and the watchdog would restart a
    # perfectly healthy container every cycle.
    if curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY:-}" \
            "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; then
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

# ── Tick ─────────────────────────────────────────────────────────────────────
# spark-sovereign owns the Docker containers below. Agent frameworks
# (OpenClaw, LibreChat, n8n, etc.) own their own lifecycle — typically via a
# systemd user unit with `Restart=on-failure`, or Docker's own restart
# policies if they ship as containers.
#
# To monitor an additional containerized service, add a line below:
#     check_container <name> "docker start <name>"
check_container searxng    "docker start searxng"
check_brain
check_container asr-server "docker start asr-server"
check_container tts-server "docker start tts-server"

log "tick ${TICK_STATUS}"
exit 0
