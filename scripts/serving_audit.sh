#!/usr/bin/env bash
# =============================================================================
# SERVING AUDIT — what models.yml DECLARES vs what vLLM actually DID
# =============================================================================
# Every setting in config/models.yml is a request, not a guarantee. vLLM is
# free to ignore, downgrade, or silently override any of them at load time,
# and it reports that only in the startup log — which nothing in this repo
# has ever read back.
#
# Two field-reported failures on this exact model make that gap concrete:
#
#   1. PREFIX CACHING SILENTLY DISABLED. vLLM is reported to turn prefix
#      caching off for this model's card parameters despite the flag being
#      accepted on the command line. If that happens here, every OpenClaw
#      request reprocesses the whole conversation prefix from scratch — which
#      is the single most expensive thing that can go wrong in a coding
#      workflow, and it fails completely silently. We pass
#      --enable-prefix-caching and have never confirmed it took effect.
#
#   2. ADVERTISED CONTEXT MAY NOT BE REACHABLE. The default attention backend
#      is reported to cap usable context around 60K at 0.80 utilisation, with
#      FlashInfer fitting ~170K instead. We declare max_model_len: 262144 at
#      0.45 utilisation — barely half that memory budget — and pin no
#      attention backend at all. If the KV cache cannot hold 262144 tokens,
#      that number is a claim the server cannot honour, and the failure
#      arrives as a mid-session error rather than a startup one.
#
# This script does not trust the log alone. Where a behaviour can be measured
# from outside, it measures it.
#
# Usage:
#   bash scripts/serving_audit.sh
#
# Read-only: no restarts, no config changes. Safe against production Brain.
# Exit codes: 0 = declared config matches reality, 1 = a mismatch worth acting
#             on, 2 = could not determine.
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
if isinstance(val, bool):
    val = str(val).lower()
print(val if val is not None else '')
"
}

# Container logs are untrusted for display — a server's startup output can
# restate values that were supplied as secrets. See scripts/specdecode_probe.sh
# for the full note; this is the same filter.
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
    if len(key) >= 8:
        line = line.replace(key, "<redacted>")
    sys.stdout.write(line)
'
}

BRAIN_PORT=$(get_field brain port)
BRAIN_NAME=$(get_field brain served_name)
DECL_CTX=$(get_field brain max_model_len)
DECL_KV=$(get_field brain kv_cache_dtype)
DECL_PREFIX=$(get_field brain enable_prefix_caching)
DECL_ATTN=$(get_field brain attention_backend)
DECL_UTIL=$(get_field brain gpu_memory_utilization)

AUTH=(-H "Authorization: Bearer ${BRAIN_API_KEY}")
BASE="http://localhost:${BRAIN_PORT}"
EXIT=0

echo ""
echo "============================================================"
echo " Serving Audit — declared vs actual"
echo "============================================================"
echo "  models.yml declares:"
echo "    max_model_len          : ${DECL_CTX}"
echo "    kv_cache_dtype         : ${DECL_KV}"
echo "    enable_prefix_caching  : ${DECL_PREFIX}"
echo "    attention_backend      : ${DECL_ATTN:-<blank — vLLM autoselects>}"
echo "    gpu_memory_utilization : ${DECL_UTIL}"
echo ""

if ! curl -sf --max-time 5 "${AUTH[@]}" "${BASE}/v1/models" >/dev/null 2>&1; then
    echo "  ERROR: Brain not responding on port ${BRAIN_PORT}"
    exit 2
fi

LOGS=$(docker logs brain 2>&1 | head -600 || echo "")

# -- 1. Attention backend and KV dtype ---------------------------------------
echo ">>> 1. Attention backend / KV cache dtype (from startup log)"
if [ -z "${LOGS}" ]; then
    echo "    WARN: no container logs available."
    EXIT=2
else
    echo "${LOGS}" | grep -iE "attention backend|using .*attn|flashinfer|kv cache dtype|kv_cache_dtype" \
        | head -8 | redact | sed 's/^/    /'
fi
echo ""

# -- 2. Actual KV cache capacity vs advertised context ------------------------
# vLLM logs the real KV cache size in tokens once it has allocated. That number,
# not max_model_len, is the true context ceiling: if the cache holds fewer
# tokens than max_model_len, a single request can never reach the advertised
# window, and the failure surfaces mid-session rather than at startup.
echo ">>> 2. Usable context — KV cache capacity vs advertised max_model_len"
KVLINE=$(echo "${LOGS}" | grep -iE "GPU KV cache size|KV cache size|Maximum concurrency" | head -4)
if [ -z "${KVLINE}" ]; then
    echo "    Could not find a KV cache size line in the log."
    echo "    Look for 'GPU KV cache size' manually: docker logs brain | grep -i 'kv cache'"
    EXIT=2
else
    echo "${KVLINE}" | redact | sed 's/^/    /'
    echo ""
    KV_TOKENS=$(echo "${KVLINE}" | grep -ioE "GPU KV cache size: *[0-9,]+" \
                | grep -oE "[0-9,]+" | tr -d ',' | head -1)
    if [ -n "${KV_TOKENS}" ] && [ -n "${DECL_CTX}" ]; then
        if [ "${KV_TOKENS}" -lt "${DECL_CTX}" ]; then
            echo "    *** MISMATCH: KV cache holds ${KV_TOKENS} tokens, but"
            echo "    *** max_model_len advertises ${DECL_CTX}."
            echo "    *** A single request CANNOT reach the advertised context."
            echo "    *** Raise gpu_memory_utilization (currently ${DECL_UTIL}),"
            echo "    *** try attention_backend: FLASHINFER, or lower"
            echo "    *** max_model_len so the number you publish is honest."
            EXIT=1
        else
            CONC=$(( KV_TOKENS / DECL_CTX ))
            echo "    OK: cache holds ${KV_TOKENS} tokens >= advertised ${DECL_CTX}"
            echo "    (~${CONC} concurrent request(s) at full context)"
        fi
    fi
fi
echo ""

# -- 3. Prefix caching — measured, not trusted --------------------------------
# The log line can say enabled while the feature is inert, so measure it.
# Send a long prompt, then send the SAME prefix again with a different tail.
# With prefix caching working, the second request skips reprocessing the shared
# prefix and TTFT drops sharply. Without it, both are roughly equal.
echo ">>> 3. Prefix caching — measured via TTFT on a repeated prefix"
echo "${LOGS}" | grep -iE "prefix cach|enable_prefix_caching|automatic prefix" \
    | head -4 | redact | sed 's/^/    log: /'

PREFIX_RESULT=$(BASE="${BASE}" BRAIN_NAME="${BRAIN_NAME}" BRAIN_API_KEY="${BRAIN_API_KEY}" \
python3 - <<'PYEOF'
import json, os, sys, time, urllib.request

base  = os.environ["BASE"]
model = os.environ["BRAIN_NAME"]
key   = os.environ["BRAIN_API_KEY"]
url   = f"{base}/v1/chat/completions"

# Long enough that reprocessing it is unmistakably slower than reusing it.
prefix = ("Here is a module to review.\n\n" +
          "\n".join(f"def function_{i}(alpha, beta):\n"
                    f'    """Compute step {i} of the pipeline."""\n'
                    f"    result = alpha * {i} + beta\n"
                    f"    return result\n" for i in range(400)))

def ask(tail):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prefix + "\n\n" + tail}],
        "max_tokens": 8,
        "stream": True,
        "temperature": 0,
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            if line[6:] == "[DONE]":
                break
            try:
                chunk = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            if chunk.get("choices"):
                d = chunk["choices"][0].get("delta") or {}
                if d.get("content") or d.get("reasoning") or d.get("reasoning_content"):
                    return time.perf_counter() - start
    return time.perf_counter() - start

try:
    cold = ask("Summarise function_1 in one sentence.")
    warm = ask("Summarise function_2 in one sentence.")   # same prefix, new tail
except Exception as e:
    print(f"ERROR {e}")
    sys.exit(2)

print(f"{cold:.3f} {warm:.3f}")
PYEOF
)

if echo "${PREFIX_RESULT}" | grep -q "^ERROR"; then
    echo "    Could not measure: ${PREFIX_RESULT}"
    EXIT=2
else
    COLD=$(echo "${PREFIX_RESULT}" | awk '{print $1}')
    WARM=$(echo "${PREFIX_RESULT}" | awk '{print $2}')
    echo ""
    echo "    TTFT cold (first sight of prefix) : ${COLD}s"
    echo "    TTFT warm (same prefix, new tail) : ${WARM}s"
    VERDICT=$(COLD="${COLD}" WARM="${WARM}" DECL_PREFIX="${DECL_PREFIX}" python3 -c '
import os
cold, warm = float(os.environ["COLD"]), float(os.environ["WARM"])
declared = os.environ["DECL_PREFIX"] == "true"
speedup = cold / warm if warm > 0 else 0
print(f"    speedup: {speedup:.2f}x")
if speedup >= 1.8:
    print("    OK: prefix caching is WORKING — the shared prefix was reused.")
    raise SystemExit(0)
if declared:
    print("    *** MISMATCH: models.yml sets enable_prefix_caching: true, but")
    print("    *** re-sending an identical prefix bought little or nothing.")
    print("    *** The flag is accepted and the feature is not taking effect.")
    print("    *** This is the reported failure mode for this model, and it is")
    print("    *** expensive: every OpenClaw turn reprocesses the whole")
    print("    *** conversation prefix. Check the startup log lines above for")
    print("    *** a line where vLLM disables it, and what reason it gives.")
    raise SystemExit(1)
print("    Prefix caching is not enabled in models.yml — expected result.")
raise SystemExit(0)
')
    VERDICT_RC=$?
    echo "${VERDICT}"
    [ "${VERDICT_RC}" != "0" ] && EXIT=1
fi

echo ""
echo "============================================================"
if [ "${EXIT}" = "0" ]; then
    echo " Declared config matches observed behaviour."
elif [ "${EXIT}" = "1" ]; then
    echo " MISMATCH FOUND — see the *** lines above."
    echo " Fix these BEFORE tuning speculative decoding: a broken prefix"
    echo " cache or an unreachable context window costs far more in real"
    echo " agentic use than draft-token tuning can win back."
else
    echo " Inconclusive — some checks could not be evaluated."
fi
echo "============================================================"
exit ${EXIT}
