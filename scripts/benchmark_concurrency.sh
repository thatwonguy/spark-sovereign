#!/usr/bin/env bash
# =============================================================================
# CONCURRENCY BENCHMARK — aggregate throughput vs parallel streams
# =============================================================================
# benchmark_brain.sh measures ONE stream. That is the right number for "how
# fast does it feel to me typing at it", and the wrong number for "how much
# work can this box do". They differ by an order of magnitude, and quoting
# one where the other belongs is how throughput claims get misread.
#
# Why they differ: decode is bandwidth-bound. One forward pass reads the whole
# weight set and, at batch size N, emits N tokens from that single read. So
# aggregate throughput rises with concurrency until something else binds —
# KV cache capacity, max_num_seqs, or compute. Circulating figures like
# "148 tok/s at 8 streams, 258 at 32" for this model need no exotic technique
# at all; they are ordinary batching, and this script checks whether this box
# reproduces them.
#
# Read the output as two separate questions:
#   AGGREGATE  — total tokens/s across all streams. Scales with concurrency.
#                This is the number to compare against multi-stream claims.
#   PER-STREAM — what one user experiences. Falls as concurrency rises.
#                This is what OpenClaw feels like while N agents are running.
#
# Usage:
#   bash scripts/benchmark_concurrency.sh
#   STREAMS="1 4 8 16 32" bash scripts/benchmark_concurrency.sh
#   MAX_TOKENS=512 bash scripts/benchmark_concurrency.sh
#
# Read-only: no restarts, no config changes. But it DOES load the GPU hard,
# so do not run it while relying on Brain for anything interactive.
#
# NOTE: max_num_seqs in config/models.yml is 16. Streams beyond that queue
# rather than batch, so the curve should flatten there — if it does not, that
# is itself informative and worth chasing.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
BRAIN_SEQS=$(get_field brain max_num_seqs)

STREAMS="${STREAMS:-1 2 4 8 16 32}"
MAX_TOKENS="${MAX_TOKENS:-256}"

echo ""
echo "-- Concurrency Benchmark -----------------------------------"
echo "  Model        : ${BRAIN_NAME}"
echo "  Endpoint     : http://localhost:${BRAIN_PORT}/v1"
echo "  Streams      : ${STREAMS}"
echo "  Tokens each  : ${MAX_TOKENS}"
echo "  max_num_seqs : ${BRAIN_SEQS}  (curve should flatten past this)"
echo ""

if ! curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
        "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; then
    echo "  ERROR: Brain not responding on port ${BRAIN_PORT}"
    echo "  Check: docker logs brain --tail 50"
    exit 2
fi

BRAIN_PORT="${BRAIN_PORT}" BRAIN_NAME="${BRAIN_NAME}" \
BRAIN_API_KEY="${BRAIN_API_KEY}" STREAMS="${STREAMS}" MAX_TOKENS="${MAX_TOKENS}" \
python3 - <<'PYEOF'
import json, os, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

port   = os.environ["BRAIN_PORT"]
model  = os.environ["BRAIN_NAME"]
key    = os.environ["BRAIN_API_KEY"]
maxt   = int(os.environ["MAX_TOKENS"])
levels = [int(x) for x in os.environ["STREAMS"].split()]

url = f"http://localhost:{port}/v1/chat/completions"

# Distinct prompts per stream. Identical prompts would all hit the prefix
# cache and measure cache replay instead of decode.
PROMPTS = [
    "Explain how a hash map handles collisions, then write one in Python.",
    "Write a binary search tree with insert and delete in Rust.",
    "Describe the CAP theorem and give a concrete example of each tradeoff.",
    "Implement a rate limiter using a token bucket in Go.",
    "Explain how TCP congestion control works, then diagram slow start.",
    "Write a topological sort in C++ and explain the cycle detection.",
    "Compare optimistic and pessimistic locking with a worked example.",
    "Implement an LRU cache in Java with O(1) get and put.",
]

def one_stream(i):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)]}],
        "max_tokens": maxt,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": True,        # pin length so streams are comparable
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {key}"})
    start = time.perf_counter()
    ttft = None
    completion = 0
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if ttft is None and chunk.get("choices"):
                d = chunk["choices"][0].get("delta") or {}
                if d.get("content") or d.get("reasoning") or d.get("reasoning_content"):
                    ttft = time.perf_counter() - start
            if chunk.get("usage"):
                completion = chunk["usage"].get("completion_tokens", 0)
    elapsed = time.perf_counter() - start
    return {"ttft": ttft, "elapsed": elapsed, "tokens": completion or maxt}

print(f"  {'streams':>7}  {'aggregate':>12}  {'per-stream':>12}  {'p50 TTFT':>10}  {'wall':>8}")
print("  " + "-" * 58)

baseline = None
rows = []
for n in levels:
    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as pool:
        results = list(pool.map(one_stream, range(n)))
    wall = time.perf_counter() - wall_start

    total_tokens = sum(r["tokens"] for r in results)
    aggregate = total_tokens / wall
    per_stream = sum(r["tokens"] / r["elapsed"] for r in results) / n
    ttfts = sorted(r["ttft"] for r in results if r["ttft"] is not None)
    p50 = ttfts[len(ttfts) // 2] if ttfts else float("nan")

    rows.append((n, aggregate, per_stream))
    if baseline is None:
        baseline = aggregate

    print(f"  {n:>7}  {aggregate:>8.1f} tok/s  {per_stream:>8.1f} tok/s  "
          f"{p50 * 1000:>7.0f} ms  {wall:>6.1f} s")

print("")
print("  Scaling vs 1 stream:")
for n, agg, _ in rows:
    print(f"    {n:>3} streams : {agg / baseline:>5.2f}x aggregate")
print("")
print("  Reading this:")
print("    - AGGREGATE rising with streams is normal and expected. One weight")
print("      read serves the whole batch, so batching is close to free until")
print("      KV cache or max_num_seqs binds.")
print("    - Multi-stream figures quoted for this model (e.g. ~148 tok/s at 8,")
print("      ~258 at 32) should land in this table WITHOUT any special")
print("      technique. If they do, they say nothing about single-stream speed.")
print("    - PER-STREAM falling is the cost you pay. That is what an")
print("      interactive OpenClaw session feels like under parallel agents.")
print("    - If aggregate flattens well BEFORE max_num_seqs, the binding")
print("      constraint is KV cache, not batching — raise")
print("      gpu_memory_utilization or lower max_model_len and re-run.")
PYEOF
