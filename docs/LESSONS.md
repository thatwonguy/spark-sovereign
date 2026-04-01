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

---

## 8. Model Revisit: Back to 35B-A3B-FP8 (with SM121 Kernels)

**Context:** Lesson 4 recorded the switch FROM 35B-A3B TO 27B-FP8, citing MoE quadratic attention at long contexts and better SWE-bench coding scores for the dense 27B. That reasoning was sound — but it assumed the 35B-A3B was actually running as fast as documented (~50 tok/s). It was not.

**Root cause discovered:** `vllm/vllm-openai:cu130-nightly` contains a CMake arch guard bug — it compiles `"12.0f"` instead of `"12.0a"` for the SM121 architecture check. This silently excludes the GB10 from native kernel compilation, causing vLLM to fall back to generic paths. Real-world measured throughput for both 27B-FP8 and 35B-A3B on this image: **12–15 tok/s**, not 50. All previous tok/s estimates in config comments were based on incorrect assumptions about the image behavior.

This was confirmed via NVIDIA Developer Forums (multiple independent benchmarks with llama-benchy v0.3.3, April 2026).

**New image:** `hellohal2064/vllm-qwen3.5-gb10:latest` — community-built ARM64/GB10 image that fixes the CMake bug and compiles SM121-native kernels. Independently verified at **48–50 tok/s** for 35B-A3B-FP8 on a single DGX Spark, with 1M context via YaRN.

**Required env vars for FP8 Marlin backend on SM121 (set in models.yml extra_env):**
```
VLLM_FLASHINFER_MOE_BACKEND=latency
VLLM_TEST_FORCE_FP8_MARLIN=1
VLLM_MARLIN_USE_ATOMIC_ADD=0
```
Without these, the MoE FP8 path does not engage the Marlin kernel and throughput reverts to ~13 tok/s.

**Why 35B-A3B over 27B-FP8 at equal real-world speed:**
- ~35 GiB FP8 weights vs ~27 GiB — only slightly larger footprint
- MoE: only ~3B params active per token — lower compute per token than dense 27B
- More headroom left for KV cache with the same 0.75 util (~56 GB vs ~64 GB prior — less needed because the model is faster and can serve the same context with less buffering)
- Outperforms 27B-FP8 on vision, agent, and multi-step reasoning benchmarks at this token rate

**Open question — MoE long-context cliff (from Lesson 4):** The quadratic attention concern at 100K+ context is real for MoE full-attention layers, but the 35B-A3B uses sparse MoE only in the FFN layers, not attention. Attention is standard multi-head and scales the same as dense models. The long-context degradation observed previously may have been a throughput perception issue (slow model feels worse at long context) rather than an architectural ceiling. Testing will confirm.

**What to watch:** If long agentic sessions (100K+ tokens) feel noticeably slower or degraded vs the 27B-FP8, that is the MoE attention cliff reasserting itself. Roll back via the swap-back comment block in `config/models.yml`.

*Last updated: April 1, 2026*
