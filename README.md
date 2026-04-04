# spark-sovereign

Private local AI stack on **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip).

**Zero cloud. Zero API cost. Zero data leaving your hardware.**

- **Qwen3.5-35B-A3B-FP8** — 35B MoE (3B active), ~49 tok/s, 131K context, tool calls + reasoning
- **OpenClaw** handles everything else: voice, memory, RAG, web search, Telegram, MCP tools
- **One model. One endpoint. Fully self-contained.**

---

## How It Works

```
vLLM (Brain)  →  http://localhost:8000/v1
      ↑
OpenClaw  →  connects via onboard wizard, handles all agent capabilities
      ↑
You  →  OpenClaw TUI, Telegram, browser UI at http://localhost:18789
```

Brain runs as a Docker container, starts automatically on boot, and serves the model at port 8000. OpenClaw connects to it and provides everything on top — voice, memory, web search, Telegram, MCP tools, agent orchestration.

---

## What OpenClaw Provides (No Extra Setup)

| Capability | How |
|---|---|
| **Voice I/O** | Speak → transcribe → Brain responds → speaks back |
| **STT (Speech-to-Text)** | Local Whisper CLI (GPU-accelerated) or cloud providers (OpenAI, Deepgram) |
| **TTS (Text-to-Speech)** | Provider-based (ElevenLabs, Microsoft, OpenAI) — requires API key |
| **Talk Mode** | Continuous voice conversation (macOS/Android/iOS) with ElevenLabs streaming |
| **Image / video** | Send photo or video → Brain analyzes natively |
| **Memory** | Persistent across sessions — learns from every conversation |
| **Web search** | Live search, results fed to Brain |
| **Telegram** | Message your bot → Brain responds. Voice notes, images, text |
| **MCP tools** | Files, git, GitHub, browser, HTTP, shell, AWS, Stripe, Slack |
| **Agent orchestration** | Brain spawns parallel workers for long tasks |
| **TUI** | `openclaw tui` — interactive terminal chat |

See `config/mcp_servers.json` for the full MCP server catalog.

---

## Voice Setup (Optional)

**STT (Speech-to-Text) - Local & Private:**
- **Run:** `bash scripts/04_voice_stt.sh` to download whisper-small (~450MB, ~96% accuracy)
- **How it works:** Whisper CLI transcribes voice notes locally on GPU before sending to model
- **Config:** `tools.media.audio` in `~/.openclaw/openclaw.json`
- **Privacy:** 100% local, no cloud APIs, no data leaves your machine

**What you can do:**
- Send voice notes in Telegram → auto-transcribed → model responds with text
- Works in TUI, Telegram, and all OpenClaw channels
- GPU-accelerated (~2GB VRAM, ~7s for 8-second audio)

**Docs:**
- https://docs.openclaw.ai/nodes/audio

---

## Model

| Component | Model | Size | Port |
|---|---|---|---|
| **Brain** | Qwen/Qwen3.5-35B-A3B-FP8 | ~55 GB | 8000 |

**Why Qwen3.5-35B-A3B-FP8:**
- 35B MoE with only 3B active per token — fast and efficient
- ~49 tok/s on DGX Spark (vs ~14-30 for dense 27B, ~35-45 for Nemotron-3-Nano)
- Community-confirmed: surpasses Qwen3-235B-A22B benchmarks with only 3B active params
- More intelligent AND faster than both previous release models (27B dense, Nemotron-3-Nano)
- Standard vllm/vllm-openai:cu130-nightly image — no custom image needed
- 131K context window with FP8 KV cache
- Same `qwen3_coder` tool parser and `qwen3` reasoning parser as the 27B — same family
- ~55GB weights at 0.80 util → ~42GB KV cache headroom

---

## Memory Map

```
128GB DGX Spark Unified Memory (121.69 GiB visible to CUDA)
═══════════════════════════════════════════════════════════════
 Qwen3.5-35B-A3B FP8 (Brain)  ~97.4 GB    0.80 util (~55GB weights + ~42GB KV cache)
 OS + Docker + vLLM             6.0 GB    always-on
 OpenClaw + overhead            2.0 GB    always-on
───────────────────────────────────────────────────────────────
 TOTAL ALLOCATED (est.)       ~105.4 GB
 HEADROOM (est.)               ~16.3 GB   ✅ safe — MoE only activates 3B/token
═══════════════════════════════════════════════════════════════
```

---

## Repo Structure

```
spark-sovereign/
├── config/
│   ├── models.yml          ← SINGLE SOURCE OF TRUTH for all models
│   └── mcp_servers.json    ← MCP server catalog (copy blocks into OpenClaw)
├── scripts/
│   ├── 00_first_boot.sh       ← WiFi setup + NVIDIA Sync + Tailscale
│   ├── 01_system_prep.sh      ← Docker config, directories, Python deps, boot service
│   ├── 02_download_models.sh  ← Download model from HF → /opt/models (prunes unused)
│   ├── 03_vllm_servers.sh     ← Start Brain (port 8000)
│   ├── 04_voice_stt.sh        ← Local Whisper STT setup (optional, for voice notes)
│   ├── 05–09_*.sh             ← NOT NEEDED — OpenClaw onboard handles everything
│   ├── boot_sequence.sh       ← Auto-start on boot (installed by 01_system_prep.sh)
│   ├── start_brain_ad_hoc.sh  ← Restart Brain manually
│   └── check_stack.sh         ← Health check
├── docs/
│   └── TROUBLESHOOTING.md
├── .env.example            ← Copy to .env, fill in HF_TOKEN at minimum
└── .gitignore
```

---

## Setup — Box Open to Running

Three sequential layers — cannot skip any.

```
Layer 1: First boot wizard   — physical, one time, ~15 min
Layer 2: NVIDIA Sync + SSH   — on your laptop, one time, ~10 min
Layer 3: spark-sovereign     — on the Spark, via SSH
```

---

### Layer 1 — First Boot (Physical)

**Before you plug anything in:**
- There is **no power button** — plugging in power = immediate boot
- Connect all peripherals **before** plugging in power
- Keep the Quick Start Guide — hostname and hotspot credentials are on a sticker inside

**Option A — Headless:**
1. Power on → Spark broadcasts a WiFi hotspot
2. Connect your laptop to that SSID (credentials on sticker)
3. Browser captive portal opens — follow wizard: language → terms → username/password → home WiFi

**Option B — Monitor attached:**
1. Power on → wizard appears on display, same sequence

After WiFi connects, Spark downloads updates (~10 min) and reboots. It's then at `spark-XXXX.local`.

---

### Layer 2 — NVIDIA Sync + SSH (On Your Laptop)

Download NVIDIA Sync: `https://build.nvidia.com/spark/connect-to-your-spark/sync`

1. Open NVIDIA Sync → Settings → Devices → Add Device
2. Enter hostname (`spark-XXXX.local`), username, password → Add
3. Tray → select device → **Terminal**

**Tailscale (remote access from anywhere):**
- NVIDIA Sync → Settings → Tailscale → Enable → Add a Device
- Do NOT install the Tailscale app separately on your laptop

---

### Layer 3 — Scripts (Run on the Spark via SSH)

**One-time setup:**
```bash
sudo usermod -aG docker $USER && newgrp docker
```

**Clone and configure:**
```bash
git clone https://github.com/YOUR_ORG/spark-sovereign.git ~/spark-sovereign
cd ~/spark-sovereign
cp .env.example .env
nano .env   # set HF_TOKEN at minimum
```

**Run these four scripts in order** — each is idempotent, safe to re-run:

```bash
bash scripts/00_first_boot.sh      # Tailscale + confirms setup
bash scripts/01_system_prep.sh     # Docker config, dirs, Python deps, auto-start service
bash scripts/02_download_models.sh # Downloads Qwen3.5-35B-A3B-FP8 → /opt/models (~55GB)
bash scripts/03_vllm_servers.sh    # Starts Brain on port 8000 — waits until ready
```

Then open OpenClaw, run the onboard setup wizard, and point it at:
```
http://localhost:8000/v1
```

OpenClaw handles everything from there — voice, memory, web search, Telegram, MCP tools.

> **Script 02 automatically prunes old models.** Any model directory in `/opt/models` not listed in `config/models.yml` is deleted before the new download. Disk space is freed automatically.

---

## Auto-Start on Boot

Script 01 installs a systemd service (`spark-sovereign.service`) that runs automatically every time the Spark boots. No manual intervention needed after a power cycle:

1. OS boots → Docker starts → systemd triggers `spark-sovereign.service`
2. Brain container starts via `start_brain_ad_hoc.sh`
3. Service waits until port 8000 is ready before completing

**Note:** Brain takes **3–5 minutes to load** after a cold boot while ~55GB of weights load into memory. This is normal — OpenClaw will reconnect automatically once port 8000 is ready.

To check service status:
```bash
systemctl status spark-sovereign
journalctl -u spark-sovereign -f
```

---

## Swapping the Model

All model config lives in `config/models.yml` — the single source of truth.

1. Edit `config/models.yml` — update `hf_repo`, `name`, `local_path`, `served_name`, `gpu_memory_utilization`
2. Download:
   ```bash
   bash scripts/02_download_models.sh   # downloads new model, prunes old automatically
   ```
3. Restart:
   ```bash
   bash scripts/start_brain_ad_hoc.sh
   ```
4. Verify:
   ```bash
   bash scripts/check_stack.sh
   ```

Each section in `models.yml` has commented swap examples.

---

## Health Check

```bash
bash scripts/check_stack.sh
```

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

For the build journey and decisions behind this setup, see [docs/LESSONS.md](docs/LESSONS.md).

Common fixes:
- Brain not loading → `docker logs brain --tail 50`
- OOM → reduce `gpu_memory_utilization` in `config/models.yml`
- Swap model → edit `config/models.yml`, re-run `02_download_models.sh` + `start_brain_ad_hoc.sh`
- Restart Brain → `bash scripts/start_brain_ad_hoc.sh`
- Check auto-start logs → `journalctl -u spark-sovereign -f`
