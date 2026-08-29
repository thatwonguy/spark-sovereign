# spark-sovereign

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-NVIDIA_DGX_Spark-76B900?logo=nvidia&logoColor=white)](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
[![OpenClaw](https://img.shields.io/badge/agentic_layer-OpenClaw-blueviolet?logo=lobster&logoColor=white)](https://github.com/openclaw/openclaw)
[![Model](https://img.shields.io/badge/model-Qwen3.8--27B--NVFP4-orange)](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)
[![Speed](https://img.shields.io/badge/speed-23.9_tok%2Fs_(agentic--measured)-yellow)](config/models.yml)
[![Privacy](https://img.shields.io/badge/privacy-100%25_local-critical)](README.md)

**Your AI. Your hardware. Your rules.**

A fully self-contained, private AI stack running on the **NVIDIA DGX Spark** (128GB unified memory, GB10 Superchip, ~$4,000–$5,000 as of March 2026).

No cloud. No API keys. No rate limits. No surveillance. No subscriptions. No data leaving your machine. Ever.

Brain serves a standard **OpenAI-compatible API** — any agentic framework that speaks this protocol works out of the box. We test with [OpenClaw](https://github.com/openclaw/openclaw), but you can plug in LangChain, AutoGen, CrewAI, Open Interpreter, LobeChat, or anything else. The infrastructure layer doesn't care what's on top.

---

## Install

Get an SSH shell on your Spark ([how](#layer-2--nvidia-sync--ssh-on-your-laptop)), then paste this:

```bash
curl -fsSL https://raw.githubusercontent.com/thatwonguy/spark-sovereign/main/install.sh | bash
```

A guided setup wizard starts. It checks the machine, asks two optional
questions, and then does about 40 minutes of unattended work. You do not need
to know what Docker, vLLM, or a model weight is to get to the end of it.

Prefer to read before you run — always a reasonable instinct with a piped
installer:

```bash
curl -fsSL https://raw.githubusercontent.com/thatwonguy/spark-sovereign/main/install.sh -o install.sh
less install.sh
bash install.sh
```

The installer only fetches this repo at its latest release tag and hands over to
[`scripts/wizard.sh`](scripts/wizard.sh). Everything it runs afterwards is a
script in `scripts/` that you could equally run by hand — see
[Setup](#setup--box-open-to-running) for the manual sequence.

> Already have the repo cloned? `bash scripts/wizard.sh` is the same wizard.
> Interrupted partway through? Run it again — every step is idempotent and it
> resumes.

---

## Why This Exists

Proprietary frontier models come with strings attached — rate limiting, usage-based pricing, mass data collection, content moderation that blocks legitimate work, and terms of service that change without notice. You don't own anything. You're renting access to someone else's computer, on their terms.

The open-source community has been closing the gap fast. Models available today for private, local use are approaching — and in some benchmarks surpassing — proprietary alternatives. The hardware to run them is now available at consumer price points.

**spark-sovereign** is the bridge: a working, tested, production-ready setup that takes a DGX Spark from box-open to a fully operational private AI server — with CLI coding, chat, Telegram communication, voice, agentic tool use, multimodal input, web search, memory, and MCP integrations — all running locally.

This is for anyone who wants to **own their AI infrastructure** instead of renting it.

This setup lets you pick the best available open-weight model, serve it locally on your own 24/7 hardware, and point OpenClaw at it for full agentic capabilities. The only thing outside your control is electricity. Your AI stays up as long as you can pay the power bill. Use it to your heart's content — and as more intelligent, faster models become available, swap them in and instantly gain speed and intelligence boosts, with the VRAM limits of your Nvidia-CUDA optimized hardware.

---

## What You Get

**TLDR:** As of August 2026, this setup is a practical replacement for Claude Code and ChatGPT Codex for day-to-day engineering work. CLI coding, agentic tool use, parallel agents, chat, voice, Telegram, MCP integrations, **native image input** — all running locally, 24/7, with zero API dependency. An engineer can go fully off-grid and still get professional work done. Currently running Qwen3.8-27B NVFP4 — dense multimodal, 262K context, slower than the previous MoE but more capable per token.

- **~24 tokens/sec** on agentic coding, ~17 on open-ended prose — single-stream, measured, 256-token generation on an idle Spark (speculative decoding with a DSpark drafter; the gain is workload-dependent — see [Benchmarks](#benchmarks) and `docs/BENCHMARKS.md`). Slower than v4.2.1 (~53 tok/s FP8 MoE) — see the [Model Evolution](#model-evolution) trade below.
- **262K context window** — long conversations, full codebase analysis, deep reasoning
- **Native vision** — send images directly to Brain (up to 10 per prompt); dense multimodal model, no separate vision encoder
- **Agentic coding** — tool calling, code execution, file management, web search
- **Parallel agents** — OpenClaw spawns multiple workers for complex tasks simultaneously
- **Voice I/O** — speak to it, it speaks back (local Whisper STT, configurable TTS)
- **Telegram bot** — message your AI from your phone, send voice notes, images, text
- **Persistent memory** — remembers across sessions, learns your codebase and preferences
- **MCP tools** — git, GitHub, browser, shell, databases, Slack, Stripe, and more
- **Auto-start on boot** — plug in power, walk away, it's ready in 5 minutes
- **~55 GB of 128 GB unified memory** reserved by vLLM at `gpu_memory_utilization: 0.45` — leaves ~55 GB free for other workloads on the same Spark

### How This Compares (August 2026 — Honest Assessment)

|  | **spark-sovereign** (Qwen3.8-27B NVFP4) | **Claude Code** (Opus 4.8) | **ChatGPT Codex** (GPT-5.6 Sol) |
|---|---|---|---|
| **Speed** | ~24 tok/s on agentic coding, ~17 on prose, zero network latency | Variable — depends on server load and queue | Variable — depends on server load and queue |
| **Coding** | Strong — handles day-to-day engineering, debugging, refactoring, and generation | Best-in-class for complex multi-step coding | Strong, comparable to Claude on most tasks |
| **Hard reasoning** | Good for most tasks; frontier models still lead on the hardest problems | Strongest on complex architectural reasoning | Strong, especially on math and long-chain logic |
| **Agentic** | Full — parallel agents, tool calling, MCP, code execution via OpenClaw | Full — native tool use, computer use | Full — native tool use, code interpreter |
| **Vision** | Native — up to 10 images per prompt, no separate encoder | Native | Native |
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

**The honest take:** On **coding**, this model punches genuinely hard. Qwen3.8-27B posts **79.0% on QwenSWEBench, 61.7% on SWE-Bench Pro, 90.3% on LiveCodeBench v6, 73.0 Terminal-Bench 2.1, 84.3% OSWorld-Verified, and 89.2% GPQA Diamond** — numbers competitive with Opus 4.6-era flagships and Sonnet 4.6 / GPT-5.6 Terra on the code axis, and ahead of them on several agentic-execution and computer-use benchmarks. **Opus 4.8** and **GPT-5.6 Sol** still lead on the very hardest architectural reasoning and pure-knowledge questions — that gap is real, and shows up on cross-repo refactors and open-ended research. But for the daily work of a professional engineer — writing code, debugging, tool use, PR review, agent orchestration, image analysis — this is not a toy. It's a serious daily driver that a self-respecting developer can absolutely 5–10× themselves with, especially once you factor in **24/7 availability, zero rate limits, unlimited context reuse, parallel agents, and total privacy**. The ~17 tok/s throughput is slower than cloud APIs but not disabling for interactive work.

**What you're trading:** the current model is a deliberate speed-for-capability swap from the previous MoE baseline — **~3× slower decode (~17 vs ~53 tok/s), in exchange for native multimodal input (text + images + video, up to 10 images per prompt), a 27B dense reasoning core, and 262K native context.** If sustained single-stream throughput matters more to you than vision + dense reasoning, `git checkout v4.2.1` puts you on the faster MoE unchanged — see [Model Evolution](#model-evolution).

The gap to frontier models is closing fast. Every few weeks a new open-weight model drops that's smarter or faster than the last. This hardware will only get more capable over time.

---

## Model Evolution

We tested multiple models to find the best intelligence-to-speed ratio on Spark hardware. The open-source ecosystem moves fast — what was best last month gets surpassed the next.

| Release | Model | Architecture | Active Params | tok/s | Vision | Status |
|---|---|---|---|---|---|---|
| v1.0 | Qwen3.5-27B-FP8 | Dense | 27B | ~14–30 | No | Too slow — hit memory bandwidth ceiling |
| v2.0 | Nemotron-3-Nano-30B-A3B-FP8 | MoE | 3B | ~35–45 | No | Fast but weaker on coding/reasoning |
| v3.0 | Qwen3.5-35B-A3B-FP8 | MoE | 3B | ~49 | No | Retired — superseded by v4.0 |
| **v4.2.1** | **Qwen3.6-35B-A3B-FP8** | **MoE + DeltaNet** | **3B** | **~53** | **No** | **Prior baseline — fastest measured. Available via `git checkout v4.2.1`** |
| v5.0 | Qwen3.8-27B-NVFP4 | Dense multimodal | 27B | ~17 | Yes | Traded speed for vision + higher intelligence per token |
| v5.1 | Qwen3.8-27B-NVFP4 | Dense multimodal | 27B | ~17 | Yes | Superseded by v5.2 — hardened stack: loopback bind, auto-provisioned API key, persisted compile cache |
| v5.2 | Qwen3.8-27B-NVFP4 | Dense multimodal | 27B | ~17 | Yes | Superseded by v5.3. MTP draft length 5 → 3, measured across 15 configs. Output-preserving |
| v5.3 | Qwen3.8-27B-NVFP4 | Dense multimodal | 27B | ~24 agentic / ~17 prose | Yes | **Last tagged release.** DSpark drafter replaces MTP heads: +21.6% on agentic work, output unchanged. See #20 |
| **`main`** | **Qwen3.8-27B-NVFP4** | **Dense multimodal** | **27B** | **~24 agentic / ~17 prose** | **Yes** | **Current — this is what runs on our Spark. Same model and serving parameters as v5.3, plus the setup-script fixes below. Deploy this** |

**There is no tag newer than v5.3, and that is deliberate.** Tags briefly existed above it and were withdrawn as not stable enough to hand anyone. Rather than mint another version number, `main` is the deploy target and is kept as the thing actually running on our Spark.

Nothing on top of v5.3 touches the model or how it is served — every commit is a fix to the scripts that install it. The ones that matter if you are deploying:

- `02_download_models.sh` could have its destructive prompts answered by the remaining lines of a pasted command block, and delete model weights. It now reads from the terminal, never prompts when it cannot ask, and says why when it deletes without asking. It also offers an archived copy before re-downloading ~22 GB, and no longer prunes the drafter it was still using.
- `01_system_prep.sh` pins `huggingface_hub >= 1.0`, without which the `hf` CLI that phase 2 depends on does not exist.
- `03_vllm_servers.sh` hands the generated API key to OpenClaw directly instead of printing it and hoping it gets pasted.

v5.3 predates all of it. If you need a pinned tag for reproducibility it still works, but expect the download phase to behave as described above.

**v5.0 is a deliberate speed-for-capability trade.** The dense Qwen3.8-27B moves every one of its 27B parameters through the Spark's ~273 GB/s memory bus on every token, versus v4.2.1's MoE that only touched 3B active. NVFP4 4-bit weights help but don't close a ~9× active-compute gap — we measured ~17 tok/s clean-idle vs ~53 tok/s for the MoE. (v5.2 later recovered part of that with speculative-decoding tuning, to ~17 tok/s; the non-speculative floor is a measured 12 tok/s.) We kept v5.0 because it adds native image input (up to 10 per prompt), the dense architecture gives more coherent per-token reasoning, and 262K context is preserved. For workloads where sustained throughput matters more than vision, `git checkout v4.2.1` restores the faster MoE stack unchanged.

The current model (Qwen3.8-27B) is a dense NVFP4 build quantized by Unsloth specifically for Blackwell (SM12.1) hardware. Native 262K context, integrated vision encoder, `qwen3_coder` tool-call parser, `qwen3` reasoning parser, and MTP (Multi-Token Prediction) speculative-decoding heads shipped with the checkpoint.

**The 27B is staying for now.** The obvious next step was Qwen3.8-Flash-Next, and we spent three attempts on it. It is not a configuration problem: the 125B MoE is NVFP4 and fits, but the 51B n-gram embedding table ships unquantized, and `VLLM_PLE_CPU_OFFLOAD` does nothing on a Spark because the 128 GB is unified — "offload to host" moves bytes within the same pool. The third attempt does run, by memory-mapping that table from NVMe instead of trying to shrink it. It is not something we are willing to put in front of anyone yet, so the 27B remains the deployed model until there is a build worth shipping.

That work is kept on the `brain-flash-next-eval` branch rather than merged, along with its write-up as Lesson #21 — including the fit check that returned CLEAR and cost a 170 GiB download. Nothing about it is deployed, and nothing here depends on it.

For the full build journey and every decision made, see [docs/LESSONS.md](docs/LESSONS.md) — Lesson #16 covers the v4.2.1 → v5.0 trade in detail, and Lesson #17 covers the v5.1 hardening pass.

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

| Component | Model | Weights | Port | tok/s (measured) | TTFT |
|---|---|---|---|---|---|
| **Brain** | unsloth/Qwen3.8-27B-NVFP4 | ~22 GB (NVFP4 4-bit) | 8000 | ~24 agentic / ~17 prose | ~255–397 ms |

**Key specs:**
- Dense 27.78B params, multimodal — every token touches all 27B params (see [Model Evolution](#model-evolution) for why speed is 3× slower than v4.2.1)
- Native **text + images + video** input — up to 10 images per prompt via `limit_mm_per_prompt`
- `vllm/vllm-openai:qwen38-arm64-cu130` — arm64 build for GB10, includes the vLLM version that handles the Qwen3.8 architecture and MTP speculative decoding
- `qwen3_coder` tool parser + `qwen3` reasoning parser
- NVFP4 4-bit weights + FP8 KV cache
- `gpu_memory_utilization: 0.45` (~55 GB reserved by vLLM — ~22 GB weights + ~33 GB KV cache, ~55 GB free for OS / Docker / other workloads)
- 262K native context
- MTP speculative decoding at `num_speculative_tokens: 3` (ships in checkpoint, no draft model needed) — **verified live, 64.4% acceptance; 5 was measurably worse, see below**
- Prefix caching enabled — fast repeated prompts

Benchmark it yourself: `bash scripts/benchmark.sh quick` (single-stream TTFT + decode tok/s from the running Brain).

**On the throughput number — answered, 2026-08-26.**
Measured across 15 serving configurations; full detail in `docs/LESSONS.md` #18.

The old 15–17 tok/s was a **mistuned draft length**, not a hardware wall and not
a broken serving path. `num_speculative_tokens` shipped at 5, and 5 was the worst
of the three settings tested:

| MTP draft tokens | Decode | Acceptance |
|---|---|---|
| off | 12.04 tok/s | — |
| 2 | 18.47 tok/s | 60.3% |
| **3** *(current)* | **19.66 tok/s** | **64.4%** |
| 5 *(v5.0–v5.1)* | 15.18 tok/s | 39.5% |

Acceptance falls off with draft position and rejected tokens still cost their
verification pass — so longer is not better. Output is unchanged: speculative
decoding verifies every draft against the real model.

**The roofline is real, and it sits at 12 tok/s.** Non-speculative decode measures
12.04 tok/s, which against a measured 245 GB/s (not the 273 spec sheet) and ~23.4
GB of weights is the bandwidth limit almost exactly. Speculation is what beats it;
attention backend, KV dtype and utilisation moved decode by under 1% between them.

Treat the table as a **ranking**, not a guarantee — all four rows were measured
back-to-back under identical conditions. Absolute decode tracks acceptance, which
tracks the sampled continuation: re-measuring later gave 46.5% and 17.1 tok/s.
**Expect ~17 tok/s day to day.** Four runs measured 16.74, 17.06, 17.13 and 19.66; the 19.66 was the sweep, on an idle box with the watchdog stopped.

Decode is bandwidth-bound, so *aggregate* throughput rises with concurrency for
free: multi-stream figures like ~148 tok/s at 8 streams are ordinary batching and
say nothing about single-stream speed. This box does 108.9 tok/s at 8 streams.

To re-measure at any time:

```bash
bash scripts/benchmark.sh audit       # is prefix caching live? is 262K context reachable?
bash scripts/benchmark.sh bandwidth   # is the roofline real, or is the path moving too many bytes?
bash scripts/benchmark.sh quick       # decode + TTFT of whatever is running now
```

All but the last are read-only and safe against a running Brain.

To test configurations **systematically** rather than one at a time, run the
whole thing. One command audits, sweeps every configuration, verifies each one
actually took effect before trusting its numbers, and writes
[`docs/BENCHMARKS.md`](docs/BENCHMARKS.md):

```bash
bash scripts/benchmark.sh list   # show what would be tested
bash scripts/benchmark.sh        # run everything (hours; resumable; Brain is down)
```

It is **ad-hoc only** — nothing calls it, and it must never be added to the boot
sequence or watchdog. `docs/BENCHMARKS.md` is the durable answer to "what did we
already try, which numbers can be trusted, and what should we actually use" —
written to be read later by someone, or something, with no memory of this work.

The audit runs first because it can find something that makes the rest
moot. Two failures are reported for this model on this hardware and neither has
been checked here: vLLM silently disabling prefix caching despite the flag being
accepted (which makes every agent turn reprocess the whole conversation prefix),
and the default attention backend capping usable context far below the advertised
262K. A dead prefix cache costs more in real agentic use than any amount of
draft-token tuning wins back.

---

## Memory Map

Deliberately modest footprint — v5.0 reserves less than half the Spark's memory, leaving room for other services, dashboards, or dev containers to coexist on the same box.

```
128GB DGX Spark Unified Memory (121.69 GiB visible to CUDA)
===============================================================
 Qwen3.8-27B NVFP4 (Brain) ~55.0 GB   0.45 util (~22GB weights + ~33GB KV cache)
 OS + Docker + vLLM         6.0 GB    always-on
 OpenClaw + overhead        2.0 GB    always-on
---------------------------------------------------------------
 TOTAL ALLOCATED          ~63.0 GB
 HEADROOM                 ~58.7 GB   plenty for other Docker services on the same box
===============================================================
```

If you want to push more memory to KV cache for very-long-context workloads, raise `gpu_memory_utilization` in `config/models.yml` — every 0.05 buys ~6 GB more cache. This *won't* increase decode speed (that's bandwidth-bound), but it does allow larger batches and longer conversations.

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
Layer 3: spark-sovereign     — on the Spark, via SSH:

           00_first_boot.sh       Tailscale, environment sanity checks
           01_system_prep.sh      Docker, dirs, Python deps, systemd + watchdog
           02_download_models.sh  Pull weights to /opt/models
           03_vllm_servers.sh     Generate API key, start Brain, wait for ready
           04_voice_stt.sh        Optional — local Whisper STT

         then: openclaw onboard   Point it at the Brain, paste the API key
```

Run 00 through 03 in order. Every one is idempotent, so re-running after a
failure is safe. 04 is optional and only adds voice.

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

> **Most people should use the wizard instead** — see [Install](#install). It runs
> exactly the sequence below, and handles the docker group, the API key, and the
> `.env` file for you. What follows is the same thing done by hand, for when you
> want to see or change each step.

```bash
# One-time setup
sudo usermod -aG docker $USER && newgrp docker

# Clone and configure
git clone https://github.com/thatwonguy/spark-sovereign.git ~/spark-sovereign
cd ~/spark-sovereign
# Stay on main — it is what runs on our Spark, and it pins the model and every
# serving parameter in config/models.yml. v5.3 is the last tagged release and
# predates the download-phase fixes; see Model Evolution above before pinning it.
cp .env.example .env
nano .env   # set HF_TOKEN at minimum

# Run these scripts in order (idempotent, safe to re-run)
bash scripts/00_first_boot.sh      # Tailscale + confirms setup
bash scripts/01_system_prep.sh     # Docker config, dirs, Python deps, auto-start service, watchdog timer
bash scripts/02_download_models.sh # Downloads model → /opt/models (~22GB for the current NVFP4 build)
bash scripts/03_vllm_servers.sh    # Generates the API key, starts Brain on port 8000, waits until ready
bash scripts/04_voice_stt.sh       # Optional — local Whisper STT (~450MB)
```

That is the whole sequence. Everything else in `scripts/` is a helper the
system calls for you — `boot_sequence.sh` and `start_brain_ad_hoc.sh` run from
systemd, `watchdog.sh` from its timer — or a diagnostic you run when you want
it (`check_stack.sh`, `benchmark.sh`). You never need to invoke those to
get from an unboxed Spark to a working stack.

**Script 03 prints an API key when it finishes.** On first run it generates one
(`openssl rand -hex 32`), stores it in `.env` (gitignored, `chmod 600`), and
passes it to vLLM as `VLLM_API_KEY` — never as a command-line flag, so it does
not show up in `ps aux`. Every script in this repo reads it from `.env`
automatically. Copy it out any time with:

```bash
grep BRAIN_API_KEY .env
```

Then connect your agentic framework to `http://localhost:8000/v1`.

**With OpenClaw (recommended):** `openclaw onboard` → base URL
`http://localhost:8000/v1`, model ID = `served_name` from `config/models.yml`,
and **paste the generated API key when asked**. OpenClaw keeps its own config
and does not read `.env`, so this is the one value you have to carry across by
hand. Until you do, OpenClaw gets a 401 and the Brain looks broken while being
perfectly healthy.

**With any other framework:** Same base URL and model ID, sending the key as a
bearer token. Verify both states:

```bash
curl -s localhost:8000/v1/models                                  # 401 — auth is on
curl -s -H "Authorization: Bearer $(grep BRAIN_API_KEY .env | cut -d= -f2)" \
     localhost:8000/v1/models                                     # model list
```

See [docs/OPENCLAW_SETUP.md](docs/OPENCLAW_SETUP.md) for detailed connection examples (curl, Python, Node.js).

> **The Brain listens on `127.0.0.1` only.** `brain.bind_host` in
> `config/models.yml` defaults to loopback, so nothing outside the Spark can
> reach port 8000 — other machines on your LAN or tailnet included. Set it to
> `0.0.0.0` if you deliberately want remote access.

> **Script 02 prunes models no longer in `config/models.yml`.** In an
> interactive terminal it offers to move the pruned model to
> `/opt/model-archive` first, so rolling back costs a `mv` instead of another
> download. Non-interactive callers delete without asking.

### Rotating the API key

`.env` is the single source of truth — every script in the repo reads
`BRAIN_API_KEY` from it, so you change it in exactly one place. Blank the value
and let script 03 mint a fresh one:

```bash
cd ~/spark-sovereign
sed -i 's|^BRAIN_API_KEY=.*|BRAIN_API_KEY=|' .env   # clear it
bash scripts/03_vllm_servers.sh                     # generates + prints the new key
```

Or set one yourself instead of generating:

```bash
sed -i "s|^BRAIN_API_KEY=.*|BRAIN_API_KEY=$(openssl rand -hex 32)|" .env
bash scripts/03_vllm_servers.sh
```

Either way, script 03 restarts the Brain with the new key and the health checks
(`check_stack.sh`, `watchdog.sh`, `boot_sequence.sh`, `benchmark.sh`)
pick it up on their next run with no edits.

**The one place it does not propagate is OpenClaw**, which stores its own copy.
Update it there too or it will 401 against a healthy Brain:

```bash
grep BRAIN_API_KEY .env     # read the new value
openclaw onboard            # re-enter it when prompted for the API key
```

Rotate whenever the key has been shown somewhere it shouldn't be — pasted into
a chat or an issue, or printed in a log you shared. Rotation is the real fix
for a leaked credential; deleting the place it appeared is not.

---

## Auto-Start on Boot

Script 01 installs a systemd service that starts Brain automatically on every power cycle. No manual intervention needed.

Brain takes **3–6 minutes to load** after a cold boot — ~22GB of NVFP4 weights plus the MTP draft model, then `torch.compile` and flashinfer kernel autotuning. OpenClaw reconnects automatically once ready.

The compile and autotune output is kept in a `vllm-cache` Docker volume, so only the first start after a model swap pays the full cost; later restarts skip that work. Confirm it is being reused — the log should say `0 new, N from previous config` rather than `N new, 0 from previous`:

```bash
docker logs brain 2>&1 | grep 'from previous config'
```

```bash
systemctl status spark-sovereign
journalctl -u spark-sovereign -f
```

### Self-Healing Watchdog

`spark-watchdog.timer` runs every 2 min after boot and self-heals the Docker containers spark-sovereign manages (`searxng`, `brain`, `asr-server`, `tts-server`). It is **idempotent** — healthy services are never touched — and **bounded**: after 3 consecutive failed recoveries, a service is quarantined to prevent restart loops.

The watchdog is intentionally **framework-agnostic** — it does not monitor agent layers (OpenClaw, LibreChat, n8n, etc.). Run your agent framework as a systemd user unit with `Restart=on-failure` (user linger is already enabled). To monitor an additional container, add `check_container <name> "docker start <name>"` to the tick block at the bottom of `scripts/watchdog.sh`.

```bash
# Live heartbeat — one summary line every 2 min
sudo journalctl -u spark-watchdog -f
# e.g.  [watchdog] tick searxng=up brain=up asr-server=absent tts-server=absent

# Inspect state
ls -la /var/lib/spark-sovereign/state/
cat /var/lib/spark-sovereign/state/*.fails

# Clear a quarantine after fixing the underlying issue
sudo rm /var/lib/spark-sovereign/state/<svc>.quarantined
```

Brain gets a 10-min load grace window — the watchdog will not restart Brain mid-load (see [docs/LESSONS.md](docs/LESSONS.md#14-brain-takes-45-min-to-load--thats-normal-not-broken)).

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
│   ├── boot_sequence.sh       ← Auto-start on boot (oneshot, runs once at boot)
│   ├── watchdog.sh            ← Self-healing tick (every 2 min via systemd timer)
│   ├── start_brain_ad_hoc.sh  ← Restart Brain manually
│   ├── check_stack.sh         ← Health check
│   └── benchmark.sh           ← AD-HOC: the only benchmarking entry point.
│                                  Self-contained. `benchmark.sh` alone fills
│                                  docs/BENCHMARKS.md; subcommands audit / quick /
│                                  bandwidth / matrix / render / list
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
Model ID:  qwen38-27b  (or your served_name from config/models.yml)
API key:   any string
```

See [docs/OPENCLAW_SETUP.md](docs/OPENCLAW_SETUP.md) for connection examples in curl, Python, and Node.js.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Free to use, modify, and distribute with attribution. The models referenced are open-weight and available on HuggingFace under their respective licenses. vLLM and OpenClaw are open source (MIT/Apache 2.0).

---

*Built in public. Own your AI.*
