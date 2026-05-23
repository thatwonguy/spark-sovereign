#!/usr/bin/env bash
# Sequenced boot — CPU services first, then Brain, then voice.
# Tolerates failures: if any single step fails, continue with the rest.
# Steady-state health is owned by spark-watchdog.timer (every 2 min).

set -uo pipefail   # NOTE: no -e — one failure must not abort the chain.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[spark-boot] $*"; }

log "Starting CPU-only services..."
for name in searxng; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting Brain..."
if ! bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh"; then
    log "  Brain start failed — watchdog will retry"
fi

# Bounded wait — up to 12 min for Brain to answer on port 8000.
# If it doesn't, continue: voice + OpenClaw still come up, watchdog takes over.
log "Waiting for Brain to be ready (port 8000, up to 12 min)..."
DEADLINE=$(( $(date +%s) + 720 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if curl -sf --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
        log "Brain ready."
        break
    fi
    if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
        log "  brain container not running — leaving recovery to watchdog"
        break
    fi
    sleep 10
done
if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    log "  Brain not ready within 12 min — leaving recovery to watchdog"
fi

log "Starting voice services..."
for name in asr-server tts-server; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting OpenClaw gateway..."
openclaw gateway start 2>/dev/null || log "  openclaw gateway start failed — watchdog will retry"

log "Boot sequence complete — watchdog owns steady-state health."
exit 0
