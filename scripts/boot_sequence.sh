#!/usr/bin/env bash
# Sequenced boot — CPU services first, then Brain, then voice.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[spark-boot] $*"; }

log "Starting CPU-only services..."
for name in searxng; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting Brain..."
bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh"

log "Waiting for Brain to be ready (port 8000)..."
until curl -sf http://localhost:8000/v1/models >/dev/null 2>&1; do
    if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
        log "ERROR: brain container exited. Check: docker logs brain"
        exit 1
    fi
    sleep 5
done
log "Brain ready."

log "Starting voice services..."
for name in asr-server tts-server; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting OpenClaw gateway..."
openclaw gateway start 2>/dev/null || true

log "Stack is up."
