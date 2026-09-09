# TODO

Open question driving this branch:

> **Any updates on the best model, best drafter, and best speed for the Spark?**

Everything below is a research brief, not a decision. Items marked UNVERIFIED
came from an external LLM with web access and have not been checked against the
hardware, the HuggingFace repos, or the upstream issue trackers. Verify before
acting on any of them.

---

## Where we actually are (measured, this repo)

| | Config | Decode |
|---|---|---|
| Live | Qwen3.8-27B NVFP4 + DSpark drafter, 7 tokens | **23.9 tok/s** (`spec-dspark7`, docs/BENCHMARKS.md) |
| Non-speculative floor | same model, no drafter | 15.2 tok/s (`baseline`) |
| Day to day | working box, not sweep conditions | ~17 tok/s (config/models.yml) |
| Rollback | `git checkout v4.2.1` — FP8 MoE, no vision | ~53 tok/s |

**Correct the baseline before quoting any speedup.** External briefs describe
the target as "15-17 tok/s". That is the non-speculative floor, or the
day-to-day figure — not the current config. The DSpark drafter already shipped
(LESSONS #20). Any claim must be measured against **23.9 tok/s**, which makes a
50 tok/s target a ~2.1x improvement, not ~3x.

---

## Bet A — SGLang + DFlash2 on the existing 27B (this branch)

Same model, same 262K context, same ~15GB weights. Swap the serving stack
vLLM -> SGLang and the drafter DSpark -> DFlash2. This is a **speed** bet.

Claimed target: 50 tok/s greedy single-stream, 148 @ c8, 258 @ c32. UNVERIFIED.

Components to confirm exist and load on GB10 before any code is written:

| Piece | Claimed value | Status |
|---|---|---|
| Server | SGLang, not vLLM | verify GB10 support |
| Image | `lmsysorg/sglang:dev-qwen38-27b-dflash2` | UNVERIFIED — confirm tag, pin by digest |
| Target | Qwen3.8-27B NVFP4, BF16-head repo | we run `unsloth/Qwen3.8-27B-NVFP4`; confirm which is meant |
| Drafter | `hamichok/Qwen3.8-27B-DFlash2-NVFP4-modelopt`, block-size 6 | UNVERIFIED — repo may not exist |
| lm_head fix | MiaAI-Lab quantized-lm_head | UNVERIFIED |
| Parsers | `--reasoning-parser qwen3 --tool-call-parser qwen3_coder` | verify against SGLang docs |

Reference configs claimed to exist — clone and diff rather than reinventing:
`hasso5703/dgx-spark-qwen38` and `MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark`.
**Confirm both are real before relying on either.**

### Workstreams — one issue each

**1. Streaming tool calls through OpenClaw — HARD BLOCKER.**
A repeat of the bug class in LESSONS #8: OpenClaw always sends `stream: true`,
and a vLLM hermes-parser bug returned raw `<tool_call>` XML as `content`
instead of parsed `tool_calls`. The same class is claimed open in SGLang —
empty `tool_calls[]` with the XML in content, plus a Qwen3.8 loop emitting
token-ID-0 repeatedly when thinking + tools + `qwen3_coder` combine.
Test with thinking ON and a tool supplied; that is the claimed trigger.
Do not merge if this is broken. It is the same gate that killed the earlier model.

**2. Agent memory across the endpoint switch.**
Per LESSONS #2 and #7, memory lives in OpenClaw, not the serving engine —
vLLM/SGLang is a stateless OpenAI-compatible endpoint. So this should reduce to
a `base_url` / model-ID edit, with memory persisting because it was never in
vLLM. Confirm that, and confirm OpenClaw needs no re-onboarding.
Watch prefix caching: #13 depends on vLLM `--enable-prefix-caching` for the
repeated `memory.md` preprompt. SGLang's analog is RadixAttention. If the
preprompt is not cached, prefill cost balloons on every turn.

**3. Boot sequence and watchdog.**
Per #14/#15 both assume a vLLM container on port 8000,
`BRAIN_LOAD_GRACE_SECONDS=600`, and a container-name health check. SGLang's
load time, health endpoint and readiness signal all differ. Re-measure the load
window for the DFlash2 image — drafter and target both load. Keep the watchdog
framework-agnostic per #15.

**4. GB10 flags and drafter wiring.**
`--quantization modelopt_fp4`, `--speculative-draft-model-path`,
`--speculative-draft-model-quantization modelopt_fp4`,
`--speculative-dflash-block-size 6`, `--fp4-gemm-backend flashinfer_cutlass`,
`--mem-fraction-static`. Claim: the upstream compressed-tensors NVFP4 drafter
does NOT load in SGLang and needs the modelopt re-quant. The 27B does support
FP8 KV (unlike Flash-Next) — confirm SGLang `--kv-cache-dtype` under DFlash2.

**5. models.yml / config schema.**
Per #11/#12/#13 some flags are hardcoded in scripts and others read from yml.
Establish which is which before porting, or the SGLang path duplicates
hardcoded behaviour — the exact mistake #11 documents. Add SGLang fields
without removing the vLLM rollback path.

**6. Rollback safety.**
The vLLM 27B path stays fully intact; it has validated OpenClaw tool calling.
SGLang is added alongside, and nothing is deleted until SGLang is tested on the
Spark and merged.

### Merge gate — all six, on the actual Spark

1. Streaming tool calls return structured `tool_calls`: no XML in content, no token-0 loop
2. Agent memory verified preserved across the endpoint switch
3. Radix/prefix caching confirmed active for the `memory.md` preprompt
4. Measured single-stream tok/s recorded in BENCHMARKS.md and **beats 23.9**
5. Watchdog and boot sequence recover SGLang cleanly
6. vLLM rollback path intact

---

## Bet B — gh0stx (NOT this branch)

`promzeus/gh0stx-nvfp4`, a pruned Qwen3.5-397B: 141B total / 17B active,
~90GB weights, context capped at 65K on the DFlash path. UNVERIFIED.

**This is bigger, slower and lower-context than the 27B** — a knowledge bet,
not a speed bet, and the opposite of "smaller and faster". Against the current
config it costs ~75GB more weight, drops 262K context to 65K, and gives up
speed. It belongs on its own branch, evaluated after Bet A ships. Starting it
here would blow the memory budget and contradict the 262K baseline.

---

## Flash-Next — the LMSYS day-0 post does NOT reopen it

SGLang shipped day-0 Qwen3.8-Flash-Next support. Read closely, it confirms the
shelving in LESSONS #22 (pending in PR #17) rather than reversing it:

- The headline **540 tok/s at batch size 1 is B200 TP4** — four datacenter
  GPUs, ~180GB HBM3e each at ~8 TB/s. This box is one GB10 at 273 GB/s.
  Nothing in the post claims single-GB10 viability.
- Its efficiency win is **offloading the 51.2B n-gram table to host memory**,
  saving 23.5 GiB VRAM per GPU and boosting KV capacity ~78.5%. That is
  exactly the trick LESSONS #21 proved does not exist on GB10: unified memory
  means host and device are the same 121 GiB pool, so the offload frees
  nothing. The headline optimization is the one that structurally cannot apply.
- The KV boost we are excluded from is precisely what #22 needed. QSA forces a
  BF16 KV cache; without the freed VRAM we face raw BF16 KV against a
  nearly-full pool.
- The cookbook's verified hardware list is H200 / B200 / B300 / GB300.
  **GB10 is absent**, and support is not in a tagged release — build from the
  model-support PR. That is the same WIP territory that burned attempts 1 and 2.

**Reopen triggers — watch, do not act:**

- SGLang's verified hardware matrix adds GB10, or any single-node cell. It
  stops at GB300 today.
- A KV-quantization path for QSA appears, removing the BF16 KV requirement.
- **IndexShare MTP** — freezes and reuses the target QSA index selections
  across draft steps, cutting indexer time at long context. New since we
  shelved. Does not fix the KV pool by itself; it matters only in combination
  with a KV unlock.

---

## Filenames in this brief are inferred, not confirmed

The external brief guessed at `03_vllm_servers.sh`, `start_brain_ad_hoc.sh`,
`watchdog.sh`, `boot_sequence.sh` and `config/models.yml` from LESSONS #8-#15.
Open each file before writing changes. The six workstreams are the real
deliverable; the filenames are a hypothesis.
