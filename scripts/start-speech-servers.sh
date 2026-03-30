#!/usr/bin/env bash
#
# Start Nemotron speech servers (ASR + TTS)
# Run on boot or manually to enable voice transcription and synthesis
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
PID_DIR="${PROJECT_ROOT}/.pids"

# Create directories
mkdir -p "$LOG_DIR" "$PID_DIR"

export PYTHONPATH="${PROJECT_ROOT}/src:${PYTHONPATH}"

cd "$PROJECT_ROOT"

# Kill any existing servers
if [ -f "${PID_DIR}/asr.pid" ]; then
    kill "$(cat ${PID_DIR}/asr.pid)" 2>/dev/null || true
    rm -f "${PID_DIR}/asr.pid"
fi

if [ -f "${PID_DIR}/tts.pid" ]; then
    kill "$(cat ${PID_DIR}/tts.pid)" 2>/dev/null || true
    rm -f "${PID_DIR}/tts.pid"
fi

echo "Starting ASR server on port 8002..."
nohup python3 -m nemotron_speech.server \
    --host 0.0.0.0 \
    --port 8002 \
    --model nvidia/nemotron-speech-streaming-en-0.6b \
    > "${LOG_DIR}/asr.log" 2>&1 &
echo $! > "${PID_DIR}/asr.pid"
echo "ASR server PID: $(cat ${PID_DIR}/asr.pid)"

echo "Starting TTS server on port 8003..."
nohup python3 -m nemotron_speech.tts_server \
    --host 0.0.0.0 \
    --port 8003 \
    --model nvidia/magpie_tts_multilingual_357m \
    > "${LOG_DIR}/tts.log" 2>&1 &
echo $! > "${PID_DIR}/tts.pid"
echo "TTS server PID: $(cat ${PID_DIR}/tts.pid)"

echo "Speech servers started successfully!"
echo "  - ASR: ws://localhost:8002"
echo "  - TTS: http://localhost:8003/v1/audio/speech"
