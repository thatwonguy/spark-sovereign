# Serving Configuration Benchmarks — Qwen3.8-27B on DGX Spark (GB10)

<!-- GENERATED FILE. Do not edit by hand. -->
<!-- Source of truth: docs/benchmarks.jsonl (append-only ledger). -->
<!-- Regenerate: bash scripts/benchmark.sh render -->

## What this file is

A record of serving configurations **actually measured on this machine**, 
produced by `scripts/benchmark.sh`. It exists so that anyone — including 
a future LLM session with no memory of this work — can answer three questions 
without re-deriving them:

1. **What has already been tried?** Don't re-run what's in the table below.
2. **Which numbers can be trusted?** See the Validity column. This is the important one.
3. **What should be used right now?** See Recommendation.

### How to read the Validity column — read this before using any number

| Validity | Meaning |
|---|---|
| `VALID` | Every requested parameter was confirmed in effect. The number measures what the config says it measures. |
| `PARTIAL` | Some parameters applied, others didn't. The number is real but is **not** attributable to the stated config. |
| `INVALID` | Requested parameters did not take effect. **Do not rank or cite this number.** |
| `BLOCKED` | Could not run — missing image or unconfigured engine. Absence of data, not evidence of badness. |
| `FAILED` | Server did not come up. The config itself may be unusable on this hardware. |

This distinction matters more than the throughput figures. vLLM accepts flags 
it then silently ignores — prefix caching on this model is a documented case. 
A benchmark of a config that never applied yields a real number attributed to 
the wrong cause, which is worse than no number, because it looks like evidence.

## Results

| Config | Engine | Validity | Decode | TTFT | Aggregate | Prefix reuse | Drafted | KV cache |
|---|---|---|---|---|---|---|---|---|

**Columns.** *Decode* is single-stream tok/s — what one interactive session feels like. 
*Aggregate* is total tok/s at the highest concurrency tested — what the box can do in 
parallel; it rises with batching and is not comparable to Decode. *Prefix reuse* is the 
TTFT speedup from re-sending an identical long prefix: **≥1.8x means prefix caching is 
genuinely working**, ~1.0x means it is inert regardless of what the flag says. *Drafted* 
is speculative tokens proposed during one generation — **0 means speculative decoding is 
configured but dead**. *KV cache* is the real context ceiling in tokens; if it is below 
`max_model_len`, the advertised context window cannot be reached.

## Recommendation

**No VALID measurements yet.** Nothing here should be used to choose a 
configuration. Run `bash scripts/benchmark.sh` on the Spark.

## Detail

---

*Generated 2026-08-26T12:10:46-07:00 from 0 ledger entries by `scripts/benchmark.sh render`.*
