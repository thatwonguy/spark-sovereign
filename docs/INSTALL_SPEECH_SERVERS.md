# Speech Servers Setup Guide

This guide covers installation and setup of the NVIDIA Nemotron speech servers for ASR (automatic speech recognition) and TTS (text-to-speech).

## Prerequisites

- NVIDIA GPU with CUDA support
- Python 3.10+
- Required packages (already installed):
  - `nemo_toolkit[asr]` for ASR server
  - `loguru`, `websockets`, `aiohttp` for server framework
  - `ffmpeg` for audio conversion

## Quick Start

### 1. Start servers manually

```bash
# From spark-sovereign directory
./scripts/start-speech-servers.sh
```

### 2. Stop servers

```bash
./scripts/stop-speech-servers.sh
```

### 3. Verify running

```bash
# Check ASR server
curl http://localhost:8002/health

# Check TTS server
curl http://localhost:8003/health
```

## Systemd Service (Recommended)

For persistence across reboots, install the systemd service:

### 1. Copy service file

```bash
sudo cp systemd/nemotron-speech.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### 2. Enable and start

```bash
sudo systemctl enable nemotron-speech
sudo systemctl start nemotron-speech
```

### 3. Check status

```bash
sudo systemctl status nemotron-speech
journalctl -u nemotron-speech -f
```

### 4. Logs location

- Main log: `/home/thatwonguy/spark-sovereign/logs/nemotron.log`
- ASR log: `/home/thatwonguy/spark-sovereign/logs/asr.log`
- TTS log: `/home/thatwonguy/spark-sovereign/logs/tts.log`

## API Endpoints

### ASR (Speech-to-Text)

- **WebSocket**: `ws://localhost:8002`
- **Health**: `http://localhost:8002/health`
- **Protocol**: Sends audio chunks (WAV, 16kHz mono), receives JSON transcript messages

### TTS (Text-to-Speech)

- **HTTP POST**: `http://localhost:8003/v1/audio/speech`
- **Health**: `http://localhost:8003/health`
- **Request**: `{"model": "magpie-tts", "input": "text", "voice": "john"}`
- **Response**: Audio bytes (OGG/Vorbis)
- **Available voices**: john, sofia, aria, jason, leo

## Troubleshooting

### Server won't start

1. Check dependencies:
   ```bash
   python3 -c "import nemo_toolkit; print('OK')"
   python3 -c "import loguru; print('OK')"
   ```

2. Check port availability:
   ```bash
   ss -tlnp | grep -E '800[23]'
   ```

3. Check logs:
   ```bash
   tail -100 logs/asr.log
   tail -100 logs/tts.log
   ```

### CUDA/GPU errors

- Ensure NVIDIA drivers are installed: `nvidia-smi`
- Check GPU memory: `free -h` (need ~2GB for Nemotron 0.6B)

### Connection refused

- Verify server is running: `ps aux | grep nemotron`
- Check firewall: `sudo ufw status` (allow ports 8002, 8003 if needed)
