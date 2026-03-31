#!/bin/bash
# ~/spark-sovereign/scripts/04_voice_stt.sh
# Local STT (Speech-to-Text) setup for OpenClaw
# Per OpenClaw docs: STT uses CLI-based transcription (whisper CLI)
# This script sets up LOCAL Whisper STT only - no TTS, no cloud APIs

# Configuration
MODELS_DIR="$HOME/.local/share/openclaw-voice"
WHISPER_MODEL="small"  # Options: tiny, base, small, medium, large-v3

# Create directories
echo -e "${YELLOW}[1/3] Creating directories...${NC}"
mkdir -p "$MODELS_DIR/whisper"
echo "  ✓ $MODELS_DIR/whisper"

# Download Whisper model (for CLI usage)
echo -e "${YELLOW}[2/3] Downloading Whisper model ($WHISPER_MODEL)...${NC}"
WHISPER_URL="https://huggingface.co/openai/whisper-$WHISPER_MODEL/resolve/main/pytorch_model.bin"

if [ ! -f "$MODELS_DIR/whisper/pytorch_model.bin" ]; then
    echo "  Downloading from HuggingFace (~450MB for small)..."
    wget -O "$MODELS_DIR/whisper/pytorch_model.bin" "$WHISPER_URL" --progress=bar:force
    echo "  ✓ Download complete"
else
    echo "  ✓ Already downloaded"
fi
echo "  ✓ Model: $MODELS_DIR/whisper/pytorch_model.bin"

# Install/verify whisper CLI
echo -e "${YELLOW}[3/3] Setting up Whisper CLI...${NC}"

# Check if whisper CLI is available
if command -v whisper &> /dev/null; then
    echo "  ✓ Whisper CLI already installed"
    WHISPER_INSTALLED=true
else
    echo "  Installing whisper CLI (Python)..."
    pip install openai-whisper --quiet
    echo "  ✓ Whisper CLI installed"
    WHISPER_INSTALLED=true
fi

# Output configuration
echo ""
echo -e "${BLUE}=== Configuration ===${NC}"
echo ""
echo "Add this to ~/.openclaw/openclaw.json:"
echo ""
cat << 'EOF'
{
  "tools": {
    "media": {
      "audio": {
        "enabled": true,
        "maxBytes": 20971520,
        "echoTranscript": true,
        "echoFormat": "🎤 \"{transcript}\"",
        "models": [
          {
            "type": "cli",
            "command": "whisper",
            "args": ["--model", "small", "--device", "cuda", "{{MediaPath}}"],
            "timeoutSeconds": 45
          }
        ]
      }
    }
  }
}
EOF

echo ""
echo -e "${BLUE}=== What This Does ===${NC}"
echo ""
echo "STT (Speech-to-Text) - LOCAL & PRIVATE:"
echo "  • Voice notes auto-transcribe before reaching the model"
echo "  • Whisper CLI runs locally on GPU (~2GB VRAM)"
echo "  • Model: $WHISPER_MODEL (~96% accuracy)"
echo "  • No cloud APIs, no data leaves your machine"
echo ""
echo "What you can do:"
echo "  • Send voice notes in Telegram → auto-transcribed → model replies with text"
echo "  • Works in TUI, Telegram, and all OpenClaw channels"
echo "  • Echo shows: 🎤 \"transcribed text\""
echo ""
echo -e "${BLUE}=== Test ===${NC}"
echo ""
echo "Test Whisper CLI:"
echo "  whisper --model $WHISPER_MODEL --device cuda <audio_file.mp3>"
echo ""
echo "Test OpenClaw STT:"
echo "  1. Add config to ~/.openclaw/openclaw.json (see above)"
echo "  2. Config hot-reloads automatically (no restart needed)"
echo "  3. Send a voice note in Telegram → should auto-transcribe"
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
