#!/bin/bash
# ~/spark-sovereign/scripts/04_voice_servers.sh
# Local STT setup for OpenClaw voice support
# Per OpenClaw docs: STT uses CLI-based transcription (whisper CLI)
# TTS uses provider-based (ElevenLabs, Microsoft, OpenAI) - no custom endpoints

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== OpenClaw Voice Setup (STT) ===${NC}"
echo ""
echo "Per OpenClaw docs:"
echo "- STT: CLI-based (whisper CLI) or provider-based (OpenAI, Deepgram)"
echo "- TTS: Provider-based (ElevenLabs, Microsoft, OpenAI)"
echo "- Talk Mode: Uses ElevenLabs streaming API"
echo ""

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

# Set up environment variable for model path
echo ""
echo -e "${BLUE}=== Configuration ===${NC}"
echo ""
echo "Add this to your ~/.bashrc or ~/.zshrc:"
echo "  export WHISPER_MODEL_PATH=\"$MODELS_DIR/whisper/pytorch_model.bin\""
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
        "models": [
          {
            "type": "cli",
            "command": "whisper",
            "args": ["--model", "small", "--device", "cuda", "{{MediaPath}}"],
            "timeoutSeconds": 45
          }
        ],
        "echoTranscript": true
      }
    }
  },
  "messages": {
    "tts": {
      "auto": "inbound",
      "providers": {
        "elevenlabs": {
          "enabled": true,
          "apiKey": "${ELEVENLABS_API_KEY}",
          "voiceId": "21m00Tcm4TlvDq8ikWAM",
          "modelId": "eleven_multilingual_v2"
        },
        "microsoft": {
          "enabled": false
        },
        "openai": {
          "enabled": false
        }
      }
    }
  },
  "talk": {
    "enabled": true,
    "silenceTimeoutMs": 1500,
    "interruptOnSpeech": true,
    "apiKey": "${ELEVENLABS_API_KEY}",
    "voiceId": "21m00Tcm4TlvDq8ikWAM",
    "modelId": "eleven_v3"
  }
}
EOF

echo ""
echo -e "${BLUE}=== Notes ===${NC}"
echo ""
echo "1. STT (Speech-to-Text):"
echo "   - Uses whisper CLI (local, GPU-accelerated)"
echo "   - Model: $WHISPER_MODEL (~96% accuracy)"
echo "   - Command: whisper --model small --device cuda <audio_file>"
echo ""
echo "2. TTS (Text-to-Speech):"
echo "   - Uses ElevenLabs API (cloud, high quality)"
echo "   - Alternative: Microsoft Azure TTS (requires Azure subscription)"
echo "   - OpenClaw does NOT support custom TTS endpoints"
echo ""
echo "3. Talk Mode:"
echo "   - Continuous voice conversation (macOS/Android/iOS)"
echo "   - Requires ElevenLabs API key"
echo "   - Uses streaming TTS for low latency"
echo ""
echo "4. Privacy-first alternative:"
echo "   - If you need 100% local TTS, use Piper CLI manually"
echo "   - But OpenClaw's TTS integration only supports providers"
echo "   - You'd need to modify OpenClaw source to add custom TTS"
echo ""
echo -e "${BLUE}=== Test ===${NC}"
echo ""
echo "Test Whisper CLI:"
echo "  whisper --model $WHISPER_MODEL --device cuda <audio_file.mp3>"
echo ""
echo "Test OpenClaw voice:"
echo "  1. Add config to ~/.openclaw/openclaw.json"
echo "  2. Set ELEVENLABS_API_KEY env var (for TTS)"
echo "  3. Restart: openclaw gateway restart"
echo "  4. Test: /tts status"
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
