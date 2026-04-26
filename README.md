# spark-sovereign

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-NVIDIA_DGX_Spark-76B900?logo=nvidia&logoColor=white)](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
[![OpenClaw](https://img.shields.io/badge/agentic_layer-OpenClaw-blueviolet?logo=lobster&logoColor=white)](https://github.com/openclaw/openclaw)
[![Model](https://img.shields.io/badge/model-Qwen3.6--35B--A3B--FP8-orange)](https://huggingface.co/Qwen/Qwen3.6-35B-A3B-FP8)
[![Speed](https://img.shields.io/badge/speed-~53_tok%2Fs-brightgreen)](config/models.yml)
[![Privacy](https://img.shields.io/badge/privacy-100%25_local-critical)](README.md)

**Your AI. Your hardware. Your rules.**

A fully self-contained, private AI stack running on the **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip, ~$4,000–$5,000 as of March 2026).

No cloud. No API keys. No rate limits. No surveillance. No subscriptions. No data leaving your machine. Ever.

Brain serves a standard **OpenAI-compatible API** — any agentic framework that speaks this protocol works out of the box. We test with [OpenClaw](https://github.com/openclaw/openclaw), but you can plug in LangChain, AutoGen, CrewAI, Open Interpreter, LobeChat, or anything else. The infrastructure layer doesn't care what's on top.

---

## Why This Exists

Proprietary frontier models come with strings attached — rate limiting, usage-based pricing, mass data collection, content moderation that blocks legitimate work, and terms of service that change without notice. You don't own anything. You're renting access to someone else's computer, on their terms.

The open-source community has been closing the gap fast. Models available today for private, local use are approaching — and in some benchmarks surpassing — proprietary alternatives. The hardware to run them is now available at consumer price points.

**spark-sovereign** is the bridge: a working, tested, production-ready setup that takes a DGX Spark from box-open to a fully operational private AI server — with CLI coding, chat, Telegram communication, voice, agentic tool use, multimodal input, web search, memory, and MCP integrations — all running locally.

This is for anyone who wants to **own their AI infrastructure** instead of renting it.

This setup lets you pick the best available open-weight model, serve it locally on your own 24/7 hardware, and point OpenClaw at it for full agentic capabilities. The only thing outside your control is electricity. Your AI stays up as long as you can pay the power bill. Use it to your heart's content — and as more intelligent, faster models become available, swap them in and instantly gain speed and intelligence boosts, with the VRAM limits of your Nvidia-CUDA optimized hardware.

---

## What You Get

**TLDR:** As of April 2026, this setup is a practical replacement for Claude Code and ChatGPT Codex for day-to-day engineering work. CLI coding, agentic tool use, parallel agents, chat, voice, Telegram, MCP integrations — all running locally, 24/7, with zero API dependency. An engineer can go fully off-grid and still get professional work done. Now running Qwen3.6 with 73.4% SWE-bench Verified and 262K native context.

- **~53 tokens/sec** sustained inference — no queue, no throttling, no network latency
- **262K context window** — long conversations, full codebase analysis, deep reasoning
- **Agentic coding** — tool calling, code execution, file management, web search
- **Parallel agents** — OpenClaw spawns multiple workers for complex tasks simultaneously
- **Voice I/O** — speak to it, it speaks back (local Whisper STT, configurable TTS)
- **Telegram bot** — message your AI from your phone, send voice notes, images, text
- **Persistent memory** — remembers across sessions, learns your codebase and preferences
- **Multimodal** — send images and video, Brain analyzes natively
- **MCP tools** — git, GitHub, browser, shell, databases, Slack, Stripe, and more
- **Auto-start on boot** — plug in power, walk away, it's ready in 5 minutes
- **109 of 128 GB VRAM utilized** — this setup pushes a single DGX Spark to its limit

### How This Compares (April 2026 — Honest Assessment)

|  | **spark-sovereign** (Qwen3.6-35B-A3B) | **Claude Code** (Opus 4.6) | **ChatGPT Codex** (GPT-5.4) |
|---|---|---|---|
| **Speed** | ~53 tok/s sustained, zero latency | Variable — depends on server load and queue | Variable — depends on server load and queue |
| **Coding** | Strong — handles day-to-day engineering, debugging, refactoring, and generation | Best-in-class for complex multi-step coding | Strong, comparable to Claude on most tasks |
| **Hard reasoning** | Good for most tasks; frontier models still lead on the hardest problems | Strongest on complex architectural reasoning | Strong, especially on math and long-chain logic |
| **Agentic** | Full — parallel agents, tool calling, MCP, code execution via OpenClaw | Full — native tool use, computer use | Full — native tool use, code interpreter |
| **Context window** | 262K tokens | 200K tokens | 128K–1M tokens |
| **Chat / conversation** | Unlimited — no session limits, no token caps | Session-limited, rate-limited on heavy use | Generous but usage-capped on Pro tier |
| **Voice** | Local STT + configurable TTS, Telegram voice notes | Not available in CLI | Voice mode available |
| **Privacy** | 100% local — zero data leaves your machine | Data processed on Anthropic servers | Data processed on OpenAI servers |
| **Ownership** | You own the hardware, the model, and every byte of output | You own nothing — renting API access | You own nothing — renting API access |
| **Rate limits** | None — run it 24/7 at full speed | Yes — throttled during peak usage, hard caps on Pro | Yes — usage caps on all tiers |
| **Cost after setup** | Electricity only (~$5–15/month) | $20–200/month + API overages | $20–200/month + API overages |
| **Availability** | 24/7 — works offline, no outages, no maintenance windows | Dependent on Anthropic infrastructure | Dependent on OpenAI infrastructure |
| **Bans / ToS risk** | Zero — no terms of service, no content policy, no account to lose | Subject to Anthropic's acceptable use policy | Subject to OpenAI's usage policies |
| **Model upgrades** | Swap in newer open-weight models as they release — instant | Automatic but you have no choice or control | Automatic but you have no choice or control |

**The honest take:** Frontier models like Opus 4.6 and GPT-5.4 still lead on the hardest reasoning tasks — the kind where you need 500B+ active parameters grinding through a complex multi-file refactor or novel algorithm design. But for the vast majority of professional engineering work — writing code, debugging, reviewing PRs, chatting, running agents, using tools — this local setup gets the job done at ~53 tok/s with zero ongoing cost, total privacy, and no one standing between you and your AI.

The gap is closing fast. Every few weeks, a new open-weight model drops that's smarter and faster than the last. This hardware will only get more capable over time.

---

## Model Evolution

We tested multiple models to find the best intelligence-to-speed ratio on Spark hardware. The open-source ecosystem moves fast — what was best last month gets surpassed the next.

| Release | Model | Active Params | tok/s | Intelligence | Status |
|---|---|---|---|---|---|
| v1.0 | Qwen3.5-27B-FP8 (dense) | 27B | ~14–30 | High | Too slow — hit memory bandwidth ceiling |
| v2.0 | Nemotron-3-Nano-30B-A3B-FP8 | 3B | ~35–45 | Medium | Fast but weaker on coding/reasoning |
| v3.0 | Qwen3.5-35B-A3B-FP8 | 3B | ~49 | High | Retired — superseded by v4.0 |
| **v4.0** | **Qwen3.6-35B-A3B-FP8** | **3B** | **~53** | **High** | **Current — drop-in upgrade from v3.0** |

The current model (Qwen3.6-35B-A3B-FP8) is a Gated DeltaNet + MoE hybrid that activates only 3B parameters per token while having 35B total params to draw from. The DeltaNet architecture uses linear attention for 3/4 of layers, dramatically reducing KV cache pressure at long contexts — native 262K context vs 131K on the previous Qwen3.5. Scores 73.4% on SWE-bench Verified (+3.4 over v3.0) and 51.5% on Terminal-Bench 2.0 (+11 over v3.0).

For the full build journey and every decision made, see [docs/LESSONS.md](docs/LESSONS.md).

---

## Architecture

```
vLLM (Brain)  →  http://localhost:8000/v1  (OpenAI-compatible API)
      |
Agentic layer  →  OpenClaw, LangChain, AutoGen, CrewAI, or any framework
      |
You  →  Terminal, Telegram, browser UI, CLI, whatever your framework supports
```

Brain runs as a Docker container serving the model via vLLM on a standard OpenAI-compatible endpoint. Any framework that can call `/v1/chat/completions` works — tool calling, streaming, multimodal, all supported at the API level.

We test and document with **OpenClaw** (open source, fully local, no API key). But this is a plug-and-play infrastructure layer — swap in whatever agentic framework fits your workflow.

---

## Current Model

| Component | Model | Weights | Port | tok/s |
|---|---|---|---|---|
| **Brain** | Qwen/Qwen3.6-35B-A3B-FP8 | ~35 GB | 8000 | ~53 |

**Key specs:**
- Gated DeltaNet + MoE hybrid: 35B total, 3B active per token — fast inference, high intelligence
- `vllm/vllm-openai:cu130-nightly` — standard image, no custom builds (requires vLLM >= 0.19.0)
- `qwen3_coder` tool parser + `qwen3` reasoning parser
- FP8 weights + FP8 KV cache
- `gpu_memory_utilization: 0.80` (~97GB to vLLM — ~35GB weights + ~58GB KV cache, ~24GB left for OS/Docker)
- 262K native context — DeltaNet linear attention keeps KV cache manageable
- Prefix caching enabled — fast repeated prompts

---

## Memory Map

This setup uses **~109 of 128 GB** — pushing a single DGX Spark close to its limit.

```
128GB DGX Spark Unified Memory (121.69 GiB visible to CUDA)
===============================================================
 Qwen3.6-35B-A3B FP8 (Brain)  ~97.4 GB    0.80 util (~35GB weights + ~58GB KV cache)
 OS + Docker + vLLM             6.0 GB    always-on
 OpenClaw + overhead            2.0 GB    always-on
---------------------------------------------------------------
 TOTAL ALLOCATED (est.)       ~109.0 GB
 HEADROOM (est.)               ~12.7 GB   safe — MoE only activates 3B/token
===============================================================
```

As NVIDIA improves the DGX Spark hardware and the open-source community releases smarter, more efficiently quantized models, these numbers will only get better. The Spark is a long-term investment — the models you run on it next year will be significantly more capable than what's available today, on the same hardware.

---

## What the Agentic Layer Provides

The capabilities below depend on your chosen framework. OpenClaw provides all of these out of the box. Other frameworks may offer different subsets or equivalents.

| Capability | OpenClaw | Other Frameworks |
|---|---|---|
| **Voice I/O** | Speak → transcribe → Brain responds → speaks back | Varies by framework |
| **STT (Speech-to-Text)** | Local Whisper CLI (GPU-accelerated) or cloud providers | Framework-dependent |
| **TTS (Text-to-Speech)** | Provider-based (ElevenLabs, Microsoft, OpenAI) | Framework-dependent |
| **Image / video** | Send photo or video → Brain analyzes natively | Any framework can pass multimodal to the API |
| **Memory** | Persistent across sessions — learns from every conversation | Framework-dependent |
| **Web search** | Live search, results fed to Brain | Framework-dependent |
| **Telegram** | Message your bot → Brain responds. Voice notes, images, text | Varies |
| **MCP tools** | Files, git, GitHub, browser, HTTP, shell, AWS, Stripe, Slack | Growing MCP ecosystem |
| **Agent orchestration** | Brain spawns parallel workers for long tasks | LangChain, AutoGen, CrewAI, etc. |
| **TUI / Chat** | `openclaw tui` — interactive terminal chat | Most frameworks include a chat interface |

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
bash scripts/02_download_models.sh # Downloads model → /opt/models (~35GB)
bash scripts/03_vllm_servers.sh    # Starts Brain on port 8000 — waits until ready
```

Then connect your agentic framework of choice to `http://localhost:8000/v1`.

**With OpenClaw (recommended):** `openclaw onboard` → enter `http://localhost:8000/v1` as the base URL.

**With any other framework:** Point it at `http://localhost:8000/v1` using the OpenAI-compatible API. Model ID is the `served_name` from `config/models.yml`. API key can be any string.

See [docs/OPENCLAW_SETUP.md](docs/OPENCLAW_SETUP.md) for detailed connection examples (curl, Python, Node.js).

> **Script 02 automatically prunes old models.** Any model directory in `/opt/models` not listed in `config/models.yml` is deleted before the new download.

---

## Auto-Start on Boot

Script 01 installs a systemd service that starts Brain automatically on every power cycle. No manual intervention needed.

Brain takes **3–5 minutes to load** after a cold boot (~35GB of weights loading into memory). OpenClaw reconnects automatically once ready.

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
│   ├── OPENCLAW_SETUP.md   ← Agentic framework connection guide
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

## Agentic Layer — OpenClaw and Beyond

**spark-sovereign is the brain — your agentic framework is the body it controls.** spark-sovereign is the sovereign private intelligence that replaces ChatGPT, Claude, and every other paid API endpoint. It's the brain you own — running on your hardware, serving your model, answering to no one. Your agentic framework is the body — the claws that grip tools, the legs that walk through your filesystem, the nervous system that connects voice, chat, agents, memory, and MCP. The brain thinks, the body acts.

Without spark-sovereign, your framework needs someone else's brain (a cloud API). Without an agentic framework, spark-sovereign is just a model sitting on a port with no way to reach the world. Together, they're a fully autonomous AI that belongs to you.

### Why we test with OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is open source, requires no API key, and runs fully local — matching spark-sovereign's zero-cloud philosophy. It provides voice, memory, Telegram, MCP tools, and agent orchestration in a single package.

**Feature request:** [openclaw/openclaw#60792](https://github.com/openclaw/openclaw/issues/60792) — we've proposed spark-sovereign as a community hardware reference for DGX Spark users.

### Using a different framework

Any framework that supports OpenAI-compatible endpoints works. Point it at:

```
Base URL:  http://localhost:8000/v1
Model ID:  qwen36-35b  (or your served_name from config/models.yml)
API key:   any string
```

See [docs/OPENCLAW_SETUP.md](docs/OPENCLAW_SETUP.md) for connection examples in curl, Python, and Node.js.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Free to use, modify, and distribute with attribution. The models referenced are open-weight and available on HuggingFace under their respective licenses. vLLM and OpenClaw are open source (MIT/Apache 2.0).

---

*Built in public. Own your AI.*
