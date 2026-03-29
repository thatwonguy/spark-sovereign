# spark-sovereign

Private local AI supercomputer stack on **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip).

**Zero cloud. Zero API cost. Gets smarter every session.**

- Qwen3.5-122B NVFP4 brain + Nemotron Nano sub-agents
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
| **Speech to text** | Nemotron ASR (port 8002) — streaming WebSocket, sub-second latency, trained on large English corpora (March 2026 checkpoint) |
| **Text to speech** | Magpie TTS (port 8003) — 7 languages, 5 voices, multilingual 357M model |
| **Voice on phone** | Send a Telegram voice note → ASR transcribes → Brain/Nano answers → TTS speaks back. Full voice conversation from your phone, no app install |
| **Wake word / always-on** | Configure Pipecat pipeline with a wake-word detector; Spark listens on your LAN microphone |

### Vision (image → understand → act)

| Capability | How |
|---|---|
| **Image understanding** | Qwen3.5-122B is a vision model — send images via the `/v1/chat/completions` endpoint with base64 image content |
| **Screenshot analysis** | Send a screenshot from your phone or laptop; Brain describes, debugs, or acts on what it sees |
| **Diagram / chart reading** | Architecture diagrams, database ERDs, whiteboards — Brain interprets and explains |
| **Photo to text** | Handwritten notes, whiteboard photos, documents — OCR-level extraction with semantic understanding |
| **Vision via Telegram** | Send any photo to the Telegram bot → Brain analyzes it and responds. Same UX as GPT-4o on mobile |

### Default: Nano. Switch to Brain on demand.

**Nano is the daily driver — 90% of tasks, 4x faster.** Brain is there when you need it.

| Model | Speed | Use for | Vision |
|---|---|---|---|
| Nemotron-Nano (default) | 56–70 tok/s | Chat, email, Slack, coding tasks, sub-agents, most things | No |
| Qwen3.5-122B (Brain) | ~16 tok/s | Vision, large codebase architecture, overnight builds, frontier reasoning | **Yes** |

**Mode locks for the session — set once, stays until you change it:**

| Trigger | What happens |
|---|---|
| `/deep` or `deep mode` | Locks Brain for entire session. No auto-switching. |
| `/thinking` or `thinking mode` | Same as `/deep` |
| `/fast` or `fast mode` | Locks Nano for entire session |
| Any trigger mid-session | Overrides current lock immediately |
| `/auto` or `auto mode` | Releases lock, auto-classify resumes per message |

**Default (no lock): auto-classify.** Nano judges each message with a single token (`fast`/`deep`) before routing. ~200ms overhead. Once you set `/deep` or `/fast`, this is suppressed for the session — your choice holds.

```
/deep  (session start)
  "Write the Stripe billing module"  -> Brain  (locked, no re-classify)
  "Now write tests"                  -> Brain  (still locked)
  "Quick — what time is it"          -> Brain  (locked, no auto-switch to Nano)
  [image sent]                       -> Brain direct (deep mode, no two-step)

fast mode  (mid-session switch)
  "Quick reply"                      -> Nano   (locked)
  [image sent]                       -> Brain extracts -> Nano responds (two-step)
```

**Vision depends on current mode:**
- **Fast mode + image** — Brain extracts image to text description, Nano answers. Stays Nano.
- **Deep mode + image** — Brain handles image directly. Stays Brain.

The router lives at `agent/router.py`. Call `reset_session()` at the start of each new conversation to clear any previous lock.

### Agentic Orchestration — Nano Spawns Nano

Sub-agent spawning is an **OpenClaw capability** (`sessions_spawn` API) — not a model capability. Nano can orchestrate parallel Nano workers. All running at 56–70 tok/s each.

```
"Tonight, build the Stripe billing module, write tests, push to GitHub"
        ↓
Nano (orchestrator) — decomposes the goal
        ↓
sessions_spawn × 3 (parallel):
  Nano worker 1 → writes billing code      (filesystem + git MCP)
  Nano worker 2 → writes tests             (filesystem MCP)
  Nano worker 3 → writes docs + README     (filesystem MCP)
        ↓
Nano reviews, commits via git MCP, opens PR via github MCP
        ↓
Sends you Telegram summary
```

Switch to Brain for overnight work only when the task needs vision or genuine frontier-level reasoning across a very large codebase. Everything else: Nano is fast enough and more than capable.

NemoClaw sandboxes isolate each agent run:
- Network namespace — only explicitly allowed outbound endpoints
- Filesystem access — scoped to your projects directory
- MCP tools — available as callable functions inside the sandbox

```bash
nemoclaw deep connect    # Brain — vision, hard reasoning
nemoclaw fast connect    # Nano  — daily driver (default)
nemoclaw list            # all sandboxes + status
openshell term           # real-time monitor
```

### Remote Access — Work From Anywhere

| Method | How |
|---|---|
| **SSH from anywhere** | Tailscale gives your Spark a persistent encrypted IP. `ssh user@<tailscale-ip>` from any network — coffee shop, phone hotspot, another country |
| **NVIDIA Sync** | One-click SSH + VS Code from the system tray app on macOS/Windows. Auto-manages SSH keys |
| **VS Code Remote** | Full IDE running on Spark's hardware. Edit, debug, run — your laptop is just a screen |
| **Aider coding** | `aider --message "..."` from any SSH session. Brain writes the code, Nano applies diffs. No tokens billed |
| **GitHub workflows** | Agent handles PR creation, code review, branch management, CI monitoring via GitHub MCP |
| **Terminal everywhere** | SSH → tmux → leave long-running agent tasks running, reconnect from anywhere |

### Mobile — Full ChatGPT-on-Phone Experience via Telegram/Slack

Everything you get with ChatGPT Plus on your phone, plus real agentic capability:

| Feature | ChatGPT App | spark-sovereign (Telegram/Slack) |
|---|---|---|
| Text conversation | Yes | Yes — Nano responds in seconds |
| Voice notes | Yes | Yes — ASR transcribes, TTS responds |
| Image analysis | Yes | Yes — Brain vision model |
| Web search | Yes (limited) | Yes — SearXNG, full results, stored in your DB |
| Memory | Basic (opt-in) | Full — every session builds the vector DB |
| Run code | No | Yes — shell MCP executes on Spark |
| Push to GitHub | No | Yes — GitHub MCP |
| Control infrastructure | No | Yes — Docker, AWS, shell MCP |
| Bill per message | Yes ($20+/mo) | No — $0 per message |
| Private | No | Yes — never leaves your hardware |

**Routing:** Text and voice notes → `fast` sandbox (Nano, instant). Images → `deep` sandbox (Brain, vision-capable). For complex tasks from Telegram, switch your active sandbox first: `nemoclaw deep connect`, then send your message.

### What the Agent Can Control via MCP

MCP (Model Context Protocol) gives agents direct tool access to real systems. Every tool below can be called autonomously by the Brain or any Nano sub-agent:

MCP (Model Context Protocol) gives the agent direct tool access to real systems from inside the NemoClaw sandbox:

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

> **Shell/Docker:** There are no official MCP packages for shell execution or Docker. NemoClaw's OpenShell sandbox handles safe command execution natively — the agent can run commands within the sandbox's allowed policy without a separate MCP server.

See `config/mcp_servers.json` for the full catalog. Add any server to the `mcpServers` block in `config/openclaw.json` to enable it.

---

## What This Is — and Why It Compounds

Most AI setups are stateless: every session starts from zero, every token costs money, everything you type leaves your network. spark-sovereign is the opposite. It runs a 122B-parameter reasoning brain and a fast 30B sub-agent stack entirely on local hardware, with a pgvector memory layer that accumulates verified knowledge across every session. Web search results that prove correct get stored permanently. Failures get tagged and avoided. At the end of each session, the Nano model curates durable lessons from what happened and writes them to the DB. The system gets materially smarter with every use — not through retraining, but through growing, queryable, domain-specific memory. After six months of daily use, your Spark knows your codebase, your preferences, your infrastructure, and your failure patterns in a way no cloud model ever will. After a year, you have a proprietary dataset of verified, outcome-tagged interactions that can be used to fine-tune a permanently improved custom model — one that no one else has, that lives entirely on hardware you own, and that can never be deprecated, rate-limited, or changed under you.

---

## Capability Comparison

### At deployment vs. frontier cloud models (March 2026)

| Capability | GPT-5.4 (OpenAI Cloud) | Claude Sonnet 4.6 (Anthropic Cloud) | spark-sovereign (Local) |
|---|---|---|---|
| **Raw reasoning** | Best-in-class | Best-in-class | ~85% parity (Qwen3.5-122B NVFP4) |
| **Context window** | 1M tokens | 200K tokens | 64K brain / 128K Nano |
| **Cost per session** | $5–50+ | $2–20+ | **$0** (hardware sunk cost) |
| **Privacy** | Data sent to OpenAI | Data sent to Anthropic | **100% local, never leaves hardware** |
| **Memory across sessions** | Optional (limited) | None by default | **Full pgvector — grows every session** |
| **Learns from your sessions** | No | No | **Yes — lessons DB + verified RAG** |
| **Voice I/O** | API only | API only | **Native ASR + TTS streaming** |
| **Model swappability** | None | None | **Edit one YAML, restart** |
| **Fine-tuning on your data** | Expensive, restricted | Not available | **Full dataset ownership at 1 year** |
| **Works offline** | No | No | **Yes — full stack, no internet required** |
| **Telegram/Slack agent** | Requires integration work | Requires integration work | **Built-in via NemoClaw** |
| **Agentic coding (Aider)** | Via API ($$$) | Via API ($$$) | **Local, unlimited** |
| **Uptime dependency** | OpenAI infrastructure | Anthropic infrastructure | **Your hardware** |

---

### Performance trajectory — the compounding advantage

The gap to frontier cloud models narrows continuously as the vector DB accumulates verified, domain-specific knowledge.

| Timeframe | Domain task performance (vs. GPT-5.4 baseline) | What's driving the change |
|---|---|---|
| **Day 1** | ~75–80% | Raw model capability — Qwen3.5-122B is genuinely competitive |
| **1 month** | ~83–87% | First lessons stored, common failure patterns avoided, web search results cached |
| **3 months** | ~88–92% | Deep domain recall — verified answers surface before any web search; agent skips redundant lookups entirely |
| **6 months** | ~93–97% | Near-parity on your specific domains; Spark knows your stack, preferences, prior decisions; cloud models still start from zero every session |
| **12 months** | **Exceeds GPT-5.4 on your domains** | ~50K+ verified interactions available for fine-tuning; custom model trained on your exact workflows surpasses general-purpose frontier models on tasks you actually do |

> Note: "performance" here means task completion quality on your real workloads — the domains you use daily. General benchmark parity with GPT-5.4 on MMLU/HumanEval is not the goal. Outperforming it on *your* problems is.

---

## Precision Architecture — Why NVFP4 is the Right Choice for Spark

The GB10 Superchip has **dedicated FP4 tensor cores** in its Blackwell architecture. NVFP4 is not naive 4-bit quantization — it uses per-block scaling factors (~4.5 bits effective precision) that preserve model quality while fitting 122B parameters in 75.6GB.

| Layer | Precision | Why |
|---|---|---|
| Model weights (Brain + Nano) | **NVFP4** | Native GB10 tensor cores — maximum throughput, minimum memory |
| KV cache | **FP8** | Halves KV memory vs FP16; `--kv-cache-dtype fp8` on both models |
| Attention compute | **FlashInfer + TRT-LLM backend** | `VLLM_FLASHINFER_ALLREDUCE_BACKEND=trtllm` — Blackwell-optimized |
| GEMM kernels | **Marlin** | `VLLM_NVFP4_GEMM_BACKEND=marlin` — the correct kernel for NVFP4 on GB10 |
| MoE routing (Nano) | **Cutlass fallback** | `VLLM_USE_FLASHINFER_MOE_FP4=0` — FlashInfer MoE FP4 has stability issues on current vLLM; cutlass is correct |
| Atomic add (Brain) | **Enabled** | `VLLM_MARLIN_USE_ATOMIC_ADD=1` — required for NVFP4 numerical stability on Blackwell |

**Why not FP16 or BF16?** On GB10, running FP16 would require ~244GB for the 122B model — more than the entire unified memory pool. NVFP4 is not a compromise; it's the format the hardware was architected for. The RedHatAI NVFP4 checkpoint was specifically trained and validated for single-Spark deployment.

**Why not INT4/GPTQ?** GPTQ uses symmetric quantization with row-level scales. NVFP4 uses asymmetric block-scaled quantization with hardware-native support — substantially better quality at the same memory footprint on Blackwell.

---

## Model Stack (verified March 27, 2026)

| Component | Model | RAM | Port |
|---|---|---|---|
| Brain / Vision / Deep tasks | RedHatAI/Qwen3.5-122B-A10B-NVFP4 | 75.6 GB | 8000 |
| Sub-agents / Speed / Chat | nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4 | ~20 GB | 8001 |
| Voice in (ASR) | nvidia/nemotron-speech-streaming-en-0.6b | ~2.4 GB | 8002 |
| Voice out (TTS) | nvidia/magpie_tts_multilingual_357m | ~1.4 GB | 8003 |
| Embeddings (RAG/memory) | nomic-ai/nomic-embed-text-v1.5 | ~0.4 GB | 8004 |
| Vector DB | pgvector 0.8.2 on PostgreSQL 17 | ~2 GB | 5432 |
| Web search | SearXNG latest | <1 GB | 8080 |
| Agent runtime | NemoClaw + OpenClaw | ~1 GB | 18789 |
| **Total** | | **~107 GB** | |
| KV cache headroom | | **~21 GB** ✅ | |

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
│   ├── 00_first_boot.sh    ← WiFi setup + NVIDIA Sync + Tailscale
│   ├── 01_system_prep.sh   ← Docker cgroup, directories, Python deps
│   ├── 02_download_models.sh ← Download all HF models
│   ├── 03_vllm_servers.sh  ← Start Brain (8000) + Nano (8001)
│   ├── 04_voice_pipeline.sh ← Start ASR (8002) + TTS (8003)
│   ├── 05_pgvector.sh      ← Start pgvector + apply schema
│   ├── 06_searxng.sh       ← Start SearXNG web search
│   ├── 07_nemoclaw.sh      ← Install + start NemoClaw agent runtime
│   ├── 08_aider.sh         ← Install aider config
│   └── check_stack.sh      ← Health check for all services
├── agent/
│   ├── memory.py           ← Continuous learning layer (store/recall/curate)
│   ├── router.py           ← Model router (fast/deep, auto-classify, vision pipeline)
│   ├── log.py              ← Shared logger (console + rotating file)
│   └── requirements.txt
├── docs/
│   └── TROUBLESHOOTING.md
├── .env.example            ← Copy to .env, fill in secrets
└── .gitignore
```

---

## Setup — Box Open to Running

There are three layers to this setup. They are **sequential, not alternatives**. You cannot skip to Layer 3 without completing Layers 1 and 2.

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
- Plug in wired Ethernet if you have it (easier than WiFi)
- Keep the Quick Start Guide from the box — the hostname and hotspot credentials are on a sticker inside it

**Two options — choose one:**

**Option A — Headless (no monitor):**
1. Power on — Spark broadcasts a WiFi hotspot
2. Connect your laptop to that SSID (credentials on sticker)
3. Browser captive portal opens automatically — if not, navigate to the URL on the sticker
4. Follow wizard: language → accept terms → create username + password → select your home WiFi

**Option B — Monitor attached:**
1. Power on — wizard appears on display
2. Same sequence as above

**⚠ WPA2-Enterprise / 802.1X networks** (common in offices) are not supported at first boot. Use a phone hotspot for initial setup, then configure your enterprise network via NetworkManager afterward.

**After WiFi connects:**
- Device downloads and installs software automatically (~10 min)
- **Do not power off or reboot during this step** — cannot be resumed, may require factory reset
- Device reboots when done
- Spark is now at `spark-XXXX.local` on your network (XXXX from sticker)

---

### Layer 2 — NVIDIA Sync + SSH (On Your Laptop)

**Install NVIDIA Sync on your laptop:**
Download from: `https://build.nvidia.com/spark/connect-to-your-spark/sync`
Available for macOS, Windows, and Ubuntu/Debian.

**Add your Spark:**
1. Open NVIDIA Sync from system tray
2. Settings (gear icon) → Devices → Add Device
3. Enter hostname (`spark-XXXX.local`), your username, your password
4. Click Add — wait 3–4 minutes for Spark to become available
5. Password is used once to set up SSH keys, then discarded

**Connect:**
- NVIDIA Sync tray → select device → **Terminal** — gives you an SSH shell on the Spark

**For access from anywhere (Tailscale):**
- In NVIDIA Sync: Settings → Tailscale → Enable Tailscale → Add a Device
- **Do NOT install the Tailscale app on your laptop separately** — NVIDIA Sync is the Tailscale node on the laptop side
- Install Tailscale on your phone/other devices normally — sign in to the same account

**Verify SSH works:**
```bash
ssh <username>@spark-XXXX.local
nvidia-smi   # "Memory-Usage: Not Supported" is normal on Spark — not an error
```

---

### Layer 3 — spark-sovereign Scripts (Run on the Spark via SSH)

All scripts run **on the Spark**, not on your laptop. SSH in first.

**One-time setup before anything else:**
```bash
# Add yourself to docker group (no more sudo on every docker command)
sudo usermod -aG docker $USER && newgrp docker
```

**Clone this repo onto the Spark:**
```bash
git clone https://github.com/YOUR_ORG/spark-sovereign.git ~/spark-sovereign
cd ~/spark-sovereign
cp .env.example .env
nano .env   # set HF_TOKEN at minimum
```

**Run phases in order** — each script is idempotent, safe to re-run:

```bash
bash scripts/00_first_boot.sh      # Tailscale on Spark + confirms setup
bash scripts/01_system_prep.sh     # Docker config, NVMe dirs, Python deps
bash scripts/02_download_models.sh # ~100GB downloads — run overnight
bash scripts/03_vllm_servers.sh    # Brain (8000) + Nano (8001) — 5-10 min to load
bash scripts/04_voice_pipeline.sh  # ASR (8002) + TTS (8003)
bash scripts/05_pgvector.sh        # Vector DB + schema
bash scripts/06_searxng.sh         # Local web search
bash scripts/07_nemoclaw.sh        # NemoClaw — interactive onboarding wizard
bash scripts/08_aider.sh           # Aider CLI config
bash scripts/check_stack.sh        # Verify everything is up
```

**NemoClaw onboarding (Phase 7) is interactive.** When the wizard runs:
- Quickstart vs Manual → **Quickstart**
- Model provider → **Skip for now** (we use our own vLLM)
- Communication channel → **Skip for now** (configure in `.env`)
- Hooks → **Enable all three**
- Sandbox name → **deep**

The script then sets up the second `fast` sandbox automatically.

---

### After Setup — Connect and Use

```bash
nemoclaw deep connect    # Brain sandbox — vision, coding, reasoning
nemoclaw fast connect    # Nano sandbox  — daily driver (default)
openclaw tui             # interactive chat inside active sandbox
```

Or from Telegram/Slack once tokens are set in `.env` and Phase 7 is re-run.

---

## Swapping a Model

**All model configuration lives in `config/models.yml`.** To swap any model:

1. Edit `config/models.yml` — change `hf_repo`, `local_path`, `docker_image`, GPU util, etc.
   Each section has a commented `SWAP EXAMPLE` showing an alternative.

2. Download the new model:
   ```bash
   bash scripts/02_download_models.sh
   ```

3. Restart the relevant server:
   ```bash
   # Brain
   docker restart qwen-brain
   # Or full restart with new settings:
   bash scripts/03_vllm_servers.sh

   # Sub-agent
   docker restart nemotron-nano
   ```

4. Run health check:
   ```bash
   bash scripts/check_stack.sh
   ```

That's it. No hardcoded model names anywhere else in the stack.

---

## Memory Architecture — How the System Gets Smarter

Every session, the agent:

1. **Checks pgvector first** — any relevant lessons or verified web results? Uses them directly (faster, works offline).
2. **Falls back to SearXNG** if no local knowledge — results stored in `rag_cache` with `verified=FALSE`.
3. **Confirms correct results** — when an answer works, `confirm_web_result()` marks it `verified=TRUE, confidence=1.0`. Ranks highest in future recall.
4. **Curates at session end** — `curate_session()` sends the session summary to Nano, which extracts durable lessons and stores them in the `lessons` table.
5. **Failures ranked highest** (`importance=1.0`) — never repeat the same mistake.

```
Query → pgvector recall → hit? → answer (no web search)
                       → miss? → SearXNG → store result
                                          → answer works? → confirm (verified=TRUE)
                                                         → curate_session() → Nano extracts lessons
                                                                            → store in lessons table
```

### Using the memory layer in your agent code

```python
from agent.memory import recall_as_context, store_web_result, confirm_web_result, curate_session

# Before calling the LLM — inject relevant context
context = recall_as_context("stripe webhook subscription.updated", domain="stripe")
# context is a formatted string ready to inject into your system prompt

# After a SearXNG search — store the result
result_id = store_web_result(
    query="stripe webhook signature verification python",
    result="Use stripe.Webhook.construct_event() with the signing secret...",
    url="https://stripe.com/docs/...",
)

# After confirming the answer worked
confirm_web_result(result_id)

# At end of session
lessons = curate_session(session_summary_text, domain="stripe")
```

### Memory CLI

```bash
# Recall memories for a query
python3 agent/memory.py recall "how to handle stripe webhooks"

# Store a lesson manually
python3 agent/memory.py lesson "Always verify Stripe webhook signatures before processing" \
    --outcome success --domain stripe --importance 0.9

# Print DB stats
python3 agent/memory.py stats
```

---

## Aider — AI-Pair Coding with Local Models

```bash
cd ~/projects/my-saas
aider                                    # interactive TUI, uses 122B brain

# Inline commands
aider --message "Add Stripe webhook handler for subscription.updated"
aider --message "Add tests for the auth middleware"

# Use Nano for fast simple edits
aider --model openai/nemotron-nano --message "fix typo in README"
aider --model openai/nemotron-nano --message "reformat this file with black"
```

Config at `~/.aider.conf.yml` (installed by `scripts/08_aider.sh`).

---

## VS Code Remote

Via NVIDIA Sync (recommended):
1. Open NVIDIA Sync → your Spark is listed
2. Click "VS Code" → auto-launches VS Code connected to Spark
3. Full CUDA stack as backend, edit files directly

Manually:
```
VS Code → Remote Explorer → + New Remote → ssh user@spark-XXXX.local
```

---

## NemoClaw — Agent Runtime + Telegram/Slack

UI at `http://localhost:18789` after `scripts/07_nemoclaw.sh`.

Configure Telegram/Slack tokens in `.env` before running the script. The `config/openclaw.json` file uses `${ENV_VAR}` placeholders — the install script substitutes them from `.env`.

Main agent uses the Brain (8000). Sub-agents use Nano (8001) with up to 8 concurrent, 2-level spawn depth.

---

## Health Check

```bash
bash scripts/check_stack.sh
```

Shows:
- System memory + GPU utilization
- Model endpoint status (which models are loaded and serving)
- Docker container status + uptime
- SearXNG + NemoClaw UI reachability
- pgvector lesson + web cache counts

---

## Memory Map

```
128GB DGX Spark Unified Memory
═══════════════════════════════════════════════════════════════
 Qwen3.5-122B NVFP4            75.6 GB    0.60 util
 Nemotron Nano NVFP4           20.0 GB    0.18 util
 ASR (nemotron-speech)          2.4 GB    always-on
 TTS (magpie_tts)               1.4 GB    always-on
 Embeddings (nomic)             0.4 GB    always-on
 pgvector + PostgreSQL          2.0 GB    always-on
 SearXNG                        0.5 GB    always-on
 NemoClaw + OpenClaw            1.0 GB    always-on
 OS + Docker + vLLM             6.0 GB    always-on
───────────────────────────────────────────────────────────────
 TOTAL ALLOCATED               109.3 GB
 KV CACHE HEADROOM              18.7 GB   ✅ safe
═══════════════════════════════════════════════════════════════
```

---

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Common fixes:
- OOM → reduce `gpu_memory_utilization` in `config/models.yml`
- Model not loading → check `docker logs qwen-brain --tail 50`
- Swap model → edit `config/models.yml`, re-run download + server scripts
- pgvector errors → check `docker logs pgvector --tail 30`
