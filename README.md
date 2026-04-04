# spark-sovereign

**Your AI. Your hardware. Your rules.**

A fully self-contained, private AI stack running on the **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip, ~$4,000–$5,000 as of March 2026).

No cloud. No API keys. No rate limits. No surveillance. No subscriptions. No data leaving your machine. Ever.

---

## Why This Exists

Proprietary frontier models come with strings attached — rate limiting, usage-based pricing, mass data collection, content moderation that blocks legitimate work, and terms of service that change without notice. You don't own anything. You're renting access to someone else's computer, on their terms.

The open-source community has been closing the gap fast. Models available today for private, local use are approaching — and in some benchmarks surpassing — proprietary alternatives. The hardware to run them is now available at consumer price points.

**spark-sovereign** is the bridge: a working, tested, production-ready setup that takes a DGX Spark from box-open to a fully operational private AI server — with CLI coding, chat, Telegram communication, voice, agentic tool use, multimodal input, web search, memory, and MCP integrations — all running locally.

This is for anyone who wants to **own their AI infrastructure** instead of renting it.

---

## What You Get

- **~49 tokens/sec** inference on a 35B-parameter model (3B active per token via MoE)
- **131K context window** — long conversations, full codebase analysis, deep reasoning
- **Tool calling** — your AI can use tools, execute code, search the web, manage files
- **Voice I/O** — speak to it, it speaks back (local STT, configurable TTS)
- **Telegram bot** — message your AI from your phone, send voice notes, images, text
- **Persistent memory** — it remembers across sessions
- **Agent orchestration** — spawns parallel workers for complex tasks
- **Multimodal** — send images and video, Brain analyzes natively
- **MCP tools** — git, GitHub, browser, shell, databases, Slack, Stripe, and more
- **Auto-start on boot** — plug in power, walk away, it's ready in 5 minutes

---

## Model Evolution

We tested multiple models to find the best intelligence-to-speed ratio on Spark hardware. The open-source ecosystem moves fast — what was best last month gets surpassed the next.

| Release | Model | Active Params | tok/s | Intelligence | Status |
|---|---|---|---|---|---|
| v1.0 | Qwen3.5-27B-FP8 (dense) | 27B | ~14–30 | High | Too slow — hit memory bandwidth ceiling |
| v2.0 | Nemotron-3-Nano-30B-A3B-FP8 | 3B | ~35–45 | Medium | Fast but weaker on coding/reasoning |
| **v3.0** | **Qwen3.5-35B-A3B-FP8** | **3B** | **~49** | **High** | **Current — fastest and smartest** |

The current model (Qwen3.5-35B-A3B-FP8) is a Mixture-of-Experts architecture that activates only 3B parameters per token while having 35B total params to draw from. Community benchmarks confirm it surpasses Qwen3-235B-A22B (which activates 22B per token) — better architecture and training, not just bigger numbers.

For the full build journey and every decision made, see [docs/LESSONS.md](docs/LESSONS.md).

---

## Architecture

```
vLLM (Brain)  →  http://localhost:8000/v1
      |
OpenClaw  →  agent orchestration, memory, tools, voice, web search
      |
You  →  Terminal (TUI), Telegram, browser UI at http://localhost:18789
```

Brain runs as a Docker container serving the model via vLLM. OpenClaw connects to it and provides everything on top. One model. One endpoint. Fully self-contained.

---

## Current Model

| Component | Model | Weights | Port | tok/s |
|---|---|---|---|---|
| **Brain** | Qwen/Qwen3.5-35B-A3B-FP8 | ~55 GB | 8000 | ~49 |

**Key specs:**
- MoE: 35B total, 3B active per token — fast inference, high intelligence
- `vllm/vllm-openai:cu130-nightly` — standard image, no custom builds
- `qwen3_coder` tool parser + `qwen3` reasoning parser
- FP8 weights + FP8 KV cache
- `gpu_memory_utilization: 0.80` (~97GB to vLLM, ~24GB left for OS/Docker)
- Prefix caching enabled — fast repeated prompts

---

## Memory Map

```
128GB DGX Spark Unified Memory (121.69 GiB visible to CUDA)
===============================================================
 Qwen3.5-35B-A3B FP8 (Brain)  ~97.4 GB    0.80 util (~55GB weights + ~42GB KV cache)
 OS + Docker + vLLM             6.0 GB    always-on
 OpenClaw + overhead            2.0 GB    always-on
---------------------------------------------------------------
 TOTAL ALLOCATED (est.)       ~105.4 GB
 HEADROOM (est.)               ~16.3 GB   safe — MoE only activates 3B/token
===============================================================
```

---

## What OpenClaw Provides

| Capability | How |
|---|---|
| **Voice I/O** | Speak → transcribe → Brain responds → speaks back |
| **STT (Speech-to-Text)** | Local Whisper CLI (GPU-accelerated) or cloud providers |
| **TTS (Text-to-Speech)** | Provider-based (ElevenLabs, Microsoft, OpenAI) |
| **Talk Mode** | Continuous voice conversation with streaming TTS |
| **Image / video** | Send photo or video → Brain analyzes natively |
| **Memory** | Persistent across sessions — learns from every conversation |
| **Web search** | Live search, results fed to Brain |
| **Telegram** | Message your bot → Brain responds. Voice notes, images, text |
| **MCP tools** | Files, git, GitHub, browser, HTTP, shell, AWS, Stripe, Slack |
| **Agent orchestration** | Brain spawns parallel workers for long tasks |
| **TUI** | `openclaw tui` — interactive terminal chat |

---

## Setup — Box Open to Running

Three layers, run once, done.

```
Layer 1: First boot wizard   — physical, one time, ~15 min
Layer 2: NVIDIA Sync + SSH   — on your laptop, one time, ~10 min
Layer 3: spark-sovereign     — on the Spark, via SSH
```

### Layer 1 — First Boot (Physical)

- There is **no power button** — plugging in power = immediate boot
- Connect all peripherals **before** plugging in power
- Keep the Quick Start Guide — hostname and hotspot credentials are on a sticker inside

**Headless:** Power on → connect to Spark's WiFi hotspot → browser wizard opens → set username/password → connect to home WiFi

**With monitor:** Same wizard appears on display.

After WiFi connects, Spark downloads updates (~10 min) and reboots.

### Layer 2 — NVIDIA Sync + SSH (On Your Laptop)

1. Download NVIDIA Sync from `https://build.nvidia.com/spark/connect-to-your-spark/sync`
2. Add Device → enter hostname (`spark-XXXX.local`), username, password
3. Tray → select device → **Terminal**

**Remote access:** NVIDIA Sync → Settings → Tailscale → Enable → Add a Device

### Layer 3 — Scripts (Run on the Spark via SSH)

```bash
# One-time setup
sudo usermod -aG docker $USER && newgrp docker

# Clone and configure
git clone https://github.com/thatwonguy/spark-sovereign.git ~/spark-sovereign
cd ~/spark-sovereign
cp .env.example .env
nano .env   # set HF_TOKEN at minimum

# Run these four scripts in order (idempotent, safe to re-run)
bash scripts/00_first_boot.sh      # Tailscale + confirms setup
bash scripts/01_system_prep.sh     # Docker config, dirs, Python deps, auto-start service
bash scripts/02_download_models.sh # Downloads model → /opt/models (~55GB)
bash scripts/03_vllm_servers.sh    # Starts Brain on port 8000 — waits until ready
```

Then open OpenClaw, run the onboard wizard, and point it at `http://localhost:8000/v1`.

That's it. OpenClaw handles everything from there.

> **Script 02 automatically prunes old models.** Any model directory in `/opt/models` not listed in `config/models.yml` is deleted before the new download.

---

## Auto-Start on Boot

Script 01 installs a systemd service that starts Brain automatically on every power cycle. No manual intervention needed.

Brain takes **3–5 minutes to load** after a cold boot (~55GB of weights loading into memory). OpenClaw reconnects automatically once ready.

```bash
systemctl status spark-sovereign
journalctl -u spark-sovereign -f
```

---

## Swapping the Model

All model config lives in `config/models.yml` — the single source of truth.

1. Edit `config/models.yml` — update model fields
2. `bash scripts/02_download_models.sh` — downloads new, prunes old
3. `bash scripts/start_brain_ad_hoc.sh` — restarts Brain
4. Update OpenClaw model ID → `openclaw gateway restart`

Each section in `models.yml` has commented swap examples. See [docs/LESSONS.md](docs/LESSONS.md) for what we've tested and why.

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
│   ├── 04_voice_stt.sh        ← Local Whisper STT setup (optional)
│   ├── boot_sequence.sh       ← Auto-start on boot
│   ├── start_brain_ad_hoc.sh  ← Restart Brain manually
│   └── check_stack.sh         ← Health check
├── docs/
│   ├── LESSONS.md          ← Full build journey and model decisions
│   └── TROUBLESHOOTING.md
├── .env.example            ← Copy to .env, fill in HF_TOKEN at minimum
└── .gitignore
```

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Common fixes:
- Brain not loading → `docker logs brain --tail 50`
- OOM → reduce `gpu_memory_utilization` in `config/models.yml`
- Swap model → edit `config/models.yml`, re-run `02_download_models.sh` + `start_brain_ad_hoc.sh`
- Check auto-start logs → `journalctl -u spark-sovereign -f`

---

## License

This is a setup and configuration repo — no proprietary code. The models referenced are open-weight and available on HuggingFace under their respective licenses. vLLM and OpenClaw are open source.

---

*Built in public. Own your AI.*
