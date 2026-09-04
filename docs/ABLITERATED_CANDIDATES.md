# Abliterated Brain Candidates — Qwen3.8-27B

Survey date: **2026-09-04**. Machine-readable source: [`config/brain_candidates.yml`](../config/brain_candidates.yml).

## What this file is

Every refusal-ablated variant of `Qwen/Qwen3.8-27B` that could plausibly serve as
this box's brain, ranked. `Qwen/Qwen3.8-27B` is the checkpoint our current brain
(`unsloth/Qwen3.8-27B-NVFP4`) was quantized from, so these are drop-in swaps of
the same model — not a different model family, not a different context length,
not a different tool-call parser.

**Nothing in this file has been measured on this machine.** Every number below is
a vendor claim copied off a model card. This file is the same kind of artifact as
the "four things the startup log says that nothing here has measured" block in
`models.yml`: written down so the next person reads it instead of re-deriving it,
and explicitly *not* evidence. `bash scripts/benchmark.sh` is what turns any of
these into a number, and `docs/BENCHMARKS.md` is where a number goes once it
exists.

Rank order answers one question: **most thoroughly unguardrailed while still fast
and capable on GB10.** Both halves count. A build with 0/100 refusals that decodes
at 4 tok/s loses to a build with 0/100 refusals that decodes at 20.

---

## Format triage — this decides most of the ranking

About thirty abliterated Qwen3.8-27B repos exist on HuggingFace. Most are
eliminated before capability is considered, because the brain is served by vLLM
in `vllm/vllm-openai:qwen38-arm64-cu130`:

| Format | Verdict on this stack |
|---|---|
| **NVFP4** (compressed-tensors) | Servable, and what the live brain already runs. An NVIDIA DGX Spark forum thread puts NVFP4 30–34% ahead of FP8 on decode for this model — their number, not ours; this repo has never measured the two on the same weights. |
| **AWQ W4A16** | Servable via Marlin, slower. One card reports W4A16 failing to serve at all on SM120 under vLLM 0.22 — unproven for AWQ-Marlin, but a warning. |
| **BF16 safetensors** | Servable and useless as a *serving* target — see below. Quantization source only. |
| **GGUF** | llama.cpp. Not this stack; loses MTP, vision and the DSpark path. |
| **MLX** | Apple Silicon. Cannot execute on GB10 at all. |
| **EXL3** | exllamav3, not vLLM. |

**Why BF16 is disqualified as a serving target, using our own numbers:** a dense
27B in BF16 reads ~55 GB per token. `models.yml` records this box achieving
**245 GB/s**. That is ~4–5 tok/s — worse than the measured 12.0 tok/s
non-speculative floor we already have, and a third of the 23.85 tok/s we
currently run at. The BF16 repos below are listed as *quantization sources*, not
as things to `vllm serve`.

**Reading the refusal numbers:** cards that publish a baseline put stock
`Qwen/Qwen3.8-27B` at **98–99 refusals per 100** harmful prompts. Lower is more
unguardrailed. KL divergence vs base on *benign* prompts is the collateral-damage
proxy — lower means less capability was disturbed getting there.

---

## The ranking

| # | Repo | Refusals /100 | KL vs base | Format | Size | MTP | Vision |
|---|---|---|---|---|---|---|---|
| 1 | `lyf/Qwen3.8-27B-Heretic-ARA-NVFP4-MTP-VL` | **0** | 0.0535 | NVFP4 W4A4 | 20.56 GB | bf16 ✓ | bf16 ✓ |
| 2 | `sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4` | *not published* | — | NVFP4 W4A4 g16 | 20.0 GB | bf16 ✓ | bf16 ✓ |
| 3 | `trohrbaugh/Qwen3.8-27B-heretic-ara` | **0** | 0.0535 | BF16 | ~55 GB | ✓ | ✓ |
| 4 | `twolven/Qwen3.8-27B-abliterated-AWQ-MTP` | 12 | 0.1191 | AWQ W4A16 g128 | 9.37 GiB | ✓ | bf16 ✓ |
| 5 | `msuiche/Qwen3.8-27B-abliterated-cyber-GLP-49` | ~19 equiv. | — | **LoRA rank-1** | **8.6 MB** | n/a | n/a |
| 6 | `JonathanColetti/Qwen3.8-27B-Uncensored` | 12 | 0.1191 | BF16 | ~55 GB | ✓ | ✓ |
| 7 | `wangzhang/Qwen3.8-27B-abliterated` | 19 | 0.0069 | BF16 | ~55 GB | ? | ? |
| 8 | `huihui-ai/Huihui-Qwen3.8-27B-abliterated` | *not published* | — | BF16 | 55.6 GB | ✓ | ✓ |
| 9 | `hotdogs/Qwen3.8-27B-abliterated` | 39 | 0.0001 | BF16 | ~55 GB | ✓ | ✓ |
| 10 | `shawnw3i/Huihui-Qwen3.8-27B-abliterated-AWQ-MTP` | *not published* | — | AWQ 4-bit | — | ✓ | ✓ |

All Apache-2.0, inherited from Qwen3.8.

### Why the order is what it is

**1 — `lyf/...-Heretic-ARA-NVFP4-MTP-VL`. Try this first.** The only build that is
simultaneously the most thoroughly ablated variant anyone publishes a number for
(claimed 0/100, from Heretic's Arbitrary-Rank Ablation) *and* already in the
format this box serves fastest. Everything else trades one of those away. The
detail that moves it above rank 2: its card says it was validated under
`vllm/vllm-openai:qwen38-x86_64-cu130` — **the x86_64 sibling of our exact pinned
image**. Same image family means the vLLM build almost certainly carries the
kernels. It does *not* mean the arch matches; they tested SM120 (RTX 5090), we
are sm_121a. That gap is the entire risk.

**2 — `sakamakismile/...-NVFP4`. The safe bet.** Ranks below 1 on the stated axis
because huihui publishes **no refusal number at all**, and their own card calls
the method "a crude, proof-of-concept implementation to remove refusals without
using TransformerLens." They deliberately *narrowed* the ablation — first 15
layers retained, only 18–51 touched — to protect base capability. Defensible
engineering, and by construction less thorough than a build claiming 0/100. What
it has that nothing else here does: **60,541 downloads last month.** That is the
only real operational evidence in this survey. Rank 1 has none.

**3 — `trohrbaugh/...-heretic-ara`.** The *source* of rank 1, not a competitor.
Its value is letting us build our own NVFP4 with llm-compressor against sm_121a
rather than inheriting someone's SM120 build — the clean path if rank 1
benchmarks badly. Same weights, our quantization. Do not serve directly.

**4 — `twolven/...-AWQ-MTP`.** Smallest servable build here, and the only AWQ one
whose upstream publishes both a refusal count and a capability delta (mean −0.5
pts across MMLU/ARC/HellaSwag/Winogrande). But 12/100 is not 0/100, and KL 0.1191
is an order of magnitude more benign-prompt drift than rank 1 — it paid more in
collateral damage and still ended up less uncensored.

**5 — `msuiche/...-cyber-GLP-49`. Ranked here on evidence; may be the best
practical answer.** It is an 8.6 MB rank-1 LoRA adapter, not a checkpoint. If
vLLM will serve it over the brain we *already run*, then base capability is
bit-identical, the DSpark drafter keeps its acceptance rate, there is no 20 GB
download, and it toggles off with a flag. Nothing else here can claim any of
that. Claimed 81.2% delivery vs 3.1% for base, with no measured over-refusal on
held-out harmless prompts. It sits at 5 because the whole proposition rests on
one unverified assumption — see the test order below.

**9 — `hotdogs/...`. Last on the stated axis, and the entry worth understanding.**
KL 0.0001 with 39/100 refusals is one fact stated twice: it barely moved the
weights, so it barely removed the guardrails. It is the most conservative build
in the survey, which is the opposite of the request. Keep it as the control in an
A/B.

---

## Watchlist — better on paper, unservable today

`0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF` claims **0–1/100
refusals at KL 0.0085** — a strictly better Pareto point than rank 1's 0/100 at
0.0535. It is `trohrbaugh/...-heretic-ara` plus two further ARA passes, and it is
**GGUF only**. If a safetensors or compressed-tensors build appears, it takes
rank 1.

**Unresolved conflict, and it undercuts rank 1:** this card states its own
upstream (trohrbaugh) measures **3/100** refusals at KL 0.0535. trohrbaugh's card
states **0/100** at KL 0.0535. Identical KL, different refusal count. One is
wrong and the cards do not say which. Do not treat rank 1's "0/100" as settled —
it is the single load-bearing claim in this ranking and it has a contradiction
attached.

## Disqualified

Full repo lists are in `config/brain_candidates.yml` under `disqualified:`, so
nobody re-surveys HuggingFace and re-finds them. One deserves calling out here:

> **`BennyDaBall/Qwen3.8-Uncensored-NVFP4-MTP` says NVFP4 and was built with
> llama.cpp.** NVFP4-in-GGUF is not compressed-tensors NVFP4 and vLLM will not
> load it. It is the easiest mistake in this survey to make, because the name
> looks exactly like the rank 1 candidate.

---

## The drafter problem — applies to every candidate

`models.yml` pins `RadixArk/Qwen3.8-27B-DSpark` as the speculative drafter and
records **23.85 tok/s** decode with it against a **12.0 tok/s** non-speculative
floor. That drafter was trained against the **unablated** Qwen3.8-27B.

Correctness is not at risk. Speculative decoding verifies every draft token
against the target, so a swapped target still emits exactly the target's
distribution. **Throughput is very much at risk.** Acceptance rate falls wherever
the ablated target diverges from what DSpark predicts — and the ablation exists
precisely to change the next-token distribution in the refusal-adjacent region.
Divergence there is the intended effect.

So 23.85 tok/s is a number about the *old pairing*. Every candidate starts with an
unknown decode rate between 12.0 and 23.85, and the honest expectation is that it
lands nearer the floor on exactly the prompts the swap was made for. **Benchmark
the pairing, not the model.** Rank 5 is the only entry immune to this, because it
does not change the target's weights.

---

## Test order

Cheapest-decisive-test first, not rank order.

**Step 0 — test rank 5 before downloading anything.** It is 8.6 MB against 20 GB,
and it answers a question that changes the value of the whole file: *will vLLM
serve a LoRA adapter over an NVFP4 quantized base?* If yes, rank 5 gives most of
the effect for none of the risk and the DSpark numbers survive intact. If no, the
candidate is worth zero and you have spent 8.6 MB finding out.

**Step 1 — pull rank 1 and rank 2 together.** 40 GB total, both NVFP4, both
servable. Benchmark them against each other and against the current brain.

**Step 2 — only if both fail on sm_121a:** pull rank 3 (BF16) and quantize it
locally with llm-compressor targeting sm_121a. That removes the SM120 variable
entirely.

### Downloading — read this first

`scripts/02_download_models.sh` builds its keep-list from the top-level sections
of `models.yml` and **archives any `/opt/models` directory no section claims**. A
candidate downloaded but not pasted into `models.yml` *will* be archived on the
next run of `02`. Two ways through it:

```bash
# A. Paste the candidate's brain block into models.yml FIRST, then:
bash scripts/02_download_models.sh

# B. Or pull it directly, outside the managed tree, to test before committing:
hf download lyf/Qwen3.8-27B-Heretic-ARA-NVFP4-MTP-VL \
    --local-dir /opt/models-scratch/qwen38-27b-heretic-ara-nvfp4
```

Option B keeps `02` from touching it and keeps the current brain intact for A/B.

### Before pulling 20 GB, confirm the image can serve it

Same check `models.yml` prescribes for the DFlash drafter — no hits means this
build cannot serve it and no config field will change that:

```bash
docker run --rm --entrypoint bash vllm/vllm-openai:qwen38-arm64-cu130 \
  -c "python -c 'import vllm; print(vllm.__version__)'; \
      grep -rl 'nvfp4\|NVFP4' /usr/local/lib/python3*/dist-packages/vllm/model_executor/layers/quantization/ | head"
```

### Benchmarking

```bash
bash scripts/benchmark.sh audit     # did the flags actually apply?
bash scripts/benchmark.sh quick     # decode + TTFT of the running config
```

Record results in `docs/benchmarks.jsonl` with a distinct `Model` value, and heed
the existing warning in `BENCHMARKS.md`: **compare rows only within a single
Model value.** A candidate's decode rate is not comparable to the current brain's
row unless both were measured under the same serving config.

---

## Ready-to-paste `brain:` blocks

Each block replaces the `brain:` mapping in `config/models.yml`. Every field is
carried over from the current block unchanged except `name`, `hf_repo`,
`local_path`, `served_name` — and, where noted, `gpu_memory_utilization`.

**Keep `extra_env.CUTE_DSL_ARCH: sm_121a` in all of them.** It is the GB10 arch
flag; none of these candidates were built with it.

> `gpu_memory_utilization: 0.45` currently yields ~55 GB. Ranks 1, 2 and 4 have
> smaller weights than the current brain, so the same 0.45 buys *more* KV cache,
> not less — leave it alone for the first benchmark so the comparison holds one
> variable. Tune after.

### Rank 1 — Heretic-ARA NVFP4

```yaml
brain:
  name: qwen38-27b-heretic-ara-nvfp4
  hf_repo: lyf/Qwen3.8-27B-Heretic-ARA-NVFP4-MTP-VL
  local_path: /opt/models/qwen38-27b-heretic-ara-nvfp4
  port: 8000
  bind_host: 127.0.0.1
  served_name: qwen38-27b-heretic
  docker_image: vllm/vllm-openai:qwen38-arm64-cu130
  gpu_memory_utilization: 0.45
  max_model_len: 262144
  kv_cache_dtype: fp8
  max_num_seqs: 16
  max_num_batched_tokens: 8192
  tool_call_parser: qwen3_coder
  reasoning_parser: qwen3
  enable_prefix_caching: true
  speculative_config: '{"method":"dspark","model":"/models/qwen38-27b-dspark","num_speculative_tokens":7}'
  extra_env:
    CUTE_DSL_ARCH: sm_121a
    VLLM_ALLOW_LONG_MAX_MODEL_LEN: 1
  limit_mm_per_prompt: '{"image":10}'
  speculative_draft_model: /opt/models/qwen38-27b-dspark
  speculative_draft_repo: RadixArk/Qwen3.8-27B-DSpark
  active_weight_gb:
```

### Rank 2 — Huihui NVFP4

Identical to rank 1 except:

```yaml
  name: qwen38-27b-huihui-nvfp4
  hf_repo: sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4
  local_path: /opt/models/qwen38-27b-huihui-nvfp4
  served_name: qwen38-27b-huihui
```

### Rank 4 — JonathanColetti AWQ + MTP

Same as rank 1 except the four identity fields and the drafter. This build ships
its **own MTP head**, so drop the external DSpark drafter and use self-speculation
— that also sidesteps the drafter problem above:

```yaml
  name: qwen38-27b-jc-awq
  hf_repo: twolven/Qwen3.8-27B-abliterated-AWQ-MTP
  local_path: /opt/models/qwen38-27b-jc-awq
  served_name: qwen38-27b-jc-awq
  speculative_config: '{"method":"mtp","num_speculative_tokens":3}'
  # and remove speculative_draft_model / speculative_draft_repo
```

`BENCHMARKS.md` already has `spec-mtp3` at 19.7 tok/s decode / 108.9 tok/s
aggregate / 64.4% acceptance for the current brain's own MTP heads — the closest
existing baseline for what this config should look like.

### Rank 5 — cyber LoRA over the existing brain

**No brain swap.** Current `brain:` block stays exactly as it is; the adapter
loads alongside. Sketch only — `03_vllm_servers.sh` has no LoRA path today, so
this needs testing ad-hoc first:

```bash
# via scripts/start_brain_ad_hoc.sh, adding to the vllm serve args:
#   --enable-lora \
#   --lora-modules cyber=/models/qwen38-27b-cyber-lora \
#   --max-lora-rank 8
# then request model "cyber" instead of "qwen38-27b" to get the ablated behaviour,
# and "qwen38-27b" to get the stock one — same server, both available.
```

That last property is why rank 5 is interesting despite ranking 5th: it is the
only option that gives an A/B on one running server, with no second download and
no loss of the DSpark numbers.

**Two things to verify before relying on it:** vLLM LoRA over an NVFP4 base is
not established to work at all, and the card documents a long-form generation
termination bug (2026-09-03) with grammar-constrained output as the workaround —
a real hazard for agentic loops.

---

## Provenance and scope

All ten are Apache-2.0 derivatives of Qwen3.8, published openly on HuggingFace.
Their authors scope them to research and controlled environments and state
plainly that these models will answer requests the base model refuses; huihui's
card puts that in the strongest terms of the set. That property is the point of
the swap, and it is also the operative fact for anything this box is later
pointed at — the brain sits behind OpenClaw on port 18789, and whatever is
attached downstream inherits the change. Worth deciding deliberately whether the
swap applies to the default brain or to a second served name alongside it, which
is what makes rank 5's two-models-one-server property more than a convenience.
