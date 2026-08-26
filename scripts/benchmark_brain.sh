#!/usr/bin/env bash
# =============================================================================
# Brain throughput benchmark — measures what the stack actually does.
#
# Reports time-to-first-token and decode tok/s against the running Brain,
# read from config/models.yml. Use this to fill in the tok/s column in
# README.md / docs/LESSONS.md instead of quoting numbers from elsewhere.
#
# Usage:
#   bash scripts/benchmark_brain.sh                  # 3 runs, 256 tokens each
#   RUNS=5 MAX_TOKENS=512 bash scripts/benchmark_brain.sh
#   PROMPT="Write a binary search in Rust." bash scripts/benchmark_brain.sh
#
# Generation is pinned to exactly MAX_TOKENS (ignore_eos) so runs are
# comparable. Reasoning tokens count toward decode — that is the real rate.
# =============================================================================

set -euo pipefail

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

RUNS="${RUNS:-3}"
MAX_TOKENS="${MAX_TOKENS:-256}"
PROMPT="${PROMPT:-Explain how a hash map handles collisions, then write one in Python.}"

echo ""
echo "── Brain Benchmark ─────────────────────────────────────────"
echo "  Model    : ${BRAIN_NAME}"
echo "  Endpoint : http://localhost:${BRAIN_PORT}/v1"
echo "  Runs     : ${RUNS} x ${MAX_TOKENS} tokens"
echo ""

if ! curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
        "http://localhost:${BRAIN_PORT}/v1/models" >/dev/null 2>&1; then
    echo "  ERROR: Brain not responding on port ${BRAIN_PORT}"
    echo "  Check: docker logs brain --tail 50"
    exit 1
fi

BRAIN_PORT="${BRAIN_PORT}" BRAIN_NAME="${BRAIN_NAME}" \
BRAIN_API_KEY="${BRAIN_API_KEY}" \
RUNS="${RUNS}" MAX_TOKENS="${MAX_TOKENS}" PROMPT="${PROMPT}" \
python3 - <<'PYEOF'
import json, os, time, urllib.request, statistics

port  = os.environ["BRAIN_PORT"]
model = os.environ["BRAIN_NAME"]
runs  = int(os.environ["RUNS"])
maxt  = int(os.environ["MAX_TOKENS"])
prompt = os.environ["PROMPT"]

url = f"http://localhost:{port}/v1/chat/completions"

def one_run():
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": maxt,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": True,          # vLLM extension: generate exactly max_tokens
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            # Was hardcoded "Bearer local", which 401s once --api-key is set.
            "Authorization": "Bearer " + (os.environ.get("BRAIN_API_KEY") or "local"),
        },
    )
    start = time.perf_counter()
    ttft = None
    last = start
    completion_tokens = None
    prompt_tokens = None

    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue

            usage = chunk.get("usage")
            if usage:
                completion_tokens = usage.get("completion_tokens", completion_tokens)
                prompt_tokens = usage.get("prompt_tokens", prompt_tokens)

            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                # Thinking models stream reasoning before content. vLLM's field
                # name for that stream drifted: older builds use "reasoning_content",
                # newer builds use "reasoning". Accept either so the benchmark
                # survives image upgrades.
                if (delta.get("content")
                        or delta.get("reasoning")
                        or delta.get("reasoning_content")):
                    now = time.perf_counter()
                    if ttft is None:
                        ttft = now - start
                    last = now

    total = time.perf_counter() - start
    if ttft is None:
        return None
    # Decode rate excludes prefill: time from first token to last token.
    decode_window = max(last - (start + ttft), 1e-9)
    ntok = completion_tokens or maxt
    return {
        "ttft": ttft,
        "total": total,
        "tokens": ntok,
        "prompt_tokens": prompt_tokens,
        "decode_tps": (ntok - 1) / decode_window if ntok > 1 else 0.0,
        "overall_tps": ntok / total,
    }

results = []
for i in range(1, runs + 1):
    print(f"  run {i}/{runs} ...", end="", flush=True)
    try:
        r = one_run()
    except Exception as e:
        print(f" FAILED: {e}")
        continue
    if r is None:
        print(" FAILED: no tokens received")
        continue
    results.append(r)
    print(f" {r['decode_tps']:6.1f} tok/s decode   TTFT {r['ttft']*1000:6.0f} ms"
          f"   ({r['tokens']} tok in {r['total']:.1f}s)")

if not results:
    print("\n  No successful runs.")
    raise SystemExit(1)

dec = [r["decode_tps"] for r in results]
ttfts = [r["ttft"] for r in results]

print("")
print("── Results ─────────────────────────────────────────────────")
print(f"  Decode      : {statistics.median(dec):.1f} tok/s median"
      f"  (min {min(dec):.1f}, max {max(dec):.1f})")
print(f"  TTFT        : {statistics.median(ttfts)*1000:.0f} ms median")
print(f"  Prompt size : {results[0]['prompt_tokens']} tokens")
print("")
print("  Single-stream, batch size 1. Concurrent load will differ.")
print("")
PYEOF
