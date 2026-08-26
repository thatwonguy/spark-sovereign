#!/usr/bin/env bash
# =============================================================================
# render_report.sh — regenerate docs/BENCHMARKS.md from the JSONL ledger
# =============================================================================
# AD-HOC. Called by scripts/benchmark.sh after each configuration, and runnable
# by hand. Not part of any sequence.
#
# The Markdown is DERIVED, never authored. Editing it by hand loses the edit on
# the next run — put durable prose in docs/LESSONS.md instead. The ledger
# (docs/benchmarks.jsonl) is the source of truth and is append-only.
#
# Usage: bash scripts/benchmark.sh render
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${LEDGER:-${REPO_ROOT}/docs/benchmarks.jsonl}"
REPORT="${REPORT:-${REPO_ROOT}/docs/BENCHMARKS.md}"

[ -f "${LEDGER}" ] || { echo "no ledger at ${LEDGER}"; exit 1; }

LEDGER="${LEDGER}" REPORT="${REPORT}" python3 <<'PYEOF'
import json, os, datetime

ledger, report = os.environ["LEDGER"], os.environ["REPORT"]

rows = []
for line in open(ledger, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        continue

# Later measurements of the same name supersede earlier ones.
by_name = {}
for r in rows:
    by_name[r["name"]] = r
rows = list(by_name.values())

def f(v, spec="{:.1f}", dash="—"):
    return dash if v is None else spec.format(v)

ranked = sorted(
    [r for r in rows if r.get("validity") == "VALID" and r.get("decode_toks")],
    key=lambda r: r["decode_toks"], reverse=True)

out = []
w = out.append

w("# Serving Configuration Benchmarks — Qwen3.8-27B on DGX Spark (GB10)")
w("")
w("<!-- GENERATED FILE. Do not edit by hand. -->")
w("<!-- Source of truth: docs/benchmarks.jsonl (append-only ledger). -->")
w("<!-- Regenerate: bash scripts/benchmark.sh render -->")
w("")
w("## What this file is")
w("")
w("A record of serving configurations **actually measured on this machine**, ")
w("produced by `scripts/benchmark.sh`. It exists so that anyone — including ")
w("a future LLM session with no memory of this work — can answer three questions ")
w("without re-deriving them:")
w("")
w("1. **What has already been tried?** Don't re-run what's in the table below.")
w("2. **Which numbers can be trusted?** See the Validity column. This is the important one.")
w("3. **What should be used right now?** See Recommendation.")
w("")
w("### How to read the Validity column — read this before using any number")
w("")
w("| Validity | Meaning |")
w("|---|---|")
w("| `VALID` | Every requested parameter was confirmed in effect. The number measures what the config says it measures. |")
w("| `PARTIAL` | Some parameters applied, others didn't. The number is real but is **not** attributable to the stated config. |")
w("| `INVALID` | Requested parameters did not take effect. **Do not rank or cite this number.** |")
w("| `BLOCKED` | Could not run — missing image or unconfigured engine. Absence of data, not evidence of badness. |")
w("| `FAILED` | Server did not come up. The config itself may be unusable on this hardware. |")
w("")
w("This distinction matters more than the throughput figures. vLLM accepts flags ")
w("it then silently ignores — prefix caching on this model is a documented case. ")
w("A benchmark of a config that never applied yields a real number attributed to ")
w("the wrong cause, which is worse than no number, because it looks like evidence.")
w("")

w("## Results")
w("")
w("| Config | Engine | Validity | Decode | TTFT | Aggregate | Prefix reuse | Drafted | KV cache |")
w("|---|---|---|---|---|---|---|---|---|")
order = {"VALID": 0, "PARTIAL": 1, "FAILED": 2, "INVALID": 3, "BLOCKED": 4}
for r in sorted(rows, key=lambda r: (order.get(r.get("validity"), 9),
                                     -(r.get("decode_toks") or 0))):
    w("| `{}` | {} | {} | {} | {} | {} | {} | {} | {} |".format(
        r.get("name", "?"), r.get("engine", "?"), r.get("validity", "?"),
        f(r.get("decode_toks"), "{:.1f} tok/s"),
        f(r.get("ttft_ms"), "{:.0f} ms"),
        f(r.get("aggregate_toks"), "{:.1f} tok/s"),
        f(r.get("prefix_reuse_x"), "{:.2f}x"),
        f(r.get("spec_drafted"), "{:.0f}"),
        f(r.get("kv_cache_tokens"), "{:,.0f} tok")))
w("")
w("**Columns.** *Decode* is single-stream tok/s — what one interactive session feels like. ")
w("*Aggregate* is total tok/s at the highest concurrency tested — what the box can do in ")
w("parallel; it rises with batching and is not comparable to Decode. *Prefix reuse* is the ")
w("TTFT speedup from re-sending an identical long prefix: **≥1.8x means prefix caching is ")
w("genuinely working**, ~1.0x means it is inert regardless of what the flag says. *Drafted* ")
w("is speculative tokens proposed during one generation — **0 means speculative decoding is ")
w("configured but dead**. *KV cache* is the real context ceiling in tokens; if it is below ")
w("`max_model_len`, the advertised context window cannot be reached.")
w("")

w("## Recommendation")
w("")
if not ranked:
    w("**No VALID measurements yet.** Nothing here should be used to choose a ")
    w("configuration. Run `bash scripts/benchmark.sh` on the Spark.")
    w("")
    blocked = [r for r in rows if r.get("validity") == "BLOCKED"]
    if blocked:
        w("Blocked configurations (untested, *not* ruled out):")
        w("")
        for r in blocked:
            w(f"- `{r['name']}` — {r.get('note') or 'no reason recorded'}")
        w("")
else:
    best = ranked[0]
    w(f"**Fastest VALID single-stream configuration: `{best['name']}` "
      f"({best['engine']}) at {best['decode_toks']:.1f} tok/s.**")
    w("")
    w("Apply it by setting these in `config/models.yml`, then ")
    w("`bash scripts/start_brain_ad_hoc.sh`:")
    w("")
    w("```yaml")
    if best.get("overrides"):
        for kv in best["overrides"].split():
            field, _, value = kv.partition("=")
            field = field.replace("OVERRIDE_", "")
            w(f"{field}: {value if value else '   # (unset — leave blank)'}")
    else:
        w("# baseline — config/models.yml as already committed, no changes")
    w("```")
    w("")
    if len(ranked) > 1:
        second = ranked[1]
        delta = best["decode_toks"] - second["decode_toks"]
        pct = 100 * delta / second["decode_toks"] if second["decode_toks"] else 0
        w(f"Runner-up `{second['name']}` at {second['decode_toks']:.1f} tok/s "
          f"({delta:+.1f} tok/s, {pct:+.1f}%). ")
        if abs(pct) < 5:
            w("That gap is within run-to-run noise — treat these two as equivalent "
              "and prefer whichever is simpler to operate.")
        w("")
    # Warn only about the config being RECOMMENDED. A slow runner-up with a
    # dead prefix cache is not actionable; the one you are about to deploy is.
    if best.get("prefix_reuse_x") is not None and best["prefix_reuse_x"] < 1.8:
        w(f"> **Warning — the fastest config has a dead prefix cache.** "
          f"`{best['name']}` shows prefix reuse of {best['prefix_reuse_x']:.2f}x "
          f"(working is >=1.8x). Single-stream decode is not the metric that "
          f"decides agentic coding: without prefix reuse, every turn reprocesses "
          f"the whole conversation, which costs far more wall-clock than the "
          f"decode-rate lead wins back.")
        w("")
        alt = next((r for r in ranked
                    if (r.get("prefix_reuse_x") or 0) >= 1.8), None)
        if alt:
            w(f"> Prefer **`{alt['name']}`** ({alt['decode_toks']:.1f} tok/s, "
              f"{alt['prefix_reuse_x']:.2f}x reuse) for interactive and agentic use, "
              f"and reserve `{best['name']}` for batch work with no shared prefix.")
        else:
            w("> No measured configuration has working prefix reuse. Fix that "
              "before optimising decode rate — see `scripts/benchmark.sh audit`.")
        w("")

untrust = [r for r in rows if r.get("validity") in ("PARTIAL", "INVALID")]
if untrust:
    w("## Configurations whose numbers must not be cited")
    w("")
    for r in untrust:
        w(f"- `{r['name']}` ({r['validity']}) — {r.get('note') or 'no detail recorded'}")
    w("")

w("## Detail")
w("")
for r in sorted(rows, key=lambda r: r.get("name", "")):
    w(f"### `{r.get('name')}`")
    w("")
    w(f"- **Engine:** {r.get('engine')}")
    w(f"- **Overrides:** `{r.get('overrides') or 'none — models.yml as committed'}`")
    w(f"- **Validity:** {r.get('validity')} — {r.get('note') or ''}")
    w(f"- **Measured:** {r.get('measured_at')} "
      f"({r.get('runs')} runs x {r.get('max_tokens')} tokens)")
    w("")

w("---")
w("")
w(f"*Generated {datetime.datetime.now().astimezone().isoformat(timespec='seconds')} "
  f"from {len(rows)} ledger entr{'y' if len(rows)==1 else 'ies'} by "
  f"`scripts/benchmark.sh render`.*")
w("")

with open(report, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(f"wrote {report} ({len(rows)} configurations)")
PYEOF
