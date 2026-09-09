# TODO

Open question driving this branch:

> **Any updates on the best model, best drafter, and best speed for the Spark?**

Every external claim below was checked against HuggingFace, Docker Hub, the
vLLM tracker and this repo's own LESSONS.md before being written down. Where a
check was not possible it says so.

---

## Where we actually are (measured, this repo)

| | Config | Decode |
|---|---|---|
| Live | Qwen3.8-27B NVFP4 + DSpark drafter, 7 tokens | **23.9 tok/s** (`spec-dspark7`, docs/BENCHMARKS.md) |
| Non-speculative floor | same model, no drafter | 12.04 tok/s (LESSONS #19) |
| Backend/KV/util sweep | every row landed inside | 15.07–15.19 tok/s (LESSONS #19 addendum) |
| Day to day | working box, not sweep conditions | ~17 tok/s (config/models.yml) |
| Rollback | `git checkout v4.2.1` — FP8 MoE, no vision | ~53 tok/s |

**Quote 23.9, not 15-17.** External briefs frame the goal as "15-17 tok/s ->
50 tok/s". 15-17 is the *non-speculative* band; the DSpark drafter shipped in
LESSONS #20 and the live config measures 23.9. A 50 tok/s target is therefore
**~2.1x, not ~3x**.

---

## The reframe: LESSONS #19 already tested SGLang, and it lost

Merged as PR #21, branch `brain-sglang-eval`, measured 2026-08-26. Same
weights, same port, same box:

| Engine | Speculation | Decode | Aggregate @8 |
|---|---|---|---|
| vLLM | MTP, 3 draft tokens | 19.66 tok/s | 108.9 |
| vLLM | off | 12.04 tok/s | 84.1 |
| **SGLang** | **off** | **9.79 tok/s** | **73.0** |

Like for like, **SGLang is 19% slower** on this hardware. Its conclusion, verbatim:

> *"None of the reported SGLang advantage comes from the engine... the drafter
> is doing all the work. So the lever is the drafter, not the engine — and
> drafters are available under vLLM, where every launcher, watchdog recovery
> path, health check and API-key provision already works."*

The roofline, from #19: reaching 50 tok/s needs **4.15 tokens per forward pass
from vLLM's base, or 5.11 from SGLang's**. Switching engines starts you 19%
further back and demands a *better* drafter to arrive at the same number.

**So the goal of this branch is not "port to SGLang". It is "get the DFlash2
drafter running", and vLLM is the first place to try.**

---

## What changed since #19 — and it favours vLLM

`config/models.yml` records that `incoai/Qwen3.8-27B-DFlash2` was **rejected by
our pinned image**: the checkpoint declares `DFlash2DraftModel`, the build
registers `DFlashDraftModel` (no "2"), so it silently loaded DFlash v1. The
comment says it needs vLLM built from PR #52816, "which our pinned image may
predate".

**Verified 2026-09-08: vLLM PR #52816 is MERGED.**

```
vllm-project/vllm#52816  "[Spec Decode] DFlash2: local convolution + candidate selector"
state: closed   merged: True   merged_at: 2026-08-21   base: main
```

Our pinned image is `vllm/vllm-openai:qwen38-arm64-cu130`. If a build of it
dated after 2026-08-21 exists for arm64/SM121, **DFlash2 may run under vLLM
with no engine penalty at all** — capturing the drafter gain while keeping the
launcher, watchdog, health checks and API-key path that already work.

That is the highest-value experiment on this branch, and it is cheap.

---

## Verification results — what actually exists

Checked 2026-09-08.

| Artifact | Result |
|---|---|
| `unsloth/Qwen3.8-27B-NVFP4` (our brain) | HF 200 — exists |
| `RadixArk/Qwen3.8-27B-DSpark` (our drafter) | HF 200 — exists |
| `incoai/Qwen3.8-27B-DFlash2` | HF 200 — exists; our image rejects it |
| `hamichok/Qwen3.8-27B-DFlash2-NVFP4-modelopt` | HF 200 — **exists**, 173 downloads, updated 2026-08-29, apache-2.0, modelopt NVFP4 re-quant of the `incoai` base |
| `lmsysorg/sglang:dev-qwen38-27b-dflash2` | Docker Hub 200 — exists, **arm64 present** (14.4 GB), updated 2026-08-22 |
| `MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark` | **GitHub**, not HuggingFace (HF 401 / GitHub 200) |
| `hasso5703/dgx-spark-qwen38` | **GitHub**, not HuggingFace (HF 401 / GitHub 200) |
| vLLM PR #52816 | merged 2026-08-21 into main |

**One flag on the drafter:** `hamichok/...-modelopt` is tagged **`rtx5090`**,
which is **sm_120**. The Spark's GB10 is **sm_121**. Close, not identical, and
#11 exists precisely because SM12.1 needs its own environment. Do not assume
the kernels load; that is a test, not a given.

Unverified, because it cannot be checked from outside the box: the claimed
50 tok/s / 148 @ c8 / 258 @ c32, and the "MiaAI-Lab quantized-lm_head fix".

---

## Plan

### Path 1 — DFlash2 under vLLM (try first, cheap)

1. Find a `vllm/vllm-openai` arm64/CUDA-13 tag built after 2026-08-21.
2. Confirm the DFlash2 registration is present before downloading weights —
   models.yml already gives the one-liner:
   ```
   docker run --rm --entrypoint bash vllm/vllm-openai:<tag> \
     -c 'grep -rl dflash /usr/local/lib/python3*/dist-packages/vllm/ | head'
   ```
   No hits means that build cannot serve it and no config field will change it.
3. Pull `hamichok/Qwen3.8-27B-DFlash2-NVFP4-modelopt`, wire it as
   `{"method":"dflash","model":<path>,"num_speculative_tokens":7}`, and run
   `bash scripts/benchmark.sh --only spec-dflash7,spec-dflash3` — the rows are
   already defined.
4. Compare against `spec-dspark7` at 23.9 tok/s.

If this works, the branch is done without touching the engine, and workstreams
2/3/5 below mostly evaporate.

### Path 2 — SGLang + DFlash2 (fallback only)

Only if no vLLM build registers DFlash2 for arm64/SM121. You are then paying
the measured 19% engine penalty to reach the drafter, so the drafter must win
by more than that before this is worth shipping.

Infrastructure already exists — do not rebuild it:

- `config/models.yml` has an `sglang:` block (`docker_image`,
  `disable_radix_cache`, `speculative_algorithm`, `speculative_num_steps`,
  `speculative_draft_model_path`). Uncomment **only** `docker_image` to enable;
  everything else falls back to `brain:` so both engines serve identical
  weights at the same port under the same served name.
- `scripts/benchmark.sh` already treats SGLang as a first-class row and records
  BLOCKED while no image is pinned.
- Candidate image to pin: `lmsysorg/sglang:dev-qwen38-27b-dflash2` (arm64, verified).

**Known trap, already documented in models.yml:** `boot_sequence.sh`,
`watchdog.sh` and the numbered scripts do not read the `sglang:` block, and
watchdog recovery calls `start_brain_ad_hoc.sh`, which starts **vLLM**. A crash
mid-session silently reverts the engine. Stop the watchdog timer for any SGLang
work — `benchmark.sh` already does this for you.

---

## Workstreams

**1. Streaming tool calls through OpenClaw — HARD BLOCKER.**
LESSONS **#8** is the precedent and the reference is correct: vLLM 0.14.0rc2's
hermes parser returned raw `<tool_call>` XML as text content instead of parsed
`tool_calls` in streaming mode. OpenClaw always sends `stream: true` with no
API-level way to disable it, and `hermes`, `qwen3_coder` and `qwen3_xml` all
failed. That killed Qwen3-Next-80B outright.
Whatever stack ships must pass this with thinking ON and a tool supplied.
Claimed-but-unverified: an SGLang issue where thinking + tools + `qwen3_coder`
emits token-ID-0 repeatedly, and one returning empty `tool_calls[]` with XML in
content. Check the tracker before relying on either.

**2. Prefix caching.** Correct references are **#12** (the "big win for
OpenClaw's repeated memory.md preprompt" note), **#16** (promoted to a
first-class field; also fixed `start_brain_ad_hoc.sh` hardcoding
`--enable-prefix-caching` while `03_vllm_servers.sh` never passed it) and
**#18** (measured 37.4% hit rate; on by default in vLLM V1, so omitting the
flag does not disable it). Under SGLang the analog is RadixAttention —
`disable_radix_cache: false` in the existing block, note the inverted sense.
Path 1 keeps vLLM's behaviour unchanged and this becomes a non-issue.

**3. Agent memory.** Per #2, OpenClaw owns the capabilities; the engine is a
stateless OpenAI-compatible endpoint. Switching should be a `base_url` /
model-ID edit with memory intact because it was never in vLLM. Confirm against
OpenClaw's docs rather than assuming. Path 1 does not change the endpoint at all.

**4. Boot and watchdog.** #14 (4-5 min load window is normal) and #15
(watchdog is idempotent and deliberately framework-agnostic) are the correct
references. Only Path 2 needs work here; keep SGLang specifics out of the
watchdog per #15.

**5. GB10 flags.** #11 is the correct reference for SM12.1 needing its own
environment. For Path 2: `--quantization modelopt_fp4`,
`--speculative-draft-model-path`, `--speculative-draft-model-quantization
modelopt_fp4`, `--speculative-dflash-block-size 6`, `--fp4-gemm-backend
flashinfer_cutlass`, `--mem-fraction-static`. Note #19 already burned a run on
a wrong `quantization:` guess — the checkpoint declared `compressed-tensors`
and SGLang refused to start. Leave it blank and let the engine read the
checkpoint.

**6. Rollback.** The vLLM + DSpark path at 23.9 tok/s stays intact and is the
thing to beat. Nothing is deleted until the replacement is measured on the box.

---

## Merge gate — on the actual Spark

1. Streaming tool calls return structured `tool_calls`: no XML in content, no token-0 loop
2. Measured single-stream tok/s in BENCHMARKS.md **beats 23.9**
3. Prefix/radix caching confirmed active for the `memory.md` preprompt
4. Agent memory verified preserved if the endpoint changed
5. Watchdog and boot sequence recover the shipped engine cleanly
6. The vLLM + DSpark rollback path is intact

---

## Flash-Next — do not reopen

SGLang's day-0 Qwen3.8-Flash-Next support does **not** unlock this box, and it
confirms the shelving rather than reversing it (write-up pending in PR #17):

- The headline **540 tok/s at batch 1 is B200 TP4** — four datacenter GPUs at
  ~8 TB/s. This box is one GB10 at 273 GB/s.
- Its efficiency win is **offloading the 51.2B n-gram table to host memory**,
  saving 23.5 GiB VRAM per GPU and lifting KV capacity ~78.5%. Unified memory
  means host and device are one 121 GiB pool here, so that offload frees
  nothing. The headline optimization is the one that structurally cannot apply.
- Its verified hardware list is H200 / B200 / B300 / GB300. **GB10 is absent**,
  and support is not in a tagged release.

Reopen triggers, watch only: a GB10 or single-node cell appearing in SGLang's
verified matrix; a KV-quantization path for QSA that removes the BF16 KV
requirement; **IndexShare MTP** (reuses target QSA index selections across
draft steps) — which matters only combined with a KV unlock, not alone.
