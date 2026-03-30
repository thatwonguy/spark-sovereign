#!/usr/bin/env bash
#
# Stop Nemotron speech servers
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PID_DIR="${PROJECT_ROOT}/.pids"

if [ -f "${PID_DIR}/asr.pid" ]; then
    echo "Stopping ASR server (PID: $(cat ${PID_DIR}/asr.pid))..."
    kill "$(cat ${PID_DIR}/asr.pid)" 2>/dev/null || true
    rm -f "${PID_DIR}/asr.pid"
fi

if [ -f "${PID_DIR}/tts.pid" ]; then
    echo "Stopping TTS server (PID: $(cat ${PID_DIR}/tts.pid))..."
    kill "$(cat ${PID_DIR}/tts.pid)" 2>/dev/null || true
    rm -f "${PID_DIR}/tts.pid"
fi

echo "Speech servers stopped."
