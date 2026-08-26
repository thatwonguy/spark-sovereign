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

## Model History (Quick Reference)

| Release | Model | Architecture | Active Params | tok/s | Vision | Notes |
|---|---|---|---|---|---|---|
| v1.0 | Qwen3.5-27B-FP8 | Dense | 27B | ~14–30 | No | Too slow — bandwidth ceiling |
| v2.0 | Nemotron-3-Nano-30B-A3B-FP8 | MoE | 3B | ~35–45 | No | Weaker on coding/reasoning |
| v3.0 | Qwen3.5-35B-A3B-FP8 | MoE | 3B | ~49 | No | Superseded by v4.0 |
| v4.0 | Qwen3.6-35B-A3B-FP8 | MoE + DeltaNet | 3B | ~53 | No | Same intelligence as v3, +DeltaNet, 262K |
| **v4.2.1** | **Qwen3.6-35B-A3B-FP8** | **MoE + DeltaNet** | **3B** | **~53** | **No** | **Prior baseline. Available via `git checkout v4.2.1`. Watchdog v4.2 stack** |
| **v5.0** | **Qwen3.8-27B-NVFP4** | **Dense multimodal** | **27B** | **~17** | **Yes** | **Current — speed traded for vision + higher per-token reasoning** |

---

*Last updated: August 16, 2026 — v5.0 swap*
