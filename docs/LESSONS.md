# Lessons Learned — spark-sovereign Build Journey

A running log of decisions made, mistakes caught, and thinking that shaped the current setup.

---

## 1. Started with a Multi-Model Stack

**What we did:** Initial design connected multiple specialized models to cover all capabilities — a large model for reasoning/coding, a smaller fast model for routing, a separate vision encoder, ASR and TTS containers for voice, pgvector for memory, SearXNG for web search.

**What we learned:** This was over-engineered from the start. Each additional model added memory pressure, startup complexity, and another thing to break. The routing logic between models (fast/deep/auto modes) added code that had to be maintained and debugged.

---

## 2. OpenClaw Already Handles the Capabilities

**What we did:** After testing the full stack, we discovered OpenClaw natively provides voice, memory, web search, RAG, Telegram, and agent orchestration — without any of the extra containers.

**What we learned:** The separate ASR server, TTS server, pgvector DB, SearXNG instance, Telegram bot, and model router were all redundant. Dropping them simplified the stack to two things: vLLM serving the model, and OpenClaw connecting to it. Same capabilities, far less complexity.

**Result:** Scripts 04–09 marked as not needed. The entire stack is now `03_vllm_servers.sh` + OpenClaw onboard wizard.

---

## 3. NemoClaw Investigated, Avoided

**What we considered:** NemoClaw is NVIDIA's OpenClaw wrapper with OpenShell sandboxing. It looked like a good option for agent isolation and orchestration.

**Why we passed:** NemoClaw requires an NVIDIA API key to operate — vendor lock-in to NVIDIA's cloud infrastructure. That directly contradicts the core goal of this project: **zero cloud, zero external dependencies, fully local and private.** NVIDIA could change pricing, access, or availability at any time.

**What we chose instead:** OpenClaw — open source, no API key required, runs fully on local hardware. No external calls, no account required, no lock-in.

---

## 4. Model Upgraded: 35B-A3B → 27B-FP8

**Original model:** Qwen3.5-35B-A3B-FP8 (MoE — 35B total / ~3B active per token)

**Problem identified:** MoE architectures use quadratic attention for the full-attention layers. At 100K+ token contexts (which OpenClaw regularly hits during long sessions), prompt processing throughput degrades significantly. The 35B-A3B was hitting this cliff in production.

**New model:** Qwen3.5-27B-FP8 (dense, Gated DeltaNet hybrid architecture)

**Why it's better for this use case:**
- Gated DeltaNet (linear attention) scales near-linearly at long contexts — no quadratic cliff
- Dense model: all 27B parameters active every token — better quality per active param than MoE routing
- Better SWE-bench coding scores than the 35B-A3B despite smaller size
- ~27GB FP8 weights vs ~73GB — frees ~64GB for KV cache, enabling much longer effective context
- Same 262K context window, same tool calling and reasoning parsers

**Memory reallocation:** Dropped `gpu_memory_utilization` from 0.60 to 0.75. Counter-intuitively this gives *more* KV cache headroom (0.75 × 121GB = ~91GB total to vLLM; 27GB weights → ~64GB KV cache vs essentially 0 before).

---

## 5. Previous Approach Worked but Was Clunky

The multi-model + multi-container setup functioned. Models were downloading, routing was working, voice pipeline was operational. But every session required monitoring multiple Docker containers, the boot sequence was fragile, and debugging meant checking logs across 6+ services simultaneously.

The simpler setup (one model, one container, OpenClaw handles the rest) is just as capable in practice and takes minutes to diagnose instead of hours.

---

## 6. Open Gap — Vector Embedding DB for Custom Data Training

**Current limitation:** OpenClaw does not include a persistent vector embedding database. Its memory is session-aware but does not support loading and querying a custom domain-specific knowledge base (e.g. your codebase, documentation, past decisions).

**What this means:** The system can't yet be "trained" on your own data in the pgvector sense — storing embeddings of your files, docs, and past sessions in a queryable vector store that Brain retrieves from before answering.

**Planned next step:** After more OpenClaw testing, evaluate adding pgvector back as a standalone service with a lightweight MCP server front-end, so Brain can query domain-specific embeddings without rebuilding the full old memory stack.

This would give the best of both worlds: OpenClaw's native capabilities + a private, persistent knowledge base that grows with use.

---

## 7. Voice Setup — STT Only (Local & Private)

**What we learned:** OpenClaw's audio transcription happens at the OpenClaw layer, NOT the model layer. This is model-agnostic by design.

**STT (Speech-to-Text):**
- **100% local** using Whisper CLI (CLI-based transcription)
- Configured via `tools.media.audio` in `~/.openclaw/openclaw.json`
- Auto-detects installed CLIs (whisper, whisper-cli, sherpa-onnx)
- Falls back to cloud providers (OpenAI, Deepgram, Groq) if no local CLI found

**How it works:**
1. User sends voice note (Telegram, TUI, etc.)
2. OpenClaw detects audio file
3. Whisper CLI transcribes locally on GPU
4. Transcript replaces message body
5. Model sees text and responds normally
6. Echo shows: `🎤 "transcribed text"`

**Privacy:**
- ✅ Fully local — no cloud APIs
- ✅ GPU-accelerated on local hardware
- ✅ No data leaves the machine
- ✅ whisper-small model (~450MB, ~96% accuracy, ~2GB VRAM)

**What this means for users:**
- Voice notes in Telegram auto-transcribe locally
- Model responds with text (no TTS unless configured separately)
- Works across all OpenClaw channels (Telegram, TUI, etc.)

**Setup:**
```bash
bash scripts/04_voice_stt.sh  # Downloads model, installs CLI, outputs config
```

**Docs:**
- https://docs.openclaw.ai/nodes/audio

---

## 8. Qwen3-Next-80B NVFP4 Attempted and Abandoned

**What we tried:** nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4 via `avarok/vllm-dgx-spark:latest`

**What worked:**
- Model loaded and served on port 8888 (~88.4GB VRAM, healthy container)
- Non-streaming tool calls parsed correctly with `--tool-call-parser hermes`
- ~40GB weights in NVFP4, plenty of headroom

**What broke — and why we abandoned it:**

1. **Avarok image quirks:** Custom entrypoint ignores `--port`, `--served-model-name`, and all CLI flags. Everything must be passed as env vars (`MODEL`, `PORT`, `VLLM_EXTRA_ARGS`). Required reverse-engineering the entrypoint script.

2. **Tool calling broken in streaming mode:** vLLM 0.14.0rc2 (Jan 2026) in the Avarok image has a known hermes parser bug where streaming responses return raw `<tool_call>` XML as text content instead of parsed `tool_calls` arrays. OpenClaw always sends `stream: true` — no config option to disable it at the API level. Tried `hermes`, `qwen3_coder`, and `qwen3_xml` parsers — none worked in streaming.

3. **NVFP4 kernel JIT failures:** The first Avarok image (`avarok/dgx-vllm-nvfp4-kernel:v22`) failed to JIT-compile FlashInfer CUTLASS MoE kernels on SM121a. Had to switch to `avarok/vllm-dgx-spark:latest` which had pre-built kernels.

4. **MTP speculative decoding unsupported:** `--speculative-model` flag not recognized by this vLLM build, eliminating the headline speed advantage (67–112 tok/s).

**Key lesson:** Community Docker images for NVFP4 on DGX Spark are bleeding-edge. The vLLM version inside (0.14.0rc2) is too old for reliable streaming tool calls. Until Avarok ships an image with vLLM 0.8+, NVFP4 models on Spark can't do tool calling through OpenClaw.

---

## 9. Model Settled: Qwen3-30B-A3B-FP8 (Working Stack)

**Final model:** Qwen/Qwen3-30B-A3B-Instruct-2507-FP8 (MoE — 30B total / 3B active per token)

**Docker image:** `vllm/vllm-openai:cu130-nightly` (the proven standard image)

**Why this is the right choice:**
- Standard vLLM image — no custom entrypoint, no env var workarounds, `--port` and `--served-model-name` work normally
- Tool calling works with `--tool-call-parser hermes` in both streaming and non-streaming
- ~30GB FP8 weights → ~60GB KV cache at 0.75 util → massive context headroom
- ~46–54 tok/s — comparable to old dense 27B but with MoE efficiency
- 131K context window, FP8 KV cache
- Port 8000 (standard), clean model name

**What changed from old 27B dense setup:**
- MoE architecture: only 3B params active per token (vs all 27B) — more efficient inference
- More KV cache headroom: ~60GB vs ~64GB (similar) but lighter compute per token
- Same docker image, same port, same scripts — drop-in swap

**OpenClaw config for this model:**
- Base URL: `http://127.0.0.1:8000/v1`
- Model ID: `qwen3-30b` (the served_name)
- Streaming: works with any mode (partial, block, off)

---

## 10. Model Swap: Qwen3-30B-A3B → Nemotron-3-Nano-30B-A3B

**Previous model:** Qwen3-30B-A3B-Instruct-2507-FP8 (~46–54 tok/s, hermes parser)

**New model:** nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8

**Why the switch:**
- NVIDIA's own model, purpose-built for DGX Spark hardware
- Same architecture: 30B MoE, 3B active per token, FP8 quantization
- Same Docker image: `vllm/vllm-openai:cu130-nightly` — no custom images needed
- Same memory footprint: ~30GB weights, ~60GB KV cache at 0.75 util

**Key differences from Qwen3-30B:**
- Tool call parser: `qwen3_coder` (not `hermes`)
- Requires custom reasoning parser plugin: `nano_v3_reasoning_parser.py` (ships inside the HF repo)
- Pass `--reasoning-parser-plugin /path/to/nano_v3_reasoning_parser.py --reasoning-parser nano_v3` to vLLM
- Plugin file is volume-mounted into the Docker container from the model directory

**What stayed the same:**
- Port 8000, standard vLLM image, same scripts, same boot sequence
- OpenClaw connects identically — just update model ID to `nemotron-3-nano`

---

## 11. SM12.1 (DGX Spark) Requires Specific vLLM Environment Variables

**What happened:** After switching to Nemotron-3-Nano-30B-A3B-FP8, we audited the official NVIDIA HuggingFace model card and the Avarok DGX Spark vLLM docs against our actual `models.yml` config. Several critical flags were missing or wrong.

**What was wrong:**
- `quantization: fp8` was explicitly set — unnecessary and potentially harmful. The FP8 model checkpoint is pre-quantized; vLLM auto-detects this. Removed.
- `max_num_seqs: 32` — the official NVIDIA recipe uses 8. On Spark's bandwidth-constrained unified memory, 32 concurrent sequences degrades throughput or OOMs.
- No SM12.1-specific environment variables were set.

**What was added:**
- `VLLM_USE_FLASHINFER_MOE_FP8=1` — required to activate the FP8 MoE kernel path (from official HF model card)
- `VLLM_FLASHINFER_MOE_BACKEND=latency` — the `throughput` backend has SM120 kernel issues on SM12.1 (from Avarok DGX Spark vLLM docs)
- `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` — needed when pushing past default context length
- `--async-scheduling` — NVIDIA recommended for reducing host overhead between decoding steps
- `max_num_seqs` dropped from 32 to 8

**What was already correct (scripts had it, Sonnet incorrectly flagged as missing):**
- `--trust-remote-code` — hardcoded in `03_vllm_servers.sh` and `start_brain_ad_hoc.sh`, not read from yml
- `--enable-auto-tool-choice` — same, hardcoded in both scripts
- `reasoning_parser_plugin: nano_v3_reasoning_parser.py` — bare filename is correct; scripts prepend the model path (`${BRAIN_MODEL_PATH}/${BRAIN_REASON_PLUGIN}`), and `huggingface-cli download` pulls the file as part of the full repo

**Key lesson:** Always cross-reference AI-suggested configs against the actual official model card AND the scripts that consume the config. Sonnet got ~80% right but also recommended adding flags that would have broken path construction or duplicated hardcoded behavior.

---

## 12. Model Swap: Nemotron-3-Nano → Qwen3.5-35B-A3B-FP8 (v3.0 — superseded)

**Previous model:** nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8 (~35–45 tok/s, qwen3_coder + nano_v3 custom parser)

**New model:** Qwen/Qwen3.5-35B-A3B-FP8

**Why the switch:**
- Nemotron-3-Nano was weaker on complex coding and architectural reasoning — confirmed through testing
- The dense Qwen3.5-27B was smarter but bandwidth-limited to ~14–30 tok/s on Spark (273 GB/s ÷ 54GB weights ≈ 5 tok/s theoretical ceiling)
- Qwen3.5-35B-A3B-FP8 is MoE (35B total / 3B active per token) from the same Qwen3.5 family — gets MoE speed with near-dense intelligence

**What makes this model the best fit so far:**
- ~49 tok/s on Spark — 3x faster than the dense 27B, faster than Nemotron-3-Nano
- Community-confirmed: surpasses Qwen3-235B-A22B (22B active) with only 3B active params — better RL and architecture, not bigger parameter counts
- Same `qwen3_coder` tool parser and `qwen3` reasoning parser as the 27B — no custom parser plugins needed (unlike Nemotron-3-Nano which required nano_v3_reasoning_parser.py)
- ~55GB FP8 weights vs ~30GB for Nemotron — uses more memory but fits comfortably at 0.80 util
- Both more intelligent AND faster than the previous two release models

**Tuning applied:**
- `gpu_memory_utilization: 0.80` — ~97GB to vLLM (~55GB weights + ~42GB KV cache), ~24GB left for OS/Docker
- `max_num_seqs: 16` — reduced from 32; single-user setup benefits from less scheduling overhead
- `VLLM_FLASHINFER_MOE_BACKEND=latency` — required for SM12.1 MoE kernels on Blackwell
- `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` — allows 131K context without vLLM warning
- `enable-prefix-caching` — big win for OpenClaw's repeated memory.md preprompt

**Flags that don't work on cu130-nightly (vLLM v0.12+):**
- `--num-scheduler-steps` — removed in this vLLM version (multi-step scheduling is automatic)
- `--enable-chunked-prefill` — enabled by default in this vLLM version

**OpenClaw config for this model:**
- Base URL: `http://127.0.0.1:8000/v1`
- Model ID: `qwen35-35b` (the served_name)
- Context window: `131072`

**Key lesson:** The dense vs MoE trade-off is real, but within the same model family (Qwen3.5), the MoE variant can match or exceed the dense variant's intelligence while being dramatically faster. The 27B dense model is the wrong choice for bandwidth-limited hardware like the Spark — you hit physics limits, not software limits. The MoE architecture sidesteps this entirely by only moving 3B of params per token through the memory bus.

---

## 13. Model Swap: Qwen3.5-35B-A3B → Qwen3.6-35B-A3B-FP8 (v4.0–v4.2.1 — superseded, rollback baseline)

**Previous model:** Qwen/Qwen3.5-35B-A3B-FP8 (~49 tok/s, 131K context, standard MoE)

**New model:** Qwen/Qwen3.6-35B-A3B-FP8

**Why the switch:**
- +3.4 pts SWE-bench Verified (73.4% vs 70.0%) — meaningful coding improvement
- +11 pts Terminal-Bench 2.0 (51.5% vs 40.5%) — major agentic coding upgrade
- Community benchmark on single DGX Spark: ~52.73 tok/s (tg32) — slightly faster than v3.0
- Native 262K context (up from 131K) — doubles effective conversation length
- Same parsers (`qwen3_coder`, `qwen3`), same Docker image, same scripts — true drop-in

**Architecture change — Gated DeltaNet hybrid:**
- Qwen3.5 used standard MoE with full quadratic attention at every layer
- Qwen3.6 uses Gated DeltaNet + MoE: linear attention for 3/4 of layers, full attention for 1/4
- This directly addresses the long-context quadratic cliff documented in Lesson #4
- KV cache pressure dramatically reduced — 262K context fits within the same 0.80 util memory budget
- Weights dropped from ~55GB to ~35GB (34.23 GiB observed) — frees ~20GB more for KV cache
- KV cache: 57.6 GiB available → 1,509,120 tokens → 22.3x concurrent 262K requests
- Total VRAM: 109 of 128 GB utilized on DGX Spark (confirmed via dashboard)

**What changed in config:**
- `hf_repo`: `Qwen/Qwen3.5-35B-A3B-FP8` → `Qwen/Qwen3.6-35B-A3B-FP8`
- `served_name`: `qwen35-35b` → `qwen36-35b`
- `max_model_len`: `131072` → `262144`
- Everything else (image, parsers, env vars, util, seqs) stays identical

**vLLM requirement:** >= 0.19.0. Verify your `cu130-nightly` has this before deploying:
```bash
docker run --rm vllm/vllm-openai:cu130-nightly python -c "import vllm; print(vllm.__version__)"
```

**Caveats:**
- Qwen3.6 does NOT support `/think` `/nothink` soft switches (Qwen3.5 feature removed)
- MTP speculative decoding showed performance degradation on Spark — do not enable
- If 262K context causes OOM, fall back to `max_model_len: 131072`

**Key lesson:** Same model family, same shape, same tooling — but the DeltaNet architectural change is genuinely meaningful. It's not just benchmark points; the linear attention layers fix a real production problem (long-context degradation) that was documented in Lesson #4. This is the kind of upgrade worth taking: zero migration cost, real capability gain.

---

## 14. Brain Takes 4–5 Min to Load — That's Normal, Not Broken

**The recurring panic:** Telegram returns "LLM response error" right after a boot or restart, the DGX Spark dashboard shows ~45 GB unified memory used, and the instinct is "something didn't auto-start."

**What's actually happening:** vLLM's load pipeline takes 4–5 min on Spark:
- ~3.5 min to load ~35 GB of FP8 weights off NVMe into memory
- ~30 s for torch.compile, cudagraph capture, KV cache profiling
- Port 8000 only binds *after* both finish

During this window the brain container shows `Up` but `curl /v1/models` fails. Expected, not broken.

**Diagnose in 5 seconds:**
```bash
docker logs brain --tail 20    # look for "Loading safetensors..." progress
                                # or "Uvicorn running on http://0.0.0.0:8000" at the end
free -h                         # buff/cache growing = weights still streaming in
```

**Why the watchdog doesn't restart Brain during load:** `scripts/watchdog.sh` has `BRAIN_LOAD_GRACE_SECONDS=600` (10 min). If brain is up but port-silent and younger than 10 min, the watchdog leaves it alone (logs `brain=loading(Ns)` in its heartbeat). Only after the grace window does it count as a real failure and trigger recovery.

**Key lesson:** Treat the first ~10 min after a fresh brain container as a load window. Two diagnostic sessions in two days were spent re-discovering this. The watchdog already knows; future-you should too.

---

## 15. Self-Healing Watchdog — Idempotent, Bounded, Quiet

**The problem:** v4.1 added systemd-driven auto-start on boot, but the box still required SSH intervention when anything failed *after* boot (vLLM crashes, OOM, Docker daemon restarts). Unworkable for an unattended box, especially while traveling.

**What we added in v4.2:** `spark-watchdog.timer` — every 2 min runs `scripts/watchdog.sh`, which checks each service and self-heals what's down.

**Design constraints — deliberate, not accidental:**

1. **Idempotent.** Healthy services are not touched. No "restart-just-in-case." The cost of an unnecessary restart on a 4-min-loading Brain is too high.
2. **Bounded.** State tracked in `/var/lib/spark-sovereign/state/<svc>.fails`. After 3 consecutive failed recovery attempts (~6 min of trying), the service is quarantined — watchdog stops touching it until it recovers on its own or an admin clears it. Prevents crash-restart loops.
3. **Silent on success, but with a heartbeat.** Watchdog emits exactly one log line per tick: `[watchdog] tick searxng=up brain=up asr-server=absent tts-server=absent`. Confirms it's alive without spamming.
4. **Boot path stays simple.** `boot_sequence.sh` does first-time startup (and tolerates failures — `set -e` removed, bounded Brain wait). After that, the watchdog owns steady-state.
5. **Linger enabled.** `loginctl enable-linger` so user-level units survive power cycles without an SSH session.

**Why no Docker `--restart unless-stopped`?** Considered and rejected. Docker's policy would respawn Brain forever underneath us and defeat the quarantine logic. Centralizing lifecycle decisions in one place (the watchdog) is worth one extra layer.

**Scope boundary — framework-agnostic by design (v4.2.1):** The watchdog monitors *spark-sovereign-owned Docker containers only* (`searxng`, `brain`, `asr-server`, `tts-server`). It does **not** monitor agent frameworks (OpenClaw, LibreChat, n8n, Continue, AnythingLLM, etc.) — those own their own lifecycle. Recommended pattern for the framework layer: a systemd user unit with `Restart=on-failure` (linger is already enabled). For containerized frameworks, add `check_container <name> "docker start <name>"` to the tick block at the bottom of `watchdog.sh`. An earlier draft had a hard-coded `check_openclaw` that depended on the `openclaw` CLI being on PATH — it broke under systemd's reduced PATH (openclaw ships via npm under `~/.nvm/versions/node/<ver>/bin`) and, more fundamentally, leaked framework choice into infrastructure code. Removed.

**Storage cost:** ~80 bytes per heartbeat × 30 ticks/hr ≈ 21 MB/year worst case. systemd-journald rotates the journal at 4 GB / 10% of `/var/log` automatically — physically cannot grow indefinitely.

**Key lesson:** "Self-healing" without bounded retries is just "restart loop with extra steps." The quarantine flag is the most important part of the design, not the auto-restart. Equally important: infrastructure code should not name specific frameworks; each layer owns its own lifecycle.

---

## 16. Model Swap: Qwen3.6-35B-A3B → Qwen3.8-27B NVFP4 (v5.0 — Current; Vision Accepted, Speed Sacrificed)

**Previous model:** Qwen/Qwen3.6-35B-A3B-FP8 — MoE (35B total / **3B active** per token), ~53 tok/s measured. This is what `v4.2.1` restores.

**New model:** unsloth/Qwen3.8-27B-NVFP4 — **dense 27B multimodal**, NVFP4 4-bit weights, 262K context, native vision (up to 10 images per prompt), MTP speculative-decoding heads shipped in the checkpoint.

**Docker image:** `vllm/vllm-openai:qwen38-arm64-cu130` (arm64 for GB10). The prior `cu130-nightly` tag from v4.2.1 predates the Qwen3.8 architecture and cannot register the model.

### The measurement — clean idle, single-stream, three runs of 256 tokens

| | v4.2.1 (Qwen3.6-35B-A3B FP8) | v5.0 (Qwen3.8-27B NVFP4) |
|---|---|---|
| Decode | ~53 tok/s | **15–17 tok/s** (median 15.5 / 16.9 across three independent runs, range 14.3–18.5) |
| TTFT | — | ~280 ms (range 262–289 ms) |
| VRAM reserved | 0.80 util (~97 GB) | 0.45 util (**~55 GB — verified via `nvidia-smi`**) |
| Weights on disk | ~35 GB (FP8) | ~22 GB (NVFP4 4-bit) |

Numbers were reproduced three times independently — `scripts/benchmark_brain.sh` after the benchmark-script fix (commit `9cd2f2d`), a self-diagnostic the Brain agent ran on itself, and a third confirmation run the same day. All landed in the 15–17 tok/s median window with consistent TTFT and prompt-size accounting. Consistent enough to publish.

### Why the drop

Spark is **memory-bandwidth-bound**, not compute-bound. Per-token decode speed is set by how many parameter bytes have to move through the ~273 GB/s memory bus:

- v4.2.1 MoE: **3B active × 8-bit ≈ 3 GB/token** → fits the bandwidth budget → ~53 tok/s.
- v5.0 dense: **27B × 4-bit ≈ 13.5 GB/token** → ~4.5× more bytes per token → ~3× slower decode.

NVFP4 4-bit weights help (would be ~27 GB/token at 8-bit), but the active-compute gap wins. This is exactly the pattern documented in **Lesson #12** ("dense 27B on Spark is the wrong choice for bandwidth-limited hardware — you hit physics, not software"). We hit it again on purpose, this time knowingly, because the trade came with something the MoE couldn't offer.

### Why we kept it anyway

1. **Native multimodal input (text + images + video).** Qwen3.8-27B accepts up to 10 images per prompt directly, plus video — no separate vision encoder. The previous MoE was text-only. For image-in workflows (screenshots, diagrams, photos through Telegram, video frames), this is a capability delta, not just a benchmark delta.
2. **Coding capability actually holds up on paper.** Published benchmarks at release (Aug 14, 2026): 79.0% QwenSWEBench, 61.7% SWE-Bench Pro, 90.3% LiveCodeBench v6, 73.0 Terminal-Bench 2.1, 84.3% OSWorld-Verified, 89.2% GPQA Diamond. On the code and agentic-execution axes, competitive with Opus 4.6-era and Sonnet 4.6 / GPT-5.6 Terra. Frontier flagships (Opus 4.8, GPT-5.6 Sol) still lead on the hardest architectural reasoning, but the gap in daily-driver territory is small.
3. **Dense per-token reasoning.** Every token routes through all 27.78B parameters instead of a 3B expert subset. For long single-thread reasoning (multi-file refactors, architectural discussion, hard-to-benchmark "coherence"), the dense model tends to hold thread better than a same-size MoE.
4. **262K context preserved.** No regression on context window from v4.2.1.
5. **Blackwell-native quantization.** NVFP4 is what GB10 is designed for; weights fit in ~22 GB, leaving over half the Spark's memory for other workloads.
6. **Apache 2.0 license.** No commercial restrictions on inference or downstream use.

### What OpenClaw needs on the client side — otherwise the trade is neutered

OpenClaw declares the `vllm/qwen38-27b` provider with `input: ["text"]`. If left this way, **images get stripped before they reach vLLM** and you get the 3× speed penalty with none of the vision benefit. Add `"image"` to that provider's `input:` list in OpenClaw's config before relying on vision. (This is an OpenClaw config, not a repo change — flagging here so the rollback-vs-keep decision is made with full information.)

### What we changed to make this land

- `config/models.yml`: `hf_repo`, `local_path`, `served_name`, `docker_image`, `gpu_memory_utilization` (0.80 → 0.45), removed `moe_backend` (dense — flag is MoE-only), added `speculative_config` (MTP), promoted `enable_prefix_caching` to a first-class field.
- Fixed two latent bugs in the scripts along the way: `get_field()` was returning Python's `"True"` for YAML `true` (would have silently dropped any bool flag the moment one was set), and `start_brain_ad_hoc.sh` hardcoded `--enable-prefix-caching` while `03_vllm_servers.sh` never passed it (so boot-time start and watchdog recovery produced different servers).
- Added `scripts/benchmark_brain.sh` — TTFT + decode tok/s against the running Brain. **The repo had no speed tooling at all before this**, which is how the v4.1 NVFP4 attempt shipped with tok/s "TBD" for weeks. Also fixed to accept vLLM's newer `delta.reasoning` streaming field alongside the older `delta.reasoning_content` (commit `9cd2f2d`).
- Added archive-on-prune to `scripts/02_download_models.sh` — before deleting a pruned model dir, offers to move it to `/opt/model-archive` (single-slot). Rollback no longer costs a 35 GB HuggingFace download. Non-interactive callers (boot/watchdog/systemd) keep the old delete-silently behavior (commit `e74a8c0`).
- `02_download_models.sh` now checks `tokenizer.json` for a pinned `truncation` — that field silently caps prompt length with no error and had bitten previous swaps.

### Rollback path — kept explicit

The v4.2.1 tag is the last release with measured 53 tok/s and is safe to return to at any time:

```bash
git checkout v4.2.1
bash scripts/02_download_models.sh    # re-pulls the 35GB FP8 baseline
bash scripts/03_vllm_servers.sh
```

`/opt/model-archive/qwen36-35b-a3b-nvfp4` (the intermediate NVFP4 MoE from an earlier commit on this branch) is **not** a viable rollback target — it hit the `--moe-backend: flashinfer_b12x` blocker on this vLLM version and does not start.

### Key lesson

Speed and capability are not on the same axis. Lesson #12 warned that dense-on-Spark is bandwidth-limited; that lesson is still correct. What changed this time is that we had a reason to accept the trade — vision — that Lesson #12's context (chat-only text) didn't have. **Physics didn't budge; priorities did.** If your workload is text-only high-throughput, roll back to v4.2.1 and keep 53 tok/s. If you need images in the loop, v5.0 pays for itself once OpenClaw stops stripping them.

---

## 17. Hardening the v5.0 Stack (v5.1 — Same Model, Fixed Foundations)

No model change. Everything here is about the machinery around the Brain, and most of it was invisible because the tooling reported success.

### The Brain was open to the whole house

`03_vllm_servers.sh` served vLLM on `--host 0.0.0.0` with no authentication — the API key was documented as "any string works". Any device on the router could query it: other laptops, a guest phone, a smart TV, a compromised IoT device. **Not** internet-reachable — the router blocks inbound unless you forward the port, so this was never a DDoS or intrusion vector — but far wider than intended.

New `brain.bind_host` in `models.yml`, default `127.0.0.1`. Every consumer in this repo (OpenClaw's gateway, `check_stack`, `boot_sequence`, `watchdog`) talks to `localhost` and runs on the Spark, so nothing broke. Set it to `0.0.0.0` to deliberately reopen it.

### API key, auto-provisioned, off the command line

`03` now generates `openssl rand -hex 32` on first run, writes it to `.env` (gitignored, forced `chmod 600`), and prints it once. It is passed to the container as **`VLLM_API_KEY`, not `--api-key`** — [equivalent per vLLM's docs](https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/), but the flag would put the secret on the process command line where `ps aux` prints it in full.

`start_brain_ad_hoc.sh` deliberately does **not** generate. It runs unattended from `boot_sequence.sh` and `watchdog.sh`; minting a fresh key on every self-heal would break OpenClaw after each recovery.

The trap: `--api-key` makes every `/v1` route return 401, and **six scripts poll `/v1/models` as a health check**. Left alone, `watchdog.sh` would have restarted a perfectly healthy Brain every two minutes, and `boot_sequence.sh` would have timed out for 12 minutes on a Brain that was already up. All six now send the header. `benchmark_brain.sh` had a hardcoded `Authorization: Bearer local` that would have 401'd.

### The watchdog raced a deliberate restart — and the fix was to reorder, not to lock

Observed live, 2026-08-25 19:12:09:

```
19:12:09  watchdog: brain unhealthy — recovery attempt 1/3
19:12:10  watchdog: started d7d0fe1...
          03: Conflict. The container name "/brain" is already in use
```

`03` removed the container at the top of the script, then made ~15 `get_field` calls — each spawning `python3` to parse `models.yml` — before `docker run`. That left several seconds of gap. The watchdog polls every 2 minutes, saw no Brain, and *correctly* started one. `03` then died.

The tempting fix was a lock file with a timestamp, an expiry, and an `EXIT` trap. It was rejected: **a lock's failure mode is self-heal silently disabled**, and this box is expected to recover from a power cut unattended. Persistent state that can go stale is exactly the wrong trade.

The actual fix was to move the stop/remove to sit immediately before `docker run`, closing the gap to milliseconds with no new state at all. `start_brain_ad_hoc.sh` had always been ordered that way, which is why it never hit the bug — `03` simply had it backwards.

Worth noting the residual failure is benign: if the watchdog wins, the Brain **is** running correctly and only `03` prints an error.

### A health check that printed a green line it never verified

`check_stack.sh` reported `✅ Memory search: enabled (provider: auto — API key found)`. It computed `HAS_EMBED_KEY` correctly and then **ignored it** — the message lived in a catch-all `else` that fired whenever the OpenClaw config lookup returned nothing, which is what happens on 2026.4.9 where that config path no longer exists. A false all-clear on the one line that would reveal memory contents leaving the box.

It now warns properly when a cloud embedding key really is present, and otherwise reports the state as unknown while confirming no key is set.

### `01` was overwriting the file it was supposed to install

`01_system_prep.sh` wrote its own inline copy of `scripts/boot_sequence.sh` from a heredoc, then `chmod +x`'d it. So the file systemd executed was the one `01` generated, **not the one in git** — and re-running `01` silently reverted any edit to the tracked file. The two had already drifted. Replaced with a presence check; the repo is now the single source of truth.

### Compile artifacts were thrown away on every restart

Both launch paths do `docker rm -f brain` first, taking the container's writable layer with it — so `/root/.cache/vllm` died too and every restart re-ran `torch.compile` and flashinfer autotuning from scratch. The 2026-08-25 restart logged `42 new, 0 from previous config` and took ~6 min, of which ~3 min was that work. Now persisted in a `vllm-cache` named volume.

**Not yet measured:** the cache reuse benefit and the post-reboot timing. Expect `0 new, N from previous config` and a noticeably shorter load on the next restart — but that is a projection until a power cycle confirms it.

### Key lesson

Five of these six were invisible because something reported success: a health check that couldn't fail, a setup script that "worked" while discarding its own input, a watchdog doing exactly its job at exactly the wrong moment. **Tooling that cannot report a problem is worse than no tooling**, because it converts an unknown into a false certainty. The bind, the missing auth, and the discarded cache had all been true for months under a stack full of green checkmarks.

---

## 18. Is 15–17 tok/s a Ceiling or a Symptom? (Measured — Symptom, Partly)

**Status: measured on the Spark, 2026-08-26. The hypothesis below was written to be falsified, and it was — on both of its inputs.** The original text is kept intact beneath the results, because what it got wrong is more instructive than what it got right.

**The short answer: both.** The roofline is real — and we were nowhere near it, in the other direction.

Non-speculative decode measures **12.04 tok/s**, and at 245 GB/s achieved bandwidth against ~23.4 GB of weights that is the bandwidth limit, essentially exactly. There is no config that makes a dense 27B decode faster than ~12 tok/s one token at a time on this box. **That ceiling is genuine and Lesson #12 was right about the physics.**

But the shipped config was never doing one token at a time. It ran MTP speculation at `num_speculative_tokens: 5`, and **5 was the worst setting available**:

| `num_speculative_tokens` | Decode | Acceptance |
|---|---|---|
| off | 12.04 tok/s | — |
| 2 | 18.47 tok/s | 60.3% |
| **3** | **19.66 tok/s** | **64.4%** |
| 5 *(what shipped in v5.0 and v5.1)* | 15.18 tok/s | 39.5% |

Changing one number from 5 to 3 is **+29.5%**, from 15.18 to 19.66 tok/s. Against no speculation at all it is +63%. The weights, the quantisation, the attention backend and the KV dtype are all untouched — output is unchanged, because speculative decoding verifies every draft against the real model and discards what it would not have produced.

**Read that as a ranking, not a throughput guarantee.** All four rows were measured back-to-back in one sweep, watchdog stopped, box otherwise idle — which is what makes comparing them fair, and the ordering 3 > 2 > 5 > off is solid. But absolute decode tracks acceptance, and acceptance tracks the sampled continuation. Re-measuring `mtp3` two hours later, on the same prompt, gave **46.5% acceptance and 17.1 tok/s** rather than 64.4% and 19.66.

That is not a regression and nothing was misconfigured — `num_spec_tokens=3` was confirmed in the engine log. At 3 draft tokens, tokens per forward pass is `1 + 3 × acceptance`, so 64.4% → 46.5% predicts 19.66 × (2.40/2.93) ≈ **16.1 tok/s**, and 17.1 was observed. The spread is fully accounted for by acceptance alone.

**Expect ~17 tok/s day to day.** Four runs measured 16.74, 17.06, 17.13 and 19.66 — and the 19.66 was the sweep itself, on an idle box with the watchdog stopped. Against a 15.2 baseline and a 12.0 non-speculative floor. Quoting 19.66 as the number this box does would repeat, in miniature, the exact error this lesson is about: taking one measurement made under favourable conditions and treating it as a property of the hardware.

So the 15–17 tok/s was a **symptom**, and the cause was neither a broken serving path nor a hardware wall. It was a draft length nobody had ever compared against an alternative, sitting one line below a comment that said so.

**vLLM warned about it at startup, on every single boot, for two releases:**

```
WARNING [speculative.py:948] Enabling num_speculative_tokens > 1 will run
multiple times of forward on same MTP layer, which may result in lower
acceptance rate
```

That warning is specific, correct, and was printed into a log that `benchmark.sh audit` greps. Nobody read it.

Both of the "two configuration bugs that outrank all of it" turned out to be absent here. Prefix caching works. The 262144 context is reachable with 2.8x room to spare.

### The trigger

Community configs for this same model on this same hardware circulate with a claimed **50 tok/s greedy median** single-stream, plus **~148 tok/s at 8 streams** and **~258 at 32**. We measure **15–17** single-stream. Before either chasing that or dismissing it, the claim gets tested.

### Rule out the easy part first: the multi-stream numbers are ordinary

Decode is bandwidth-bound, and one forward pass reads the whole weight set regardless of batch size. At batch N, that single read emits N tokens. So aggregate throughput rises with concurrency **for free**, until KV cache capacity or `max_num_seqs` binds.

148 @ 8 and 258 @ 32 therefore need no special technique and say nothing about single-stream speed. `scripts/benchmark.sh` measures that curve and checks whether this box reproduces it. If it does, two thirds of the original claim is explained and only the 50 tok/s single-stream figure still needs an account.

### The hypothesis, stated so it can be wrong

The tempting story is: dense 27.78B × NVFP4 ≈ 13.5 GB/token over a 273 GB/s bus ⇒ ~20 tok/s ceiling ⇒ 15–17 is 75–85% of optimal ⇒ nothing to find.

**That story rests on two numbers, and neither has ever been measured here.**

| Input | Where it came from | What if it's wrong |
|---|---|---|
| **273 GB/s** | GB10 spec sheet | Real LPDDR5x achieves 70–85% of spec. If it's ~220, the ceiling is ~16 tok/s and we're already at 100% — the roofline story gets *stronger*. |
| **13.5 GB/token** | Assumes the NVFP4 kernels genuinely read 4 bits/param | If the quant path dequantizes to BF16 or falls back to a general kernel, real bytes/token could be 2–4× higher. Then **there is no ceiling here at all** — there's a broken serving path, and ordinary config work has large headroom. |

The second row is not hypothetical. `config/models.yml` already documents this exact failure for the previous MoE brain: *"REQUIRED for that MoE on Spark, or it falls back to Marlin and runs 2.5x slower."* A silent kernel fallback is a known, in-repo failure mode for this hardware. Asserting a ceiling without checking for it would be assuming the conclusion.

### The test that decides it

`scripts/benchmark.sh bandwidth` measures the denominator and derives the numerator:

```
achieved bandwidth          <- GPU memcpy benchmark, actual not spec
measured decode rate        <- benchmark.sh quick
bytes/token = bandwidth / rate
ratio       = bytes-per-token / checkpoint-size-on-disk
```

- **ratio ≈ 1.0** — weights are read at their quantized width. The roofline is real, config tuning can't beat it, and going faster single-stream requires *fewer bytes* (lower-bit quant) or *fewer passes* (speculation).
- **ratio ≫ 1.5** — the path is moving far more data than the weights occupy. **Not a ceiling — a bug.** Chase the quant kernel, the attention backend vs `kv_cache_dtype: fp8`, and CUDA-graph state.

One measurement, two very different next moves. That is why it comes before any tuning.

---

### RESULTS — measured 2026-08-26

Read-only, against the production config, Brain up. Two audit runs plus one bandwidth and one quick benchmark.

| Quantity | Measured | Was assumed |
|---|---|---|
| Achieved memory bandwidth | **245.0 GB/s** | 273 GB/s (spec sheet) |
| Decode, single stream (3 × 256 tok) | **16.22 tok/s** | ~17 |
| TTFT | **288 ms** | — |
| Tokens per forward pass (MTP) | **2.89** | implicitly 1 |
| Bytes per forward pass | **38.4 GB** | 13.5 GB "per token" |
| Checkpoint on disk | **23.4 GB** | ~13.5 GB |
| Ratio, bytes-per-pass ÷ checkpoint | **1.64x** | 1.0 assumed |
| Prefix cache hit rate (delta, identical prefix) | **37.4%** | feared 0 |
| Speculative acceptance | **0.378 – 0.511** | never measured |
| KV cache capacity | **745,115 tokens** | feared < 262,144 |

**Every input to the original roofline was wrong.** Bandwidth was over-assumed by 11%. The checkpoint is 23.4 GB, not the ~13.9 GB that 27.78B params at 4 bits implies — NVFP4 quantises the linear layers, not the embeddings, norms, MTP heads or vision tower. And "bytes per token" was the wrong unit entirely, because speculation emits 2.89 tokens per weight read.

The arithmetic that produced "~20 tok/s ceiling, we're at 75–85%, nothing to find" was wrong in all three terms. It happened to land near the observed number, which is the most dangerous way for a wrong model to be wrong.

**What is genuinely confirmed working.** The NVFP4 path is *not* falling back — the log names `FlashInferCutlassNvFp4LinearKernel for NVFP4 GEMM`, the specific kernel we want, which retires the Marlin-fallback worry that motivated the whole "denominator could be 2–4× off" branch. FLASHINFER is auto-selected out of `['FLASHINFER', 'TRITON_ATTN']` without being pinned, and it coexists with `kv_cache_dtype: fp8` rather than trading against it as the field intel predicted. MTP speculation runs at 5 drafts per step with 38–51% acceptance.

### The 1.64x is real but it is not all waste

38.4 GB read per pass against a 23.4 GB checkpoint looks like 15 GB of unexplained traffic, and `benchmark.sh` duly printed its loudest verdict. That banner overstates the case, for two reasons that push in opposite directions and neither of which is currently measured:

- **Speculation's draft passes are not free and are not in the checkpoint figure.** Each step runs 5 MTP draft passes on top of the verification pass. Every one reads the MTP layer *and* the LM head, and at this vocabulary the LM head is over a gigabyte. Several GB per step of the excess is the *expected cost of the technique*, not a defect.
- **The vision tower is in the 23.4 GB and is never read during text decode.** That shrinks the true denominator and pushes the ratio the other way.

So the honest reading is "somewhat more traffic than the weights occupy, with a known unmeasured component" — the script's 1.25–1.6 middle band — rather than the smoking gun its >1.6 branch announces. The threshold was set before speculation was known to be active and does not account for draft passes. **Do not cite the 1.64x as evidence of a bug until `spec-off` has run.**

### What the full matrix settled — and what it did not

Fifteen configurations, 3 × 256 tokens each, in `docs/BENCHMARKS.md`.

**The roofline is confirmed, and speculation is the only lever that beat it.** `spec-off` at 12.04 tok/s against 245 GB/s and ~23.4 GB of weights puts bytes-per-pass at ~20.4 GB — at or slightly under the weight set, which is what a clean dense decode path looks like. The earlier 1.64x was speculation's draft passes, exactly as flagged. **There is no serving-path bug.** The `attn`, `kv_cache_dtype` and `gpu_memory_utilization` rows all landed within 15.07–15.19 tok/s of each other: none of them moves single-stream decode at all.

**Aggregate throughput also rises with speculation**, 78.6 → 108.9 tok/s at 8 streams, which was not obvious in advance — batching and speculation could have competed for the same bottleneck and did not.

**Two overrides silently did not take effect, and the validation caught both.** This is the whole reason the Validity column exists:

- `prefix-off` requested `enable_prefix_caching=false` and measured a 37.4% hit rate — unchanged from baseline. Prefix caching is **on by default** in vLLM V1, so omitting the flag does not disable it; that needs `--no-enable-prefix-caching`. The launcher cannot currently express "off".
- `attn-triton` requested `TRITON_ATTN` and the log says `Using FLASHINFER attention backend`. Its 15.14 tok/s is a second measurement of FlashInfer, not a measurement of Triton.

Both rows are marked PARTIAL and excluded from the ranking. Without the validation fix they would have read VALID, and we would have concluded "the attention backend makes no difference" from two runs of the same backend. **The attention-backend lever remains untested**, and so does prefix-caching-off.

**The n-gram result is not a verdict.** `spec-ngram5` drafted **10 tokens across an entire generation** — it essentially never fired, and its 12.46 tok/s is just `spec-off` with overhead. That is the predicted worst case: the default prompt writes fresh prose, and prompt-lookup pays off only when output echoes context. On agentic coding over files already in context it may well beat MTP. Ruling it out on this number would repeat the mistake this lesson is about.

**The artifactory warning was mostly a red herring**, and saying so matters as much as raising it. The same log shows the FlashInfer autotune cache loading 42 configs from disk and a `Config cache hit for fp4_gemm`, plus `FlashInferCutlassNvFp4LinearKernel for NVFP4 GEMM` — the intended kernel, autotuned, from a local cache. The failed download is real but is not costing us the kernels. Downgraded from "largest single lead" to "worth pre-staging so it stays true across upgrades."

### The measurement that was decisive, and why it was `spec-off`

Turning speculation off collapses tokens-per-pass to exactly 1 and removes the draft passes from the byte count. Then `bytes_per_pass = 245 / decode_rate` measures the verification path alone:

- **ratio ≈ 1.0** — the path is clean, and the entire 1.64x was speculation's draft overhead. The ceiling is real and the way up is higher acceptance, not config work.
- **ratio still ≫ 1.5** — there is genuine excess traffic in the base forward pass, and it is worth chasing.

**Name the confound before running it.** `spec-off` changes two things at once, because the CUDA-graph mode is downstream of it:

```
CUDAGraphMode.FULL_AND_PIECEWISE is not supported with spec-decode for attention
backend FlashInferBackend; setting cudagraph_mode=PIECEWISE
```

With speculation on, FlashInfer forces graphs down from FULL to PIECEWISE. Turning speculation off restores FULL. So a faster `spec-off` result cannot distinguish "speculation was costing more than it returned" from "PIECEWISE graphs are expensive on this box". `attn-triton` separates them: if TRITON_ATTN keeps full graphs under spec-decode, it isolates the graph mode from the speculation.

### The lead that is not in the config at all

```
WARNING [flashinfer.py:441] Failed to connect to NVIDIA artifactory:
Failed to resolve 'edge.urm.nvidia.com' (Temporary failure in name resolution)
```

FlashInfer tries to download prebuilt kernels at startup and cannot, because this box has no route to the internet — which is the entire point of it. It then proceeds on JIT-compiled or fallback kernels, logging a warning and no error.

This is the same shape as the failure `config/models.yml` already records for the previous MoE brain: *"REQUIRED for that MoE on Spark, or it falls back to Marlin and runs 2.5x slower."* A silent kernel downgrade, visible only as a line in a startup log nobody greps for.

It is also the one finding here that **local-first makes structural rather than incidental**: every future FlashInfer upgrade will hit it, on this box, forever. The fix is to pre-stage the kernel cache into the image or a mounted volume, not to give the Spark internet access. Unquantified so far — it may cost nothing, or it may be the largest single factor in the 1.64x. Nothing above assumes either.

---

### A note on script names in earlier lessons

Lessons #16 and #17 reference `benchmark_brain.sh`, `serving_audit.sh`,
`specdecode_probe.sh` and friends. Those were accurate when written. They have
since been consolidated into a single self-contained entry point,
`scripts/benchmark.sh` — eight scripts had accumulated, three of them carrying
their own drifting copy of the credential redactor. The earlier text is left as written rather than retconned: it records
what was true at the time, and the mapping is `benchmark_brain.sh` →
`benchmark.sh quick`, `serving_audit.sh` → `benchmark.sh audit`,
`bandwidth_probe.sh` → `benchmark.sh bandwidth`, and the sweep/probe pair →
`benchmark.sh` (the full matrix).

### Corroboration — and two config bugs that outrank all of it

Later field reports on this same model, gathered after the above was written, sharpen the picture considerably. Treating them as claims to test rather than facts:

**The cross-check that matters most.** One reported recipe took an **FP8** build of this model from 7.88 to **58.5 tok/s** single-stream through decode strategy alone — speculative decoding plus prefix caching, weights untouched, output-preserving. FP8 weights are roughly **twice the bytes per token** of our NVFP4 build. If that box sustains 58.5 tok/s while reading ~27 GB/token, then our 15–17 tok/s while reading ~13.5 GB/token is not a bandwidth wall. Same hardware, half the bytes, a third of the speed. **That is the strongest independent evidence yet that our number is config-limited, and it does not depend on trusting any single benchmark.**

**But calibrate the expectation honestly.** That 7.4× headline is partly the repair of a broken baseline, not pure technique. 7.88 tok/s is *below* the non-speculative roofline for an FP8 27B on this bus (~10 tok/s), which means their starting point was already malfunctioning — plausibly the exact prefix-caching bug below. Ours at 15–17 against a ~20 tok/s NVFP4 roofline is a *healthy* baseline. **Expect roughly 2–3× from working speculation here, not 7×.** Anyone quoting 58 tok/s as our target is comparing against someone else's broken starting point.

**Two configuration bugs, both of which apply to us, and both of which outrank speculative decoding:**

> **Both REFUTED on this box, 2026-08-26.** Neither reported bug reproduces here. Prefix caching serves 37.4% of a repeated identical prefix; the KV cache holds 745,115 tokens against an advertised 262,144. Field intel from other people's boxes is a reason to *measure*, not a reason to believe. Left in place below as written, because the reasoning that made them worth testing was sound even though both answers came back no.

1. **Prefix caching silently disabled.** vLLM is reported to turn prefix caching off for this model's card parameters *even though the flag is accepted*. We pass `--enable-prefix-caching` and have never confirmed it took effect. If it is inert, every OpenClaw turn reprocesses the entire conversation prefix. In agentic coding — long shared context, many short turns — that costs far more than draft-token tuning can ever win back, and it fails completely silently.

2. **The advertised context may not be reachable.** The default attention backend is reported to cap usable context near 60K at **0.80** utilisation, with FLASHINFER fitting ~170K. We declare `max_model_len: 262144` at **0.45** utilisation — half that memory budget — and pin no backend at all. If the KV cache cannot hold 262144 tokens, that number is a claim the server cannot honour, and it surfaces as a mid-session failure rather than a startup one.

Both are measurable from outside the container, so `scripts/benchmark.sh audit` measures them rather than reading the log and hoping. Prefix caching is tested by sending a long prefix twice and comparing TTFT; context is tested by comparing vLLM's actual allocated KV cache size in tokens against the advertised `max_model_len`.

**Order changed as a result.** The audit runs first. A dead prefix cache or an unreachable context window is worth more than the entire speculative-decoding question, and both are cheaper to fix.

**Why the attention backend matters unusually much on this model.** It is a hybrid: ~48 GatedDeltaNet linear-attention layers plus ~16 full-attention layers. The backend choice governs the full-attention layers and the KV cache they need, which is why it shows up as a *context capacity* limit rather than only a speed one — and why the reported FLASHINFER context win is measured **without** an FP8 KV cache. That trades against our `kv_cache_dtype: fp8` rather than stacking with it, so those two settings must be changed one at a time or the result is uninterpretable.

**On DFlash2.** The strongest reported configs (~50 tok/s greedy median, 148 at 8 streams, 258 at 32) run **SGLang**, not vLLM. That is a different serving engine: different container, different arguments, and every launcher, watchdog, and health check in this repo is vLLM-shaped. It is a plausible future direction and explicitly **out of scope** for this branch — chasing it means porting the stack, not editing a config field. Exhaust the vLLM-side levers first; they are free and they are already instrumented.

This also retires an earlier claim that NVFP4 was vLLM-only and unsupported on SGLang. Multiple reported SGLang+NVFP4 configs contradict it. Noted so that it is not carried forward as a constraint that no longer holds.

### Levers, including the one initially missed

If the roofline turns out to be real, these still break it — a ceiling on *plain* decode is not a ceiling on *throughput*:

1. **MTP speculative decoding** — shipped since v5.0, in `speculative_config`, **never verified**. `scripts/benchmark.sh audit` diffs `vllm:spec_decode_*` counters across a known generation; zero drafts is conclusive.
2. **N-gram / prompt-lookup decoding** — needs no drafter and no extra weights: it proposes continuations by finding repeats of the current suffix earlier in context. Nearly free, and unusually strong on **agentic coding**, where the model reproduces long verbatim spans from files already in context. **This was omitted from the first pass at this analysis, which is precisely the kind of gap that makes "no config can beat X" an unsafe claim.** Now a first-class candidate in the sweep.
3. **Draft length** — `num_speculative_tokens: 5` was never compared against anything; the community day-zero recipe used 2. Rejected tokens still cost verification, so longer is not monotonically better.
4. **Attention backend / KV dtype** — `kv_cache_dtype: fp8` is only honoured by some backends. A silent BF16 fallback doubles KV bytes read per token, with no error.
5. **Lower-bit weights** — below NVFP4 is fewer bytes/token and a strictly higher roofline, at a quality cost.
6. **Batching** — already free, already available, just not what a single-stream number measures.

### Why acceptance rate is workload-dependent

The default benchmark prompt writes fresh prose and code from nothing — close to the **worst case** for prompt-lookup, which pays off when output echoes context. A poor `ngram` result against it would *not* generalise to real agentic coding over files in context. The sweep takes `PROMPT` for this reason; a verdict from the default prompt alone is not a verdict on your actual workload.

### Order of operations

```bash
bash scripts/benchmark.sh            # everything: audit, full matrix, then the report
```

Or one piece at a time:

```bash
bash scripts/benchmark.sh audit      # is prefix caching live? is 262K reachable?
bash scripts/benchmark.sh bandwidth  # ceiling real, or path moving too many bytes?
bash scripts/benchmark.sh quick      # decode + TTFT of the running config
bash scripts/benchmark.sh list       # what is in the matrix, what has been measured
```

The audit runs first because it can find a problem that makes the rest moot:
a dead prefix cache dominates real agentic cost, and an unreachable context
window invalidates the headline spec in README. Results accumulate in
`docs/BENCHMARKS.md`, which is generated, never authored.

The first two are read-only and safe against production. The sweep restarts Brain repeatedly.

### Key lesson — confirmed, and it is about method, not hardware

Two divisions produced a confident ceiling, and the ceiling was built on two unmeasured inputs and an incomplete list of techniques. The arithmetic was fine; treating it as a **result** rather than a **hypothesis** was not. A roofline you have not measured is a guess with units attached.

Measurement settled it: **every input was wrong** — bandwidth by 11%, checkpoint size by 70%, and the unit itself, which should have been bytes per *forward pass* and not per token. The estimate still landed near the observed 16 tok/s. A wrong model that reproduces the right number is the hardest kind to catch, and the only thing that caught it was refusing to skip the measurement.

**The sharper lesson is the second-order one.** The tool built to test the hypothesis was itself wrong three times, and every failure pointed the same way — toward a confident verdict rather than an admission of ignorance:

| What broke | What it reported | Truth |
|---|---|---|
| `print s+0` on an absent/timestamp-polluted counter | speculation DEAD | 350 drafted, 53% accepted |
| 1.8x TTFT threshold borrowed from dense transformers | prefix cache INERT | 37.4% hit rate |
| `bytes = bandwidth / tokens`, ignoring speculation | "roofline is REAL" | 1.64x, headroom exists |

The third is the one to remember. It would have **confirmed the hypothesis the script existed to test**, by construction, and printed a paragraph explaining that config tuning could not help. Instrumentation is not neutral: it encodes the assumptions of whoever wrote it, and it fails toward them.

And one more, cheaper to state and easier to repeat: a single reading of a noisy proxy is not a measurement. The prefix-cache TTFT ratio came back 0.90x and then 4.51x on the same config minutes apart. The first reading was explained with a confident, plausible, wrong story about hybrid attention layers. Two readings would have cost sixty seconds.

Test the claim. Then test the instrument. Then write the lesson.

Related: Lesson #12 (bandwidth is physics), Lesson #16 (the trade made knowingly), Lesson #17 (tooling that cannot report a problem manufactures false certainty — including tooling made of arithmetic).

---

## 19. SGLang Tested — Slower, and the Claim Was Never About the Engine

**Status: measured 2026-08-26.** Branch `brain-sglang-eval`. One row, `sglang-baseline`, on the same weights, same port, same box.

Lesson #18 left SGLang as "a plausible future direction, explicitly out of scope" on the strength of community reports of ~50 tok/s single-stream. It is no longer out of scope, because it took about twenty minutes to test and the answer is unambiguous.

| Engine | Speculation | Decode | Aggregate @8 |
|---|---|---|---|
| vLLM | MTP, 3 draft tokens | 19.66 tok/s | 108.9 |
| vLLM | off | 12.04 tok/s | 84.1 |
| **SGLang** | **off (no drafter)** | **9.79 tok/s** | **73.0** |

Like for like — both engines with speculation off — **SGLang is 19% slower**, 9.79 against 12.04, and 13% lower on aggregate. Against the tuned vLLM config it is less than half the speed.

### What that settles

**None of the reported SGLang advantage comes from the engine.** Its forward pass is *less* efficient than vLLM's on this hardware. The reported configs pair SGLang with a DFlash2 drafter, and the drafter is doing all the work.

The roofline makes this quantitative rather than a hunch. 12.04 tok/s is one forward pass over the weights; no engine changes that. So a reported 50 tok/s requires:

```
from vLLM's base:    50 / 12.04 = 4.15 tokens per forward pass
from SGLang's base:  50 /  9.79 = 5.11 tokens per forward pass
```

We get 2.4–3.7 from MTP. **SGLang starts 19% further back and therefore needs an even better drafter to reach the same place.** Porting the stack to chase it would be paying a known 19% penalty for access to a drafter that may or may not exist for this checkpoint.

**So the lever is the drafter, not the engine** — and drafters are available under vLLM, where every launcher, watchdog recovery path, health check and API-key provision already works. That is now `brain.speculative_draft_model` and the `spec-eagle3` rows, BLOCKED until a checkpoint is pinned.

### Two things the run cost, both cheap and both bugs

**A wrong quantization guess.** The committed `sglang:` block suggested `quantization: modelopt_fp4`. The checkpoint declares `compressed-tensors`, and SGLang refused to start:

```
Quantization method specified in the model config (compressed-tensors) does not
match the quantization method specified in the `quantization` argument (modelopt_fp4)
```

Blanking it, so the engine reads the checkpoint instead of being told, fixed it. A guess in a config comment is still a guess.

**A resume check that skipped the row it had just enabled.** `sglang-baseline` was already in the ledger as BLOCKED from the full matrix. The skip logic only asked whether the *name* appeared, so pinning the image and re-running printed:

```
SKIP sglang-baseline — already measured (--redo to repeat)
```

It had never been measured. BLOCKED and FAILED record the *absence* of a measurement and are exactly the rows you return to after removing the blocker. They now retry and say why. Same family as the four measurement bugs in #18: the tool reported a clean run having done no work.

### Key lesson

A rumour with a number in it is worth twenty minutes to test, and the test is worth designing so it can distinguish *which part* of the claim is true. Measuring SGLang **without** a drafter looked like the less interesting experiment; it was the one that produced the answer, because it isolated the engine from the technique. Had we run SGLang with a drafter first and seen a speedup, we would have concluded "switch engines" and been wrong about why.

Related: #18 (the roofline that makes these claims checkable), #12 (bandwidth is physics).

---

## Model History (Quick Reference)

| Release | Model | Architecture | Active Params | tok/s | Vision | Notes |
|---|---|---|---|---|---|---|
| v1.0 | Qwen3.5-27B-FP8 | Dense | 27B | ~14–30 | No | Too slow — bandwidth ceiling |
| v2.0 | Nemotron-3-Nano-30B-A3B-FP8 | MoE | 3B | ~35–45 | No | Weaker on coding/reasoning |
| v3.0 | Qwen3.5-35B-A3B-FP8 | MoE | 3B | ~49 | No | Superseded by v4.0 |
| v4.0 | Qwen3.6-35B-A3B-FP8 | MoE + DeltaNet | 3B | ~53 | No | Same intelligence as v3, +DeltaNet, 262K |
| **v4.2.1** | **Qwen3.6-35B-A3B-FP8** | **MoE + DeltaNet** | **3B** | **~53** | **No** | **Prior baseline. Available via `git checkout v4.2.1`. Watchdog v4.2 stack** |
| v5.0 | Qwen3.8-27B-NVFP4 | Dense multimodal | 27B | ~17 | Yes | Speed traded for vision + higher per-token reasoning |
| **v5.1** | **Qwen3.8-27B-NVFP4** | **Dense multimodal** | **27B** | **~17** | **Yes** | **Superseded by v5.2. Loopback bind, auto-provisioned API key, persisted compile cache. See #17** |
| **v5.2** | **Qwen3.8-27B-NVFP4** | **Dense multimodal** | **27B** | **~17** | **Yes** | **Current — same model and weights. `num_speculative_tokens` 5 -> 3. Output-preserving. +29.5% same-session vs mtp5; ~17 day to day, acceptance-dependent. See #18** |

---

*Last updated: August 26, 2026 — Lesson #18, throughput question ANSWERED: roofline real at 12 tok/s, draft length was the bug, 15.18 -> 19.66 tok/s*
