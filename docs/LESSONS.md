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

*Last updated: March 2026*
