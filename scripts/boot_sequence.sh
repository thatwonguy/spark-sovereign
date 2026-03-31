#!/usr/bin/env bash
# =============================================================================
# Auto-start boot sequence — installed as spark-sovereign.service by
# scripts/01_system_prep.sh. Runs automatically on every boot after Docker.
#
# Sequence: Start Brain → wait until port 8000 ready → done.
# OpenClaw reconnects to Brain automatically once the endpoint is up.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[spark-boot] $*"; }

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

log "Brain ready. Stack is up."
