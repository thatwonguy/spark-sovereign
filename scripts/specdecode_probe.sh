#!/usr/bin/env bash
# =============================================================================
# SPEC-DECODE PROBE — is speculative decoding actually doing anything?
# =============================================================================
# config/models.yml has shipped `speculative_config` (MTP, 5 tokens) since the
# v5.0 swap, and nothing in this repo has ever checked whether it engages.
# It probably does not. The arithmetic, from docs/LESSONS.md #16:
#
#     dense 27.78B at NVFP4  ~= 13.5 GB of weights read per token
#     GB10 memory bandwidth  ~= 273 GB/s
#     roofline                = 273 / 13.5 ~= 20 tok/s   <- no-speculation ceiling
#     measured                = 15-17 tok/s              <- 75-85% of roofline
#
# 15-17 against a 20 tok/s ceiling is a healthy NON-speculative decode. Working
# MTP at even 1.5 accepted tokens per step would put us at 25-30 and BREAK that
# ceiling, because accepted draft tokens are verified in one weight-read pass.
# So the measured number is itself evidence that MTP contributes ~nothing.
#
# This script turns that inference into a measurement. It does not change
# anything — no restart, no config edit. Safe to run against production Brain.
#
# WHY IT GENERATES LOAD: vLLM's spec-decode metrics are cumulative counters
# that start at zero. Reading them once cannot distinguish "MTP is broken" from
# "nothing has been generated yet". So we snapshot, drive a known generation,
# snapshot again, and report the DELTA. Zero drafts across a known-good
# generation is unambiguous.
#
# Usage:
#   bash scripts/specdecode_probe.sh
#   MAX_TOKENS=512 bash scripts/specdecode_probe.sh
#
# Exit codes: 0 = spec decode is working, 1 = configured but not engaging,
#             2 = could not determine (Brain down, no metrics endpoint).
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Needed for BRAIN_API_KEY — /v1 returns 401 without it once a key is set.
source "${REPO_ROOT}/.env" 2>/dev/null || true
BRAIN_API_KEY="${BRAIN_API_KEY:-}"

get_field() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
print(val if val is not None else '')
"
}

BRAIN_PORT=$(get_field brain port)
BRAIN_NAME=$(get_field brain served_name)
BRAIN_SPEC=$(get_field brain speculative_config)
MAX_TOKENS="${MAX_TOKENS:-256}"

# vLLM's auth middleware only guards /v1, so /metrics is normally open. The
# header is sent anyway — harmless when unused, correct if that ever changes.
AUTH=(-H "Authorization: Bearer ${BRAIN_API_KEY}")
BASE="http://localhost:${BRAIN_PORT}"

# Scrub credentials from anything sourced from container logs or inspect
# output before it reaches the terminal.
#
# THE INVARIANT: container logs and inspect output are untrusted for display.
# A server's startup output can restate its own configuration, including
# values that were supplied as secrets, and it does not separate those from
# anything else. So no path in this script prints that output raw — every one
# goes through redact() first.
#
# This matters more here than in most places. 03_vllm_servers.sh deliberately
# passes the bearer token as an environment variable rather than a CLI flag so
# it stays out of `ps aux`. A diagnostic that echoes raw server output to a
# terminal, a scrollback buffer, or a pasted bug report gives that protection
# straight back — and this is a script people run precisely when they are
# about to paste the result somewhere.
#
# Pattern passes first, then a literal pass on the live key value, so a shape
# the patterns do not anticipate still cannot leak the one secret we hold.
#
# Do not remove this to "clean up the output". The greps below are broad on
# purpose and will match configuration lines.
#
# Implemented in python3 rather than sed on purpose: the literal-value pass
# needs the secret treated as text, and hand-escaping a secret into a sed
# expression is fragile in the one direction that matters — a key containing
# an unescaped metacharacter either breaks the script or, worse, silently
# stops matching and prints the key. str.replace() has no such failure mode.
redact() {
    BRAIN_API_KEY="${BRAIN_API_KEY}" python3 -c '
import os, re, sys

PATTERNS = [
    (re.compile(r"((?:api[_-]?key|token|secret|password|passwd)[\"\x27]?\s*[=:]\s*[\"\x27]?)"
                r"[A-Za-z0-9._~+/-]{8,}", re.I), r"\1<redacted>"),
    (re.compile(r"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/-]{8,}", re.I), r"\1 <redacted>"),
]

key = os.environ.get("BRAIN_API_KEY", "")
for line in sys.stdin:
    for pat, repl in PATTERNS:
        line = pat.sub(repl, line)
    # Literal pass last: catches anything the patterns above missed.
    if len(key) >= 8:
        line = line.replace(key, "<redacted>")
    sys.stdout.write(line)
'
}

echo ""
echo "-- Spec-Decode Probe ---------------------------------------"
echo "  Model    : ${BRAIN_NAME}"
echo "  Endpoint : ${BASE}/v1"
echo "  Config   : ${BRAIN_SPEC:-<none in models.yml>}"
echo ""

if ! curl -sf --max-time 5 "${AUTH[@]}" "${BASE}/v1/models" >/dev/null 2>&1; then
    echo "  ERROR: Brain not responding on port ${BRAIN_PORT}"
    echo "  Check: docker logs brain --tail 50"
    exit 2
fi

# -- 1. Did the flag actually reach the server? -------------------------------
# A config value that never makes it onto the command line is the cheapest
# possible explanation, so rule it out before measuring anything.
echo ">>> 1. Flag plumbing (docker inspect)"
CMDLINE=$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' brain 2>/dev/null || echo "")
if [ -z "${CMDLINE}" ]; then
    echo "    WARN: could not inspect the 'brain' container — skipping."
elif echo "${CMDLINE}" | grep -q -- "--speculative-config"; then
    echo "    OK: --speculative-config is on the running command line:"
    echo "${CMDLINE}" | tr ' ' '\n' | grep -A1 -- "--speculative-config" | tail -1 \
        | redact | sed 's/^/        /'
else
    echo "    *** NOT FOUND: --speculative-config is absent from the running"
    echo "    *** container's command line. models.yml sets it, the server"
    echo "    *** never received it. That is the bug — stop here and fix the"
    echo "    *** plumbing in scripts/03_vllm_servers.sh."
fi
echo ""

# -- 2. What did vLLM decide at startup? --------------------------------------
# Attention backend and KV dtype are chosen at load time and only ever
# announced in the log. Neither is pinned anywhere in this repo, so the log is
# the only place the real values exist. Relevant because FP8 KV on SM121 is
# reported to require triton_attn — FlashAttention cannot serve it, and a
# silent fallback to BF16 KV would halve effective context with no error.
echo ">>> 2. Startup decisions (docker logs)"
LOGS=$(docker logs brain 2>&1 | head -400 || echo "")
if [ -z "${LOGS}" ]; then
    echo "    WARN: no logs available."
else
    # Both greps pipe through redact() — see the note on its definition.
    # These patterns match configuration output, which is exactly the class of
    # line that can restate a supplied secret. Never print them raw.
    echo "${LOGS}" | grep -iE "attention backend|using .*attn|kv cache dtype|kv_cache_dtype" \
        | head -10 | redact | sed 's/^/    /'
    echo "${LOGS}" | grep -iE "speculative|mtp|draft" | head -10 | redact | sed 's/^/    /'
fi
echo ""

# -- 3. Snapshot, generate, snapshot. -----------------------------------------
echo ">>> 3. Counter delta across a ${MAX_TOKENS}-token generation"
snapshot() {
    curl -sf --max-time 10 "${AUTH[@]}" "${BASE}/metrics" 2>/dev/null \
        | grep -E "^vllm:spec_decode" || true
}

BEFORE=$(snapshot)
if [ -z "${BEFORE}" ]; then
    echo "    NOTE: no vllm:spec_decode_* metrics exported before the run."
    echo "    Either this build predates them, or spec decode never engaged."
fi

REQ_BODY=$(BRAIN_NAME="${BRAIN_NAME}" MAX_TOKENS="${MAX_TOKENS}" python3 -c "
import json, os
print(json.dumps({
    'model': os.environ['BRAIN_NAME'],
    'messages': [{'role': 'user',
                  'content': 'Explain how a hash map handles collisions, then write one in Python.'}],
    'max_tokens': int(os.environ['MAX_TOKENS']),
    'ignore_eos': True,
}))
")

if ! curl -sf --max-time 300 "${AUTH[@]}" -H "Content-Type: application/json" \
        -X POST "${BASE}/v1/chat/completions" -d "${REQ_BODY}" >/dev/null 2>&1; then
    echo "    ERROR: generation request failed. Check: docker logs brain --tail 50"
    exit 2
fi

AFTER=$(snapshot)
echo ""

BEFORE="${BEFORE}" AFTER="${AFTER}" python3 - <<'PYEOF'
import os, re, sys

def parse(blob):
    """Sum each vllm:spec_decode_* counter across all label sets."""
    out = {}
    for line in blob.splitlines():
        m = re.match(r'^(vllm:spec_decode_[a-z_]+)(?:\{[^}]*\})?\s+([0-9.eE+-]+)$',
                     line.strip())
        if m:
            out[m.group(1)] = out.get(m.group(1), 0.0) + float(m.group(2))
    return out

before, after = parse(os.environ["BEFORE"]), parse(os.environ["AFTER"])
keys = sorted(set(before) | set(after))

if not keys:
    print("    RESULT: no spec-decode counters exposed at all. Cannot measure")
    print("    from metrics — fall back to the log lines in step 2.")
    sys.exit(2)

print("    metric                                            delta")
print("    " + "-" * 56)
delta = {}
for k in keys:
    d = after.get(k, 0.0) - before.get(k, 0.0)
    delta[k] = d
    print(f"    {k:<44} {d:>10,.0f}")
print("")

# Counter names differ between vLLM generations; accept either spelling.
def pick(*names):
    for n in names:
        for k, v in delta.items():
            if k.endswith(n):
                return v
    return None

drafted  = pick("num_draft_tokens_total", "num_draft_tokens")
accepted = pick("num_accepted_tokens_total", "num_accepted_tokens")

if drafted is None or accepted is None:
    print("    RESULT: counters present, but not the draft/accept pair this")
    print("    script knows. Read the deltas above by hand.")
    sys.exit(2)

if drafted == 0:
    print("    RESULT: *** ZERO DRAFT TOKENS ***")
    print("    Speculative decoding is configured but is NOT running. The")
    print("    server generated tokens and proposed none. This is the single")
    print("    highest-value thing to fix on this box — it is free throughput")
    print("    already paid for in config.")
    sys.exit(1)

rate = accepted / drafted
# Each accepted draft token is a token emitted without its own weight-read
# pass, so speedup over plain decode is roughly 1 + accepted-per-draft-step.
drafts = pick("num_drafts_total", "num_drafts") or 0

print(f"    acceptance rate      : {rate:.1%}  ({accepted:,.0f} of {drafted:,.0f} drafted)")
if drafts:
    per_step = accepted / drafts
    print(f"    accepted per step    : {per_step:.2f} tokens")
    print(f"    implied speedup      : ~{1 + per_step:.2f}x over non-speculative decode")
print("")

if rate < 0.15:
    print("    RESULT: drafting, but acceptance is too low to pay for itself.")
    print("    Every rejected token still costs a verification pass. Sweep")
    print("    num_speculative_tokens downward:")
    print("        bash scripts/specdecode_sweep.sh")
    sys.exit(1)

print("    RESULT: speculative decoding is live and contributing.")
print("    Cross-check against scripts/benchmark_brain.sh — if decode is still")
print("    15-17 tok/s, the gain is being given back somewhere else.")
PYEOF
STATUS=$?

echo ""
echo "-- Roofline reference --------------------------------------"
echo "  Dense 27.78B @ NVFP4    ~= 13.5 GB read per token"
echo "  GB10 memory bandwidth   ~= 273 GB/s"
echo "  Non-speculative ceiling ~= 20 tok/s"
echo ""
echo "  Any decode rate at or below ~20 tok/s is fully explained WITHOUT"
echo "  speculation. Only a number ABOVE it proves spec decode is paying off."
echo "  Measure with: bash scripts/benchmark_brain.sh"
echo "------------------------------------------------------------"
exit ${STATUS}
