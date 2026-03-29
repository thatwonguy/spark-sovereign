#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (ASR port 8002, TTS port 8003)
# =============================================================================
# Uses NVIDIA's pipecat-ai Nemotron voice stack.
# ASR: nemotron-speech-streaming-en-0.6b (March 12 2026 checkpoint)
# TTS: magpie_tts_multilingual_357m (7 languages, 5 voices)
# Both model paths sourced from config/models.yml.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('$1', {}).get('$2', ''))
"
}

ASR_PATH=$(get_field asr local_path)
TTS_PATH=$(get_field tts local_path)
ASR_PORT=$(get_field asr port)
TTS_PORT=$(get_field tts port)

echo "========================================================"
echo " spark-sovereign — Phase 4: Voice Pipeline"
echo "========================================================"
echo "  ASR model: ${ASR_PATH} → ws://localhost:${ASR_PORT}"
echo "  TTS model: ${TTS_PATH} → ws://localhost:${TTS_PORT}"
echo ""

# Clone pipecat if not already present
PIPECAT_DIR="${PIPECAT_DIR:-$HOME/nemotron-voice}"
if [ ! -d "${PIPECAT_DIR}" ]; then
    echo ">>> Cloning pipecat voice pipeline..."
    git clone https://github.com/pipecat-ai/nemotron-january-2026 "${PIPECAT_DIR}"
fi

cd "${PIPECAT_DIR}"

# Build unified container (first time: 2-3 hours)
if ! docker image inspect nemotron-voice:cuda13 &>/dev/null; then
    echo ">>> Building nemotron-voice:cuda13 (first time: ~2-3 hours)..."
    docker build -f Dockerfile.unified -t nemotron-voice:cuda13 .
    echo "    Build complete."
else
    echo "    Image nemotron-voice:cuda13 already exists — skipping build."
fi

# Preflight: make sure ports are free before using host networking
for port in "${ASR_PORT}" "${TTS_PORT}"; do
    if ss -ltn "( sport = :${port} )" | tail -n +2 | grep -q .; then
        echo "ERROR: port ${port} is already in use on the host"
        echo "Run: ss -ltnp | grep :${port}"
        exit 1
    fi
done

# Start voice pipeline container
echo ""
echo ">>> Starting voice-pipeline container..."
docker rm -f voice-pipeline 2>/dev/null || true

docker run -d --name voice-pipeline \
    --gpus all --ipc host --network host \
    --restart unless-stopped \
    -v "${MODELS_DIR}:/models" \
    -e ASR_MODEL_PATH="/models/$(basename "${ASR_PATH}")" \
    -e TTS_MODEL_PATH="/models/$(basename "${TTS_PATH}")" \
    -e ASR_PORT="${ASR_PORT}" \
    -e TTS_PORT="${TTS_PORT}" \
    nemotron-voice:cuda13 \
    ./scripts/nemotron.sh start \
        --no-llm \
        --mode vllm

echo "    voice-pipeline started."
echo "    ASR WebSocket: ws://localhost:${ASR_PORT}"
echo "    TTS WebSocket: ws://localhost:${TTS_PORT}"
echo ""
echo "Phase 4 complete. Proceed to: scripts/05_pgvector.sh"
