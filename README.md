# spark-sovereign

Private local AI supercomputer stack on **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip).

**Zero cloud. Zero API cost. Gets smarter every session.**

- Qwen3.5-35B-A3B FP8 brain — native multimodal, coding, agentic, 262K context, **50+ tok/s**
- Streaming voice I/O (ASR + TTS)
- pgvector continuous learning memory + SearXNG web search RAG
- NemoClaw agentic orchestration via Telegram / Slack
- Aider CLI coding with local models
- **Fully modular** — swap any model by editing one YAML file

---

## Full Capability Map

Everything this stack can do — across all interfaces and modalities.

### Voice (speak → think → speak back)

| Capability | How |
|---|---|
| **Speech to text** | Nemotron ASR (port 8002) — streaming WebSocket, sub-second latency, March 2026 checkpoint |
| **Text to speech** | Magpie TTS (port 8003) — 7 languages, 5 voices, multilingual 357M model |
| **Voice on phone** | Send a Telegram voice note → ASR transcribes → Brain answers → TTS speaks back |
| **Wake word / always-on** | Configure Pipecat pipeline with a wake-word detector; Spark listens on your LAN microphone |

### Vision (image → understand → act)

| Capability | How |
|---|---|
| **Image understanding** | Qwen3.5-35B-A3B is a native multimodal model — send images via `/v1/chat/completions` with base64 content |
| **Screenshot analysis** | Send a screenshot from your phone or laptop; Brain describes, debugs, or acts on what it sees |
| **Diagram / chart reading** | Architecture diagrams, ERDs, whiteboards — top-tier spatial reasoning |
| **Photo to text** | Handwritten notes, whiteboard photos, documents — OCR across multiple languages |
| **Vision via Telegram** | Send any photo to the Telegram bot → Brain analyzes and responds |

### Single Model — Full Capability at 50+ tok/s

Brain handles everything: vision, coding, agentic tool calls, reasoning, chat — all at **50+ tok/s** on the DGX Spark GB10 with 262K context.

| Model | Speed | Capabilities |
|---|---|---|
| **Qwen3.5-35B-A3B FP8 (Brain)** | **50+ tok/s** | Vision, coding, agentic, reasoning, chat, tool calls, 262K context |

Mode control still works exactly as before:

| Trigger | What happens |
|---|---|
| `/deep` or `deep mode` | Deep reasoning mode — extended thinking budget |
| `/fast` or `fast mode` | Fast response mode — reduced thinking |
| `/auto` or `auto mode` | Auto-classify per message |

### Agentic Orchestration — Brain Spawns Workers

Sub-agent spawning is an **OpenClaw capability** (`sessions_spawn` API). Brain orchestrates parallel workers, all running the same model concurrently at 50+ tok/s.

```
"Tonight, build the Stripe billing module, write tests, push to GitHub"
        ↓
Brain (orchestrator) — decomposes the goal
        ↓
sessions_spawn × 3 (parallel):
  Brain worker 1 → writes billing code      (filesystem + git MCP)
  Brain worker 2 → writes tests             (filesystem MCP)
  Brain worker 3 → writes docs + README     (filesystem MCP)
        ↓
Brain reviews, commits via git MCP, opens PR via github MCP
        ↓
Sends you Telegram summary
```

NemoClaw sandboxes isolate each agent run:
- Network namespace — only explicitly allowed outbound endpoints
- Filesystem access — scoped to your projects directory
- MCP tools — available as callable functions inside the sandbox

```bash
nemoclaw deep connect    # Brain — vision, coding, reasoning, agents
nemoclaw list            # all sandboxes + status
openshell term           # real-time monitor
```

### Remote Access — Work From Anywhere

| Method | How |
|---|---|
| **SSH from anywhere** | Tailscale gives your Spark a persistent encrypted IP |
| **NVIDIA Sync** | One-click SSH + VS Code from the system tray app on macOS/Windows |
| **VS Code Remote** | Full IDE running on Spark's hardware |
| **Aider coding** | `aider --message "..."` from any SSH session. Brain writes the code. No tokens billed |
| **GitHub workflows** | Agent handles PR creation, code review, branch management, CI monitoring via GitHub MCP |
| **Terminal everywhere** | SSH → tmux → leave long-running agent tasks running, reconnect from anywhere |

### Mobile — Full ChatGPT-on-Phone Experience via Telegram/Slack

| Feature | ChatGPT App | spark-sovereign (Telegram/Slack) |
|---|---|---|
| Text conversation | Yes | Yes — Brain responds in seconds |
| Voice notes | Yes | Yes — ASR transcribes, TTS responds |
| Image analysis | Yes | Yes — Brain native multimodal |
| Web search | Yes (limited) | Yes — SearXNG, full results, stored in your DB |
| Memory | Basic (opt-in) | Full — every session builds the vector DB |
| Run code | No | Yes — shell MCP executes on Spark |
| Push to GitHub | No | Yes — GitHub MCP |
| Control infrastructure | No | Yes — Docker, AWS, shell MCP |
| Bill per message | Yes ($20+/mo) | No — $0 per message |
| Private | No | Yes — never leaves your hardware |

### What the Agent Can Control via MCP

| Category | Package | What the agent can do |
|---|---|---|
| **Files** | `@modelcontextprotocol/server-filesystem` (npm) | Read, write, search, move files in your projects directory |
| **Git** | `mcp-server-git` (uvx/PyPI) | Commit, branch, diff, log, stash — on any local repo |
| **GitHub** | `@modelcontextprotocol/server-github` (npm) | Create PRs, review code, open issues, manage releases |
| **Browser** | `@modelcontextprotocol/server-puppeteer` (npm) | Navigate sites, click, fill forms, take screenshots, scrape |
| **HTTP** | `mcp-server-fetch` (uvx/PyPI) | Call any REST API with custom headers and bodies |
| **Database** | `@modelcontextprotocol/server-postgres` (npm) | Query pgvector memory DB or any PostgreSQL DB |
| **Memory** | `@modelcontextprotocol/server-memory` (npm) | In-session knowledge graph; complements pgvector |
| **Reasoning** | `@modelcontextprotocol/server-sequential-thinking` (npm) | Structured multi-step decomposition for complex tasks |
| **AWS** | `@aws/mcp-server` (npm — official) | S3, EC2, Lambda, CloudWatch, DynamoDB |
| **Stripe** | `@stripe/mcp` (npm — official) | Customers, subscriptions, invoices, refunds |
| **Slack** | `@modelcontextprotocol/server-slack` (npm) | Send messages, read channels, search history |

> **Shell/Docker:** NemoClaw's OpenShell sandbox handles safe command execution natively — no separate MCP server needed.

See `config/mcp_servers.json` for the full catalog.

---

## What This Is — and Why It Compounds

Most AI setups are stateless: every session starts from zero, every token costs money, everything you type leaves your network. spark-sovereign is the opposite. It runs a 35B native multimodal brain entirely on local hardware, with a pgvector memory layer that accumulates verified knowledge across every session. Web search results that prove correct get stored permanently. Failures get tagged and avoided. At the end of each session, the model curates durable lessons from what happened and writes them to the DB. The system gets materially smarter with every use — not through retraining, but through growing, queryable, domain-specific memory. After six months of daily use, your Spark knows your codebase, your preferences, your infrastructure, and your failure patterns in a way no cloud model ever will.

---

## Model Benchmarks

### Brain — Qwen3.5-35B-A3B-FP8

Native multimodal MoE: 35B total parameters, 3B active per token. Official FP8 from Qwen.

#### Performance on DGX Spark GB10

| Metric | Result |
|---|---|
| **Throughput** | **50+ tok/s** sustained (standard vLLM FP8) |
| **Context window** | **262K tokens** |
| **Architecture** | MoE — 35B total / 3B active per token |
| **Vision** | Native multimodal (early fusion — no separate encoder) |

#### Vision & Multimodal

| Benchmark | Qwen3.5-35B-A3B | Qwen3-VL-32B | Notes |
|---|---|---|---|
| **Visual reasoning** | **Exceeds** | Baseline | Outperforms Qwen3-VL across all benchmarks |
| **Coding** | **Exceeds** | Baseline | Better on HumanEval, coding agents |
| **Agents** | **Exceeds** | Baseline | Cross-generational improvement |
| **Context** | **262K** | 128K | 2× longer context |
| **Speed** | **50+ tok/s** | ~20-30 tok/s | ~2× faster |

#### Memory Footprint

| Precision | Weights | GPU allocated (util 0.40) |
|---|---|---|
| **FP8 (deployed)** | **~35 GB** | **~49 GB** |
| BF16 (base) | ~70 GB | — |

---

## Capability Comparison

### At deployment vs. frontier cloud models (March 2026)

| Capability | GPT-5.4 (OpenAI Cloud) | Claude Sonnet 4.6 (Anthropic Cloud) | spark-sovereign (Local) |
|---|---|---|---|
| **Raw reasoning** | Best-in-class | Best-in-class | ~85–90% parity (Qwen3.5-35B-A3B) |
| **Vision / multimodal** | Best-in-class | Best-in-class | **Competitive** — native multimodal MoE |
| **Context window** | 1M tokens | 200K tokens | **262K** |
| **Speed** | Fast | Fast | **50+ tok/s** |
| **Cost per session** | $5–50+ | $2–20+ | **$0** |
| **Privacy** | Data sent to OpenAI | Data sent to Anthropic | **100% local** |
| **Memory across sessions** | Optional (limited) | None by default | **Full pgvector — grows every session** |
| **Voice I/O** | API only | API only | **Native ASR + TTS streaming** |
| **Works offline** | No | No | **Yes** |
| **Fine-tuning on your data** | Expensive, restricted | Not available | **Full dataset ownership** |

---

## Model Stack (March 2026)

| Component | Model | Size | Port |
|---|---|---|---|
| **Brain** (coding, vision, agentic, chat) | Qwen/Qwen3.5-35B-A3B-FP8 | ~35 GB | 8000 |
| Voice in (ASR) | nvidia/nemotron-speech-streaming-en-0.6b | ~2.4 GB | 8002 |
| Voice out (TTS) | nvidia/magpie_tts_multilingual_357m | ~1.4 GB | 8003 |
| Embeddings (RAG/memory) | nomic-ai/nomic-embed-text-v1.5 | ~0.4 GB | 8004 |
| Vector DB | pgvector 0.8.2 on PostgreSQL 17 | ~2 GB | 5432 |
| Web search | SearXNG latest | <1 GB | 8088 |
| Agent runtime | NemoClaw + OpenClaw | ~1 GB | 18789 |
| **Total** | | **~42 GB** | |
| **Headroom** | | **~80 GB** ✅ | |

---

## Repo Structure

```
spark-sovereign/
├── config/
│   ├── models.yml          ← SINGLE SOURCE OF TRUTH for all models
│   ├── openclaw.json       ← NemoClaw agent config
│   ├── aider.conf.yml      ← Aider CLI config
│   └── pgvector/
│       └── init.sql        ← pgvector schema (lessons + rag_cache)
├── scripts/
│   ├── 00_first_boot.sh       ← WiFi setup + NVIDIA Sync + Tailscale
│   ├── 01_system_prep.sh      ← Docker cgroup, directories, Python deps, boot service
│   ├── 02_download_models.sh  ← Download all HF models, prune unused
│   ├── 03_vllm_servers.sh     ← Start Brain (8000)
│   ├── 04_voice_pipeline.sh   ← Start ASR (8002) + TTS (8003)
│   ├── 05_pgvector.sh         ← Start pgvector + apply schema
│   ├── 06_searxng.sh          ← Start SearXNG web search
│   ├── 07_nemoclaw.sh         ← Install + start NemoClaw agent runtime
│   ├── 08_aider.sh            ← Install aider config
│   ├── start_brain_ad_hoc.sh  ← Restart Brain (stops GPU consumers first)
│   └── check_stack.sh         ← Health check for all services
├── agent/
│   ├── memory.py           ← Continuous learning layer (store/recall/curate)
│   ├── router.py           ← Model router (fast/deep/auto mode)
│   ├── log.py              ← Shared logger (console + rotating file)
│   └── requirements.txt
├── docs/
│   └── TROUBLESHOOTING.md
├── .env.example            ← Copy to .env, fill in secrets
└── .gitignore
```

---

## Setup — Box Open to Running

Three sequential layers — cannot skip any.

```
Layer 1: First boot wizard        — physical, one time, ~15 min
Layer 2: NVIDIA Sync + SSH        — on your laptop, one time, ~10 min
Layer 3: spark-sovereign scripts  — on the Spark, via SSH
```

---

### Layer 1 — First Boot (Physical, No Script)

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

### Layer 3 — spark-sovereign Scripts (Run on the Spark via SSH)

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

**Run phases in order** — each script is idempotent, safe to re-run:

```bash
bash scripts/00_first_boot.sh      # Tailscale + confirms setup
bash scripts/01_system_prep.sh     # Docker config, dirs, Python deps, boot service
bash scripts/02_download_models.sh # ~37GB download — prunes unused models automatically
bash scripts/03_vllm_servers.sh    # Brain (8000) — waits until ready
bash scripts/04_voice_pipeline.sh  # ASR (8002) + TTS (8003) — first run builds image (~2-3hrs)
bash scripts/05_pgvector.sh        # Vector DB + schema
bash scripts/06_searxng.sh         # Local web search
bash scripts/07_nemoclaw.sh        # NemoClaw — interactive onboarding wizard
bash scripts/08_aider.sh           # Aider CLI config
bash scripts/check_stack.sh        # Verify everything is up
```

> **Script 02 automatically prunes old models.** If you previously downloaded Qwen3-VL-32B or Nemotron-Nano, they will be deleted from `/opt/models` before the new model is downloaded. Disk space is freed automatically.

**NemoClaw onboarding (Phase 7) is interactive:**
- Quickstart vs Manual → **Quickstart**
- Model provider → **Other OpenAI-compatible endpoint**
  - URL: `http://localhost:8000/v1`
  - Model: `qwen35-35b-a3b`
- Communication channel → **Skip for now**
- Hooks → **Enable all three**
- Sandbox name → **deep**
- Policy presets → **n** (skip — no NVIDIA API key needed for local stack)

---

### After Setup

```bash
nemoclaw deep connect    # Brain sandbox — vision, coding, reasoning, agents
openclaw tui             # interactive chat inside active sandbox
```

Or from Telegram/Slack once tokens are set in `.env`.

---

## CLI — How to Communicate with Your AI

OpenClaw provides multiple CLI interfaces for direct control:

```bash
# Interactive chat interface (recommended for ongoing work)
openclaw tui

# View logs in real-time
openclaw logs --follow

# Check gateway/connection status
openclaw gateway status

# Check all channel connections (Telegram, Discord, etc.)
openclaw channels status --deep

# List all MCP servers and their status
openclaw mcp list

# Check git status in your workspace
git diff
```

**Quick reference:**
- `openclaw tui` — Interactive terminal chat with the brain
- `openclaw logs` — Follow activity logs
- `openclaw gateway status` — Gateway connectivity
- `openclaw channels status` — Communication channels
- `openclaw mcp list` — MCP servers and capabilities

All commands work from any SSH session into your Spark.

---

## Swapping a Model

All model config lives in `config/models.yml`. To swap:

## Model Swap Recommendations (2026-03)

**Current model is optimal** — Qwen3.5-35B-A3B-FP8 is the best choice for now.

| Model | Size | Speed | Vision | Context | Recommendation |
|-------|------|-------|--------|---------|----------------|
| **Qwen3.5-35B-A3B** (current) | ~35GB | 50+ tok/s | ✅ Native | 262K | ✅ Keep |
| **Nemotron 3 Omni** (upcoming) | ~35GB | ~65 tok/s | ✅ Native | 200K+ | ⏳ Wait for NVIDIA GTC 2026 release |
| **Nemotron 3 Nano 30B** | ~15GB | ~60 tok/s | ❌ Text | 131K | ➕ Add as sub-agent (dual-model) |
| **DeepSeek R1 32B** | ~32GB | 45-50 tok/s | ❌ Text | 128K | 🔄 Only for reasoning focus |

**My recommendation:** Stay with Qwen3.5. Nemotron 3 Omni (multimodal) is coming soon and will be the true successor.

**Quick swap steps:**
1. Edit `config/models.yml` — change `hf_repo`, `local_path`, GPU util
2. Download: `bash scripts/02_download_models.sh` (auto-prunes old model)
3. Restart: `bash scripts/start_brain_ad_hoc.sh`
4. Verify: `bash scripts/check_stack.sh`

---

All model config lives in `config/models.yml`. To swap:

1. Edit `config/models.yml` — change `hf_repo`, `local_path`, GPU util, etc. Each section has a commented `SWAP EXAMPLE`.

2. Download and prune:
   ```bash
   bash scripts/02_download_models.sh   # downloads new, deletes old automatically
   ```

3. Restart:
   ```bash
   bash scripts/start_brain_ad_hoc.sh   # or: bash scripts/03_vllm_servers.sh
   ```

4. Verify:
   ```bash
   bash scripts/check_stack.sh
   ```

---

## Memory Architecture — How the System Gets Smarter

Every session:

1. **Checks pgvector first** — relevant lessons or verified results? Uses them directly.
2. **Falls back to SearXNG** if no local knowledge — stores results in `rag_cache`.
3. **Confirms correct results** — `confirm_web_result()` marks `verified=TRUE, confidence=1.0`.
4. **Curates at session end** — `curate_session()` sends summary to Brain, which extracts durable lessons into the `lessons` table.
5. **Failures ranked highest** (`importance=1.0`) — never repeat the same mistake.

```python
from agent.memory import recall_as_context, store_web_result, confirm_web_result, curate_session

context = recall_as_context("stripe webhook subscription.updated", domain="stripe")
result_id = store_web_result(query="...", result="...", url="...")
confirm_web_result(result_id)
lessons = curate_session(session_summary_text, domain="stripe")
```

```bash
python3 agent/memory.py recall "how to handle stripe webhooks"
python3 agent/memory.py stats
```

---

## Aider — AI-Pair Coding with Local Models

```bash
cd ~/projects/my-saas
aider                                    # interactive TUI
aider --message "Add Stripe webhook handler for subscription.updated"
aider --message "Add tests for the auth middleware"
```

Config at `~/.aider.conf.yml` (installed by `scripts/08_aider.sh`).

---

## VS Code Remote

Via NVIDIA Sync: Tray → your Spark → **VS Code**

Manually:
```
VS Code → Remote Explorer → + New Remote → ssh user@spark-XXXX.local
```

---

## NemoClaw — Agent Runtime + Telegram

UI at `http://localhost:18789` (run `openshell forward 18789 deep` first to activate port forward).

Brain handles all tasks — vision, coding, reasoning, sub-agents — at 50+ tok/s.

### Adding Telegram (talk from your phone)

1. Message **@BotFather** on Telegram → `/newbot` → choose a name and username → copy the token (`7xxxxxxxxx:AAF...`)
2. Message **@userinfobot** on Telegram → it replies with your numeric user ID
3. Add both to `.env`:
   ```
   TELEGRAM_BOT_TOKEN=7xxxxxxxxx:AAFxxxxxxx
   TELEGRAM_ALLOWED_USER_IDS=123456789
   ```
4. Re-run Phase 7 to apply the policy:
   ```bash
   bash scripts/07_nemoclaw.sh
   ```

That's it — message your bot on Telegram and Brain responds. Send voice notes, images, text.

### Re-running NemoClaw / adding more channels

`scripts/07_nemoclaw.sh` is fully re-runnable. It skips installs that are already done and just updates config + policies. Run it any time you:
- Add a new communication channel token to `.env`
- Need to reconfigure the inference endpoint
- Want to reset the `deep` sandbox

```bash
# Re-onboard (reconfigures sandbox from scratch)
bash scripts/07_nemoclaw.sh

# Or just apply a policy to the existing sandbox
nemoclaw deep policy-add telegram
```

---

## Health Check

```bash
bash scripts/check_stack.sh
```

---

## Memory Map

```
128GB DGX Spark Unified Memory (121.69 GiB visible to CUDA)
═══════════════════════════════════════════════════════════════
 Qwen3.5-35B-A3B FP8           48.7 GB    0.40 util (~35GB weights + ~13GB KV)
 ASR (nemotron-speech)          2.4 GB    always-on
 TTS (magpie_tts)               1.4 GB    always-on
 Embeddings (nomic)             0.4 GB    always-on
 pgvector + PostgreSQL          2.0 GB    always-on
 SearXNG                        0.5 GB    always-on
 NemoClaw + OpenClaw            1.0 GB    always-on
 OS + Docker + vLLM             6.0 GB    always-on
───────────────────────────────────────────────────────────────
 TOTAL ALLOCATED                62.4 GB
 HEADROOM                       59.3 GB   ✅ very safe
═══════════════════════════════════════════════════════════════
```

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Common fixes:
- Brain not loading → `docker logs brain --tail 50`
- OOM → reduce `gpu_memory_utilization` in `config/models.yml`
- Swap model → edit `config/models.yml`, re-run `02_download_models.sh` + `start_brain_ad_hoc.sh`
- pgvector errors → `docker logs pgvector --tail 30`
- Restart Brain → `bash scripts/start_brain_ad_hoc.sh`

---

## Minimal Setup (After Testing)

**After several days of testing OpenClaw with the full stack, the findings:**

The system is over-engineered. After testing voice I/O, pgvector, and web search RAG extensively:

**Conclusion:** **OpenClaw handles all capabilities with just the vLLM brain container.**

The following containers are **NOT needed** for core functionality:
- `asr-server` (port 8002) - Voice transcription: Text input works fine
- `tts-server` (port 8003) - Voice synthesis: Text output is sufficient
- `pgvector` (port 5432) - Memory database: OpenClaw file-based memory works
- `searxng` (port 8088) - Web search: `web_fetch` tool accesses URLs directly
- `openshell-cluster-nemoclaw` - GPU orchestration: Not needed for local setup

**What you need:**
- **Only the brain container (vLLM at port 8000)** - serves the model
- Everything else is OpenClaw native capability

**Benefits of minimal setup:**
- Simpler to manage
- Less to monitor
- Faster boot time
- Same core functionality (code, vision, agentic, chat)

**Model focus:** Keep the brain running with whatever model gives best performance/speed tradeoff (Qwen3.5-35B-A3B is currently optimal).

**This is the recommended setup for new deployments.**
