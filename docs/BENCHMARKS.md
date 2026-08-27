# Serving Configuration Benchmarks — qwen38-27b-nvfp4 on DGX Spark (GB10)

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
it then silently ignores, and a benchmark of a config that never applied yields 
a real number attributed to the wrong cause — worse than no number, because it 
looks like evidence.

The same trap catches the checker. Both of the first two PROBLEMs this audit 
ever reported were false: a Prometheus counter summed at six significant digits 
read a live speculative decoder as zero, and a TTFT threshold borrowed from 
dense transformers read a prefix cache serving 55.9% of its tokens as inert. 
Prefer a counter that reports the mechanism over a timing proxy that reports 
its effect, and treat a threshold as a claim about a specific architecture.

## Results

| Config | Engine | Validity | Decode | TTFT | Aggregate | Prefix hit | Prefix TTFT | Drafted | Accepted | KV cache |
|---|---|---|---|---|---|---|---|---|---|---|
| `spec-mtp3` | vllm | VALID | 19.7 tok/s | 254 ms | 108.9 tok/s | 37.0% | 4.51x | 132 | 64.4% | 768,858 tok |
| `spec-mtp2` | vllm | VALID | 18.5 tok/s | 239 ms | 109.6 tok/s | 37.0% | 4.93x | 116 | 60.3% | 781,963 tok |
| `kv-bf16` | vllm | VALID | 15.2 tok/s | 261 ms | 80.3 tok/s | 37.4% | 4.27x | 265 | 29.4% | 736,567 tok |
| `baseline` | vllm | VALID | 15.2 tok/s | 263 ms | 78.6 tok/s | 37.4% | 4.36x | 215 | 39.5% | 736,567 tok |
| `attn-flashinfer` | vllm | VALID | 15.2 tok/s | 269 ms | 80.7 tok/s | 37.4% | 4.40x | 185 | 48.6% | 732,293 tok |
| `util-080` | vllm | VALID | 15.1 tok/s | 408 ms | 83.4 tok/s | 37.4% | 5.05x | 180 | 52.2% | 1,896,269 tok |
| `INTERACTION-flashinfer-bf16kv` | vllm | VALID | 14.9 tok/s | 266 ms | 82.8 tok/s | 37.4% | 4.32x | 195 | 45.6% | 740,841 tok |
| `spec-ngram8` | vllm | VALID | 13.1 tok/s | 255 ms | 71.3 tok/s | 47.7% | 18.88x | 104 | 13.5% | 771,255 tok |
| `spec-ngram5` | vllm | VALID | 12.5 tok/s | 111 ms | 79.3 tok/s | 46.7% | 17.69x | 10 | 70.0% | 804,953 tok |
| `spec-ngram3` | vllm | VALID | 12.1 tok/s | 113 ms | 79.7 tok/s | 46.3% | 15.58x | 12 | 66.7% | 839,153 tok |
| `spec-off` | vllm | VALID | 11.2 tok/s | 258 ms | 79.6 tok/s | 45.3% | 10.60x | — | — | 854,227 tok |
| `sglang-baseline` | sglang | VALID | 9.8 tok/s | 556 ms | 73.0 tok/s | — | 15.67x | — | — | — |
| `attn-triton-cli` | vllm | PARTIAL | 19.7 tok/s | 418 ms | 102.5 tok/s | 37.0% | 4.19x | 138 | 59.4% | 758,606 tok |
| `prefix-off` | vllm | PARTIAL | 15.2 tok/s | 266 ms | 78.8 tok/s | 37.4% | 4.71x | 155 | 63.9% | 736,567 tok |
| `attn-triton` | vllm | PARTIAL | 15.1 tok/s | 267 ms | 78.2 tok/s | 37.4% | 4.56x | 180 | 50.6% | 743,691 tok |
| `INTERACTION-triton-util080` | vllm | PARTIAL | 14.8 tok/s | 270 ms | 92.0 tok/s | 37.4% | 4.71x | 195 | 47.2% | 1,891,995 tok |
| `sglang-radix-off` | sglang | BLOCKED | — | — | — | — | — | — | — | — |

**Columns.** *Decode* is single-stream tok/s — what one interactive session feels like. 
*Aggregate* is total tok/s at the highest concurrency tested — what the box can do in 
parallel; it rises with batching and is not comparable to Decode. 

*Prefix hit* is the share of queried tokens served from cache when an identical long 
prefix is re-sent — **this is the column that says whether prefix caching is running**. 
*Prefix TTFT* is the wall-clock speedup that bought, and it is noisy: two runs against 
the same config measured 0.90x and 4.51x while the hit rate stayed stable. Read the hit 
rate as the on/off switch and the TTFT ratio as an effect size worth repeating before 
citing — never the reverse.

*Drafted* is speculative tokens proposed during one generation — 0 while 
`speculative_config` is set means speculation is dead. *Accepted* is the share of those 
drafts the target model kept, and it is the one that decides whether speculation pays: 
rejected drafts still cost their verification pass. *KV cache* is the real context 
ceiling in tokens; if it is below `max_model_len`, the advertised context window cannot 
be reached.

## Recommendation

**Fastest VALID single-stream configuration: `spec-mtp3` (vllm) at 19.7 tok/s.**

Apply it by setting these in `config/models.yml`, then 
`bash scripts/03_vllm_servers.sh`:

```yaml
speculative_config: {"method":"mtp","num_speculative_tokens":3}
```

Runner-up `spec-mtp2` at 18.5 tok/s (+1.2 tok/s, +6.4%). 

## Configurations whose numbers must not be cited

- `prefix-off` (PARTIAL) — prefix_caching requested=false observed=yes (hit rate 0.374);
- `attn-triton` (PARTIAL) — attention_backend requested=TRITON_ATTN observed=FLASHINFER;
- `INTERACTION-triton-util080` (PARTIAL) — attention_backend requested=TRITON_ATTN observed=FLASHINFER;
- `attn-triton-cli` (PARTIAL) — extra_args requested TRITON_ATTN observed FLASHINFER;

## Detail

### `INTERACTION-flashinfer-bf16kv`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_attention_backend=FLASHINFER OVERRIDE_kv_cache_dtype=auto`
- **Validity:** VALID — all 2 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:49:07-07:00 (3 runs x 256 tokens)

### `INTERACTION-triton-util080`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_attention_backend=TRITON_ATTN OVERRIDE_gpu_memory_utilization=0.80`
- **Validity:** PARTIAL — attention_backend requested=TRITON_ATTN observed=FLASHINFER;
- **Measured:** 2026-08-26T14:56:05-07:00 (3 runs x 256 tokens)

### `attn-flashinfer`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_attention_backend=FLASHINFER`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T13:43:26-07:00 (3 runs x 256 tokens)

### `attn-triton`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_attention_backend=TRITON_ATTN`
- **Validity:** PARTIAL — attention_backend requested=TRITON_ATTN observed=FLASHINFER;
- **Measured:** 2026-08-26T13:37:19-07:00 (3 runs x 256 tokens)

### `attn-triton-cli`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_extra_args=--attention-backend=TRITON_ATTN`
- **Validity:** PARTIAL — extra_args requested TRITON_ATTN observed FLASHINFER;
- **Measured:** 2026-08-26T17:18:33-07:00 (3 runs x 256 tokens)

### `baseline`

- **Engine:** vllm
- **Overrides:** `none — models.yml as committed`
- **Validity:** VALID — all 0 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T13:24:25-07:00 (3 runs x 256 tokens)

### `kv-bf16`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_kv_cache_dtype=auto`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T13:49:36-07:00 (3 runs x 256 tokens)

### `prefix-off`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_enable_prefix_caching=false`
- **Validity:** PARTIAL — prefix_caching requested=false observed=yes (hit rate 0.374);
- **Measured:** 2026-08-26T13:31:11-07:00 (3 runs x 256 tokens)

### `sglang-baseline`

- **Engine:** sglang
- **Overrides:** `none — models.yml as committed`
- **Validity:** VALID — all 0 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T16:59:09-07:00 (3 runs x 256 tokens)

### `sglang-radix-off`

- **Engine:** sglang
- **Overrides:** `OVERRIDE_disable_radix_cache=true`
- **Validity:** BLOCKED — no SGLang image pinned in config/models.yml (sglang.docker_image)
- **Measured:** 2026-08-26T14:56:05-07:00 (3 runs x 256 tokens)

### `spec-mtp2`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":2}`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:17:04-07:00 (3 runs x 256 tokens)

### `spec-mtp3`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":3}`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:07:24-07:00 (3 runs x 256 tokens)

### `spec-ngram3`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":3,"prompt_lookup_max":4}`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:36:02-07:00 (3 runs x 256 tokens)

### `spec-ngram5`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4}`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:26:38-07:00 (3 runs x 256 tokens)

### `spec-ngram8`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":8,"prompt_lookup_max":8,"prompt_lookup_min":2}`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T17:44:28-07:00 (3 runs x 256 tokens)

### `spec-off`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_speculative_config=`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T17:38:33-07:00 (3 runs x 256 tokens)

### `util-080`

- **Engine:** vllm
- **Overrides:** `OVERRIDE_gpu_memory_utilization=0.80`
- **Validity:** VALID — all 1 requested parameter(s) confirmed in effect
- **Measured:** 2026-08-26T14:42:41-07:00 (3 runs x 256 tokens)

---

*Generated 2026-08-26T17:44:28-07:00 from 17 ledger entries by `scripts/benchmark.sh render`.*
