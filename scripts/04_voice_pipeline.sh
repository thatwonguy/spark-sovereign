#!/usr/bin/env bash
# =============================================================================
# PHASE 4 — Voice Pipeline (ASR port 8002, TTS port 8003)
# =============================================================================
# Runs TWO separate containers from the same nemotron-voice:cuda13 image:
#
#   asr-server  — nemotron_speech.server     (aiohttp WebSocket)
#   tts-server  — nemotron_speech.tts_server (FastAPI HTTP + WebSocket)
#
# There is no nemotron.sh inside the image. The entry points are the two
# Python modules above. Models are loaded from HuggingFace on first run
# and cached to ~/.cache/huggingface (mounted into both containers).
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
mkdir -p "${HF_CACHE}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('$1', {}).get('$2', ''))
"
}

ASR_HF=$(get_field asr hf_repo)
TTS_HF=$(get_field tts hf_repo)
ASR_PORT=$(get_field asr port)
TTS_PORT=$(get_field tts port)

echo "========================================================"
echo " spark-sovereign — Phase 4: Voice Pipeline"
echo "========================================================"
echo "  ASR: ${ASR_HF} → ws://localhost:${ASR_PORT}"
echo "  TTS: ${TTS_HF} → http://localhost:${TTS_PORT}"
echo "  HF cache: ${HF_CACHE}"
echo ""

# ── Build image (first time only) ─────────────────────────────────────────────
PIPECAT_DIR="${PIPECAT_DIR:-$HOME/nemotron-voice}"
if ! docker image inspect nemotron-voice:cuda13 &>/dev/null; then
    if [ ! -d "${PIPECAT_DIR}" ]; then
        echo ">>> Cloning pipecat voice pipeline..."
        git clone https://github.com/pipecat-ai/nemotron-january-2026 "${PIPECAT_DIR}"
    fi
    cd "${PIPECAT_DIR}"
    echo ">>> Building nemotron-voice:cuda13 (first time: ~2-3 hours)..."
    docker build -f Dockerfile.unified -t nemotron-voice:cuda13 .
    echo "    Build complete."
else
    echo "    Image nemotron-voice:cuda13 already exists — skipping build."
fi

# ── Stop existing containers first (frees ports before preflight check) ───────
echo ""
echo ">>> Stopping existing voice containers (if any)..."
docker rm -f asr-server  2>/dev/null || true
docker rm -f tts-server  2>/dev/null || true
docker rm -f voice-pipeline 2>/dev/null || true   # legacy name

# ── Preflight: ports must be free from other processes ────────────────────────
for port in "${ASR_PORT}" "${TTS_PORT}"; do
    if ss -ltn "( sport = :${port} )" | tail -n +2 | grep -q .; then
        echo "ERROR: port ${port} is still in use by another process"
        echo "Run: ss -ltnp | grep :${port}"
        exit 1
    fi
done

# ── Common docker flags ────────────────────────────────────────────────────────
COMMON_FLAGS=(
    --gpus all
    --ipc host
    --network host
    --restart no
    -v "${MODELS_DIR}:/models"
    -v "${HF_CACHE}:/root/.cache/huggingface"
    -e HF_TOKEN="${HF_TOKEN:-}"
    -e HUGGING_FACE_HUB_TOKEN="${HF_TOKEN:-}"
)

# ── Start ASR server ───────────────────────────────────────────────────────────
echo ""
echo ">>> Starting ASR server (port ${ASR_PORT})..."
docker run -d --name asr-server \
    "${COMMON_FLAGS[@]}" \
    nemotron-voice:cuda13 \
    python -m nemotron_speech.server \
        --host 0.0.0.0 \
        --port "${ASR_PORT}" \
        --model "${ASR_HF}"

echo "    asr-server started"
echo "    WebSocket:    ws://localhost:${ASR_PORT}"
echo "    Health check: http://localhost:${ASR_PORT}/health"

# ── Start TTS server ───────────────────────────────────────────────────────────
echo ""
echo ">>> Starting TTS server (port ${TTS_PORT})..."
docker run -d --name tts-server \
    "${COMMON_FLAGS[@]}" \
    nemotron-voice:cuda13 \
    python -m nemotron_speech.tts_server \
        --host 0.0.0.0 \
        --port "${TTS_PORT}" \
        --model "${TTS_HF}"

echo "    tts-server started"
echo "    HTTP:         http://localhost:${TTS_PORT}/v1/audio/speech"
echo "    WebSocket:    ws://localhost:${TTS_PORT}/ws/tts/stream"
echo "    Health check: http://localhost:${TTS_PORT}/health"

# ── Wait for models to load ────────────────────────────────────────────────────
echo ""
echo "Waiting for models to load (first run downloads from HuggingFace — may take a while)..."
echo "Watch logs: docker logs -f asr-server | docker logs -f tts-server"
echo ""

until curl -sf "http://localhost:${ASR_PORT}/health" >/dev/null 2>&1 && \
      curl -sf "http://localhost:${TTS_PORT}/health" >/dev/null 2>&1; do
    if ! docker ps -q --filter "name=^asr-server$" --filter "status=running" | grep -q .; then
        echo "ERROR: asr-server container exited. Check: docker logs asr-server"
        exit 1
    fi
    if ! docker ps -q --filter "name=^tts-server$" --filter "status=running" | grep -q .; then
        echo "ERROR: tts-server container exited. Check: docker logs tts-server"
        exit 1
    fi
    sleep 5
done
echo ""
echo "Both voice servers loaded and ready."

echo ""
echo "Phase 4 complete. Proceed to: scripts/05_pgvector.sh"
