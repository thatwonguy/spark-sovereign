#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — the only benchmarking entry point
# =============================================================================
#
#   *** AD-HOC. NOT PART OF ANY SEQUENCE. ***
#   Nothing calls this. It is absent from boot_sequence.sh, watchdog.sh and
#   the numbered 00-04 setup path, deliberately unnumbered so it cannot be
#   mistaken for a setup step, and must never be added to one.
#
# ONE COMMAND FILLS THE REPORT:
#
#     bash scripts/benchmark.sh
#
# That runs the audit, then every configuration in the matrix, then writes
# docs/BENCHMARKS.md. Nothing else needs invoking.
#
# SUBCOMMANDS (for when you want one piece):
#   audit      declared config vs what the server actually did   (read-only, ~1 min)
#   quick      decode rate + TTFT of the running config          (read-only, ~1 min)
#   bandwidth  achieved memory bandwidth + derived bytes/token   (read-only, ~1 min)
#   metrics    what the running server actually exports            (read-only, instant)
#   matrix     sweep every configuration                         (hours, Brain down)
#   render     regenerate BENCHMARKS.md from the ledger          (instant)
#   list       show the matrix and what has been measured        (instant)
#
# OPTIONS:
#   --only a,b   restrict the matrix to named configurations
#   --redo       re-measure configurations already in the ledger
#
# Self-contained: measurement primitives, the matrix, and the report renderer
# are all in this file. It depends only on the repo's own launchers.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env" 2>/dev/null || true
BRAIN_API_KEY="${BRAIN_API_KEY:-}"
MODELS_DIR="${MODELS_DIR:-/opt/models}"
LEDGER="${LEDGER:-${REPO_ROOT}/docs/benchmarks.jsonl}"
REPORT="${REPORT:-${REPO_ROOT}/docs/BENCHMARKS.md}"

# =============================================================================
# MEASUREMENT PRIMITIVES
# =============================================================================
# These were briefly a separate scripts/lib/bench.sh. That was one library with
# exactly one consumer — the same thing that made render_report.sh not worth
# its own file — and the split bought nothing while costing a sourcing block,
# a path-resolution dance, an execute guard, and one real bug (a stray `lib/`
# in .gitignore silently excluded it, publishing a benchmark.sh whose library
# was absent from the repo).
#
# One file. Copy it to the Spark and it works. Split it out again only when a
# second consumer actually exists.
# =============================================================================

# -- Config access ------------------------------------------------------------
# Any field can be overridden for one call by exporting OVERRIDE_<field>.
# An override set to the EMPTY string means "unset this field" — a distinct and
# necessary case, since testing "no speculation" or "let vLLM pick the backend"
# requires blanking a value rather than replacing it.
get_field() {
    local ov="OVERRIDE_$2"
    if [ -n "${!ov+set}" ]; then printf '%s\n' "${!ov}"; return; fi
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
if isinstance(val, bool):
    val = str(val).lower()
print(val if val is not None else '')
" 2>/dev/null
    # Unreadable config yields empty, which every caller already treats as
    # "not set". A genuinely broken models.yml surfaces at launch, where the
    # values are actually required — not as a traceback per field lookup.
}

# -- Credential redaction -----------------------------------------------------
# THE INVARIANT: container logs and inspect output are untrusted for display.
# A server's startup output can restate its own configuration, including values
# supplied as secrets, and does not separate those from anything else. Nothing
# in these tools prints that output raw.
#
# This matters because 03_vllm_servers.sh deliberately passes the bearer token
# as an environment variable rather than a CLI flag, to keep it out of `ps aux`.
# A diagnostic that echoes raw server output to a terminal, a scrollback buffer,
# or a pasted bug report hands that protection straight back.
#
# Pattern passes first, then a literal pass on the live key, so a shape the
# patterns miss still cannot leak the one secret we hold. Implemented in
# python3, not sed: the literal pass needs the secret treated as text, and
# hand-escaping a secret into a sed expression fails in the direction that
# matters — an unescaped metacharacter either breaks the filter or silently
# stops matching and prints the key. str.replace() has no such mode.
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

# -- Server state -------------------------------------------------------------
bench_init() {
    BRAIN_PORT=$(get_field brain port)
    BRAIN_NAME=$(get_field brain served_name)
    BASE="http://localhost:${BRAIN_PORT}"
    AUTH=(-H "Authorization: Bearer ${BRAIN_API_KEY}")
}

brain_ready() {
    curl -sf --max-time 5 "${AUTH[@]}" "${BASE}/v1/models" >/dev/null 2>&1
}

require_brain() {
    if ! brain_ready; then
        echo "  ERROR: Brain not responding on port ${BRAIN_PORT}"
        echo "  Check: docker logs brain --tail 50"
        return 2
    fi
}

brain_logs() { docker logs brain 2>&1 | head -600 || echo ""; }

# -- Launching ----------------------------------------------------------------
# Always through the engine's real launcher. A tool that assembled its own
# `docker run` would measure a server this repo never starts, and its results
# would not transfer to production.
launch_engine() {
    local engine="$1" overrides="$2"
    LAUNCH_NOTE=""
    case "${engine}" in
        vllm)
            ( for kv in ${overrides}; do export "${kv?}"; done
              bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh" ) >/tmp/bench_launch.$$ 2>&1
            ;;
        sglang)
            if [ -z "$(get_field sglang docker_image)" ]; then
                LAUNCH_NOTE="no SGLang image pinned in config/models.yml (sglang.docker_image)"
                rm -f /tmp/bench_launch.$$ 2>/dev/null
                return 3
            fi
            ( for kv in ${overrides}; do export "${kv?}"; done
              launch_sglang ) >/tmp/bench_launch.$$ 2>&1
            ;;
        *)  LAUNCH_NOTE="unknown engine ${engine}"; return 4 ;;
    esac
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        LAUNCH_NOTE=$(tail -3 /tmp/bench_launch.$$ 2>/dev/null | tr '\n' ' ')
        rm -f /tmp/bench_launch.$$ 2>/dev/null
        return 1
    fi
    rm -f /tmp/bench_launch.$$ 2>/dev/null
    return 0
}

# SGLang launcher. Kept here rather than as its own script because it is only
# ever used by the matrix — boot and watchdog start vLLM, always.
#
# The strongest reported throughput configs for this model on GB10 run SGLang
# with a DFlash2 drafter. A comparison that could only launch vLLM would be
# structurally incapable of discovering that, and an engine excluded from the
# test is an engine assumed worse. Measurement is engine-agnostic — SGLang
# serves the same OpenAI /v1 surface — so only launch and validation differ.
launch_sglang() {
    local img path name port host util ctx quant attn tool reason radix
    img=$(get_field sglang docker_image)
    path=$(get_field brain local_path)
    name=$(get_field sglang served_name);  name="${name:-$(get_field brain served_name)}"
    port=$(get_field sglang port);         port="${port:-$(get_field brain port)}"
    host=$(get_field sglang bind_host);    host="${host:-127.0.0.1}"
    util=$(get_field sglang mem_fraction_static)
    util="${util:-$(get_field brain gpu_memory_utilization)}"
    ctx=$(get_field sglang max_model_len);  ctx="${ctx:-$(get_field brain max_model_len)}"
    quant=$(get_field sglang quantization)
    attn=$(get_field sglang attention_backend)
    tool=$(get_field sglang tool_call_parser)
    reason=$(get_field sglang reasoning_parser)
    radix=$(get_field sglang disable_radix_cache)

    # Speculative decoding — the whole reason SGLang is on the list.
    #
    # Our own roofline makes the community claim checkable rather than a rumour:
    # 12.04 tok/s per forward pass is the bandwidth limit and no engine changes
    # it, so a reported ~50 tok/s requires ~4.15 tokens per forward pass against
    # the 2.4-2.9 we get from MTP. That gap is a DRAFTER difference. Launching
    # SGLang without passing these flags would measure the engine while leaving
    # the only variable that could explain the claim switched off — and would
    # then report "SGLang is no faster", which would be true and meaningless.
    local spec_algo spec_steps spec_draft
    spec_algo=$(get_field sglang speculative_algorithm)
    spec_steps=$(get_field sglang speculative_num_steps)
    spec_draft=$(get_field sglang speculative_draft_model_path)

    for n in brain qwen-brain; do docker rm -f "${n}" >/dev/null 2>&1 || true; done

    # NOTE the inverted sense: SGLang's radix cache (its prefix cache) is ON by
    # default, so the knob is a DISABLE. vLLM's is opt-in. The two engines'
    # defaults differ in the exact dimension this matrix tests.
    # shellcheck disable=SC2086
    docker run -d --name brain \
        --gpus all --ipc host --network host --restart no \
        ${BRAIN_API_KEY:+-e SGLANG_API_KEY="${BRAIN_API_KEY}"} \
        $(get_extra_env_flags sglang) \
        -v "${MODELS_DIR}:/models" -v sglang-cache:/root/.cache \
        "${img}" python3 -m sglang.launch_server \
            --model-path "/models/$(basename "${path}")" \
            --served-model-name "${name}" \
            --host "${host}" --port "${port}" \
            --mem-fraction-static "${util}" \
            --context-length "${ctx}" \
            --trust-remote-code \
            ${quant:+--quantization "${quant}"} \
            ${attn:+--attention-backend "${attn}"} \
            ${tool:+--tool-call-parser "${tool}"} \
            ${reason:+--reasoning-parser "${reason}"} \
            ${spec_algo:+--speculative-algorithm "${spec_algo}"} \
            ${spec_steps:+--speculative-num-steps "${spec_steps}"} \
            ${spec_draft:+--speculative-draft-model-path "${spec_draft}"} \
            $([ "${radix}" = "true" ] && echo "--disable-radix-cache")
}

get_extra_env_flags() {
    python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
for k, v in (cfg.get('$1', {}) or {}).get('extra_env', {} ).items():
    print(f'-e {k}={v}')
" 2>/dev/null || true
}

wait_ready() {
    local timeout="${1:-900}" waited=0
    printf "    loading"
    until brain_ready; do
        if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
            echo ""
            # Keep the CAUSE, not the last lines. A pydantic validation
            # failure ends with a stable footer ("For further information
            # visit https://errors.pydantic.dev/...") and tail -2 captured
            # exactly that footer for two dflash rows — a note that said a
            # failure occurred and nothing about why, while restore_production
            # then replaced the container and destroyed the log.
            #
            # Prefer the first line that names an error; fall back to the tail
            # only when nothing matches. Also dump the full log to disk, since
            # the container it came from will not exist minutes from now.
            local logfile="${REPO_ROOT}/docs/failed-${NAME:-launch}.log"
            docker logs brain >"${logfile}" 2>&1 || true
            local cause
            cause=$(grep -iE "error|exception|not supported|unsupported|invalid|no such" "${logfile}" \
                    | grep -viE "errors\.pydantic\.dev|further information" \
                    | head -3 | redact | cut -c1-400 | tr '\n' ' ')
            [ -z "${cause}" ] && cause=$(tail -5 "${logfile}" | redact | tr '\n' ' ')
            LAUNCH_NOTE="container exited during load: ${cause} [full log: ${logfile}]"
            return 1
        fi
        if [ "${waited}" -ge "${timeout}" ]; then
            echo ""; LAUNCH_NOTE="not ready after ${timeout}s"; return 1
        fi
        sleep 10; waited=$((waited + 10)); printf "."
    done
    echo " up (${waited}s)"
}

restore_production() {
    ( unset "${!OVERRIDE_@}" 2>/dev/null || true
      bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh" >/dev/null 2>&1 ) \
        || echo "    WARN: restore failed — run scripts/start_brain_ad_hoc.sh yourself."
}

# -- Measurements (all engine-agnostic: plain OpenAI /v1 clients) -------------

# Single-stream decode rate and TTFT. Generation is pinned to exactly
# MAX_TOKENS via ignore_eos so runs are comparable; reasoning tokens count
# toward decode, because that is the real rate a user experiences.
m_decode() {
    local runs="${1:-3}" maxt="${2:-256}"
    local prompt="${PROMPT:-Explain how a hash map handles collisions, then write one in Python.}"
    DECODE_TOKS=""; TTFT_MS=""
    local out
    out=$(BASE="${BASE}" BRAIN_NAME="${BRAIN_NAME}" BRAIN_API_KEY="${BRAIN_API_KEY}" \
          RUNS="${runs}" MAX_TOKENS="${maxt}" PROMPT="${prompt}" python3 - <<'PYEOF'
import json, os, statistics, time, urllib.request
base, model, key = os.environ["BASE"], os.environ["BRAIN_NAME"], os.environ["BRAIN_API_KEY"]
runs, maxt, prompt = int(os.environ["RUNS"]), int(os.environ["MAX_TOKENS"]), os.environ["PROMPT"]
def one():
    body = {"model": model, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": maxt, "stream": True,
            "stream_options": {"include_usage": True}, "ignore_eos": True}
    req = urllib.request.Request(f"{base}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter(); ttft = None; completion = 0
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            s = raw.decode("utf-8", "replace").strip()
            if not s.startswith("data: "):
                continue
            if s[6:] == "[DONE]":
                break
            try: c = json.loads(s[6:])
            except json.JSONDecodeError: continue
            if ttft is None and c.get("choices"):
                d = c["choices"][0].get("delta") or {}
                if d.get("content") or d.get("reasoning") or d.get("reasoning_content"):
                    ttft = time.perf_counter() - t0
            if c.get("usage"):
                completion = c["usage"].get("completion_tokens", 0)
    el = time.perf_counter() - t0
    return ttft or el, (completion or maxt) / el
ttfts, rates = [], []
for _ in range(runs):
    t, r = one(); ttfts.append(t); rates.append(r)
print(f"{statistics.median(rates):.2f} {statistics.median(ttfts)*1000:.0f}")
PYEOF
    ) || return 1
    DECODE_TOKS=$(echo "${out}" | awk '{print $1}')
    TTFT_MS=$(echo "${out}" | awk '{print $2}')
}

# Aggregate throughput across parallel streams. One forward pass reads the
# whole weight set and, at batch N, emits N tokens from that single read — so
# aggregate rises with concurrency until KV cache or max_num_seqs binds.
# Multi-stream figures quoted for this model need no special technique; this is
# what checks whether the box reproduces them. Distinct prompts per stream, or
# they would all hit the prefix cache and measure cache replay.
m_concurrency() {
    local streams="${1:-1 4 8}" maxt="${2:-128}"
    AGG_MAX=""; CONC_TABLE=""
    CONC_TABLE=$(BASE="${BASE}" BRAIN_NAME="${BRAIN_NAME}" BRAIN_API_KEY="${BRAIN_API_KEY}" \
        STREAMS="${streams}" MAX_TOKENS="${maxt}" python3 - <<'PYEOF'
import json, os, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
base, model, key = os.environ["BASE"], os.environ["BRAIN_NAME"], os.environ["BRAIN_API_KEY"]
maxt = int(os.environ["MAX_TOKENS"]); levels = [int(x) for x in os.environ["STREAMS"].split()]
P = ["Explain how a hash map handles collisions, then write one in Python.",
     "Write a binary search tree with insert and delete in Rust.",
     "Describe the CAP theorem with a concrete example of each tradeoff.",
     "Implement a token bucket rate limiter in Go.",
     "Explain TCP congestion control, then diagram slow start.",
     "Write a topological sort in C++ and explain cycle detection.",
     "Compare optimistic and pessimistic locking with an example.",
     "Implement an LRU cache in Java with O(1) get and put."]
def one(i):
    body = {"model": model, "messages": [{"role": "user", "content": P[i % len(P)]}],
            "max_tokens": maxt, "stream": True,
            "stream_options": {"include_usage": True}, "ignore_eos": True}
    req = urllib.request.Request(f"{base}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter(); tok = 0
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            s = raw.decode("utf-8", "replace").strip()
            if s.startswith("data: ") and s[6:] != "[DONE]":
                try: c = json.loads(s[6:])
                except json.JSONDecodeError: continue
                if c.get("usage"): tok = c["usage"].get("completion_tokens", 0)
    return (tok or maxt), time.perf_counter() - t0
best = 0.0
for n in levels:
    w0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as pool:
        res = list(pool.map(one, range(n)))
    wall = time.perf_counter() - w0
    agg = sum(t for t, _ in res) / wall
    per = sum(t / e for t, e in res) / n
    best = max(best, agg)
    print(f"{n} streams: {agg:.1f} tok/s aggregate, {per:.1f} tok/s per-stream")
print(f"MAX {best:.1f}")
PYEOF
    ) || return 1
    AGG_MAX=$(echo "${CONC_TABLE}" | grep "^MAX " | awk '{print $2}')
    CONC_TABLE=$(echo "${CONC_TABLE}" | grep -v "^MAX ")
}

# Prefix-cache reuse, MEASURED not read back. The flag can be accepted while
# the feature is inert — the documented failure for this model — so send a long
# prefix twice with different tails and compare TTFT. Reuse shows as a sharp
# drop; an inert cache shows ~1.0x.
# Prefix caching, measured two ways, because one of them is a proxy and the
# proxy is misleading on THIS model.
#
# PREFIX_HIT_RATE is the mechanism: cached tokens served / tokens queried,
# as a delta across the two requests below. It answers "is the cache running?"
#
# PREFIX_REUSE is the TTFT speedup from re-sending the identical prefix. It
# answers a different question — "does the cache make prefill faster?" — and it
# is a NOISY answer, which is the whole reason it must not gate a verdict.
#
# Two audit runs against this same config, minutes apart, measured 0.90x and
# then 4.51x. The hit-rate counter over the same pair of runs stayed in a
# sensible band (delta 37.4%). One run of the TTFT ratio is not evidence of
# anything: it moves with server state, concurrent load, and how much of the
# prefix survived eviction.
#
# An earlier version of this comment explained the 0.90x as structural — only
# the ~16 full-attention layers of this hybrid have cacheable KV, so a hit was
# supposed to remove only a minority of prefill work. The 4.51x reading refutes
# that: cached prefill IS substantially faster here. The architecture argument
# was plausible and wrong, and it is recorded rather than deleted because it
# was reached the same way the two false PROBLEMs were — reasoning from one
# measurement instead of measuring twice.
#
# Judge the cache by the hit rate. Report the TTFT ratio as what it is — a
# noisy effect size, not an on/off switch.
m_prefix_reuse() {
    local q0 h0 q1 h1
    q0=$(metric_sum "prefix_cache_queries_total")
    h0=$(metric_sum "prefix_cache_hits_total")
    PREFIX_REUSE=$(BASE="${BASE}" BRAIN_NAME="${BRAIN_NAME}" BRAIN_API_KEY="${BRAIN_API_KEY}" \
        python3 - <<'PYEOF' 2>/dev/null || echo ""
import json, os, time, urllib.request
base, model, key = os.environ["BASE"], os.environ["BRAIN_NAME"], os.environ["BRAIN_API_KEY"]
prefix = ("Review this module.\n\n" + "\n".join(
    f"def function_{i}(a, b):\n    return a * {i} + b\n" for i in range(400)))
def ask(tail):
    body = {"model": model, "max_tokens": 8, "stream": True, "temperature": 0,
            "messages": [{"role": "user", "content": prefix + "\n\n" + tail}]}
    req = urllib.request.Request(f"{base}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            s = raw.decode("utf-8", "replace").strip()
            if s.startswith("data: ") and s[6:] != "[DONE]":
                try: c = json.loads(s[6:])
                except Exception: continue
                if c.get("choices"):
                    d = c["choices"][0].get("delta") or {}
                    if d.get("content") or d.get("reasoning") or d.get("reasoning_content"):
                        return time.perf_counter() - t0
    return time.perf_counter() - t0
cold = ask("Summarise function_1."); warm = ask("Summarise function_2.")
print(f"{cold/warm:.2f}" if warm > 0 else "")
PYEOF
    )
    q1=$(metric_sum "prefix_cache_queries_total")
    h1=$(metric_sum "prefix_cache_hits_total")
    PREFIX_HIT_RATE=""
    if [ -n "${q0}" ] && [ -n "${q1}" ] && [ -n "${h0}" ] && [ -n "${h1}" ] \
       && [ "$((q1 - q0))" -gt 0 ]; then
        PREFIX_HIT_RATE=$(python3 -c \
            "print(f'{($h1 - $h0) / ($q1 - $q0):.3f}')" 2>/dev/null || echo "")
    fi
}

# Sum one Prometheus counter by EXACT name, at full precision.
#
# Three details here are load-bearing. Each one silently produced a wrong
# answer in the previous version of this code, and together they turned a live
# speculative decoder that had drafted 350 tokens into the audit verdict
# "configured, but ZERO tokens drafted — it is not running":
#
#   1. EXACT name match. vLLM exports `<name>_total` (the counter) alongside
#      `<name>_created` (a gauge holding the Unix timestamp at which the
#      counter was created). A prefix match catches both, and adding a ~1.79e9
#      timestamp to a counter of a few hundred drowns it.
#   2. printf, not print. awk formats non-integral values with OFMT, default
#      "%.6g" — six significant digits. Once the timestamp is in the sum, the
#      before and after reads both round to the identical "1.78777e+09" and the
#      delta is exactly zero. Any change under ~1000 is erased by the format.
#   3. Empty output when the counter is ABSENT, so "this build exports no such
#      metric" stays distinguishable from a genuine zero. `END{print s+0}`
#      prints "0" for no matching lines at all, converting an unanswerable
#      question into a confident and wrong verdict.
#
# Auth is sent even though /metrics currently answers without it: the endpoint
# is unauthenticated today, not guaranteed to be tomorrow, and a probe that
# starts failing closed would fail into that same "0" — which is precisely the
# reading this function exists to make impossible.
# Takes the metric name WITHOUT its engine prefix. vLLM exports
# `vllm:spec_decode_num_draft_tokens_total`; another engine exports the same
# quantity under its own prefix. Stripping the prefix before comparing means one
# probe works across engines, and — importantly — an engine that does NOT export
# the metric still yields empty rather than a fabricated zero.
#
# The suffix is still matched EXACTLY, so `_total` never collides with
# `_created`. That distinction is the whole reason this function exists; see the
# comment above about a live speculative decoder reading as zero.
#
# Run `benchmark.sh metrics` against a live server to see what it actually
# exports before assuming any name.
metric_sum() {
    curl -sf --max-time 10 "${AUTH[@]}" "${BASE}/metrics" 2>/dev/null \
        | awk -v suf="$1" '
            {
                n1 = $1
                b = index(n1, "{"); if (b) n1 = substr(n1, 1, b - 1)
                c = index(n1, ":"); if (c) n1 = substr(n1, c + 1)
                if (n1 == suf) { s += $NF; n += 1 }
            }
            END { if (n) printf "%.0f\n", s }'
}

# Speculative decoding, measured as a delta across one known generation.
# Counters are cumulative, so a single read cannot distinguish "broken" from
# "nothing generated yet" — only a delta across known load is conclusive.
#
# Drafted alone does not decide whether speculation is WORTH anything: a draft
# that is always rejected still costs its verification pass. The acceptance
# rate is the number that decides, so it is measured here too.
m_spec_drafted() {
    local d0 d1 a0 a1 n0 n1
    d0=$(metric_sum "spec_decode_num_draft_tokens_total")
    a0=$(metric_sum "spec_decode_num_accepted_tokens_total")
    n0=$(metric_sum "spec_decode_num_drafts_total")
    curl -sf --max-time 300 "${AUTH[@]}" -H "Content-Type: application/json" \
        -X POST "${BASE}/v1/chat/completions" \
        -d "{\"model\":\"${BRAIN_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a quicksort in Python.\"}],\"max_tokens\":128}" \
        >/dev/null 2>&1
    d1=$(metric_sum "spec_decode_num_draft_tokens_total")
    a1=$(metric_sum "spec_decode_num_accepted_tokens_total")
    n1=$(metric_sum "spec_decode_num_drafts_total")

    # Absent counters yield empty, which every caller must treat as UNKNOWN.
    if [ -z "${d0}" ] || [ -z "${d1}" ]; then
        SPEC_DRAFTED=""; SPEC_ACCEPT_RATE=""; TOKENS_PER_PASS=""
        return 0
    fi
    SPEC_DRAFTED=$((d1 - d0))
    SPEC_ACCEPT_RATE=""
    if [ -n "${a0}" ] && [ -n "${a1}" ] && [ "${SPEC_DRAFTED}" -gt 0 ]; then
        SPEC_ACCEPT_RATE=$(python3 -c \
            "print(f'{($a1 - $a0) / ${SPEC_DRAFTED}:.3f}')" 2>/dev/null || echo "")
    fi

    # Tokens emitted per full forward pass through the weights. This is the
    # conversion factor between a decode RATE and a bytes-per-pass figure, and
    # without it the roofline arithmetic in cmd_bandwidth is simply wrong.
    #
    # Non-speculative decode emits one token per pass, so rate and pass count
    # are the same number and the distinction is invisible. MTP speculation
    # breaks that: one verification pass over the full weights emits the bonus
    # token plus every accepted draft. Measured here that is 1 + 186/70 = 3.66
    # tokens per weight read, so dividing bandwidth by the token rate
    # understates bytes-per-pass by 3.66x — enough to turn "moving 3x more data
    # than the weights occupy" into "at the roofline, nothing to find".
    #
    # drafts_total counts verification steps, which is the quantity wanted.
    # Steps that ran without speculation are not counted, so this slightly
    # overstates tokens-per-pass; it is an approximation and is labelled as one
    # wherever it is reported.
    TOKENS_PER_PASS=""
    if [ -n "${n0}" ] && [ -n "${n1}" ] && [ -n "${a0}" ] && [ -n "${a1}" ] \
       && [ "$((n1 - n0))" -gt 0 ]; then
        TOKENS_PER_PASS=$(python3 -c \
            "print(f'{1 + ($a1 - $a0) / ($n1 - $n0):.3f}')" 2>/dev/null || echo "")
    fi
}

# Achieved device memory bandwidth. The roofline denominator, measured rather
# than taken from a spec sheet — real LPDDR5x sustains 70-85% of spec, and the
# difference decides whether a decode rate is near-optimal or nowhere near it.
# Throwaway container: no host namespaces, no network, no mounts.
m_bandwidth() {
    local buf="${BUF_GB:-2}" iters="${ITERS:-30}"
    BANDWIDTH=$(docker run --rm --gpus all --network none \
        -e BUF_GB="${buf}" -e ITERS="${iters}" \
        --entrypoint python3 "$(get_field brain docker_image)" -c '
import os, time, torch
n = int(float(os.environ["BUF_GB"]) * (1 << 30) // 2)
iters = int(os.environ["ITERS"])
a = torch.empty(n, dtype=torch.float16, device="cuda")
b = torch.empty(n, dtype=torch.float16, device="cuda")
a.fill_(1.0)
for _ in range(5): b.copy_(a)
torch.cuda.synchronize(); t0 = time.perf_counter()
for _ in range(iters): b.copy_(a)
torch.cuda.synchronize(); dt = time.perf_counter() - t0
print(f"{2 * a.numel() * a.element_size() * iters / dt / 1e9:.1f}")
' 2>/dev/null | tail -1)
    echo "${BANDWIDTH}" | grep -qE '^[0-9.]+$' || BANDWIDTH=""
}

# -- Validation ---------------------------------------------------------------
# Did the requested parameters ACTUALLY take effect? This is what separates a
# measurement from a number. vLLM accepts flags it then silently ignores, so a
# benchmark of a config that never applied yields a real figure attributed to
# the wrong cause — worse than no figure, because it looks like evidence.
validate_runtime() {
    local overrides="$1"
    VALIDATION_NOTE=""; VALIDITY=""; KV_TOKENS=""
    PREFIX_HIT_RATE="${PREFIX_HIT_RATE:-}"; SPEC_ACCEPT_RATE="${SPEC_ACCEPT_RATE:-}"
    local problems=0 checks=0 logs
    logs=$(brain_logs)

    for kv in ${overrides}; do
        local field="${kv%%=*}"; field="${field#OVERRIDE_}"
        local want="${kv#*=}"
        checks=$((checks + 1))
        case "${field}" in
            enable_prefix_caching)
                m_prefix_reuse
                if [ -z "${PREFIX_HIT_RATE}" ]; then
                    VALIDATION_NOTE+="prefix_caching requested=${want} but hit-rate counters did not move; "
                    problems=$((problems + 1))
                else
                    local on want_on="yes"
                    on=$(python3 -c "print('yes' if ${PREFIX_HIT_RATE} >= 0.10 else 'no')")
                    [ "${want}" = "false" ] && want_on="no"
                    [ "${on}" != "${want_on}" ] && {
                        VALIDATION_NOTE+="prefix_caching requested=${want} observed=${on} (hit rate ${PREFIX_HIT_RATE}); "
                        problems=$((problems + 1)); }
                fi
                ;;
            attention_backend)
                # Match the SELECTION line, not the mention. vLLM logs
                #   Using FLASHINFER attention backend out of potential
                #   backends: ['FLASHINFER', 'TRITON_ATTN']
                # so a substring search for "TRITON" succeeds even when
                # FLASHINFER was chosen — the candidate list contains every
                # backend we might ask for. The old check was `grep -qi
                # ${want%%_*}`, which would have stamped VALID on attn-triton
                # while the server ran FlashInfer, and the whole point of the
                # attention-backend rows is to tell those two apart.
                if [ -n "${want}" ]; then
                    local sel
                    sel=$(echo "${logs}" | grep -ioE "Using [A-Z0-9_]+ attention backend" \
                          | head -1 | awk '{print $2}')
                    if [ -z "${sel}" ]; then
                        VALIDATION_NOTE+="attention_backend=${want} unverifiable — no selection line in log; "
                        problems=$((problems + 1))
                    elif [ "${sel^^}" != "${want^^}" ]; then
                        VALIDATION_NOTE+="attention_backend requested=${want} observed=${sel}; "
                        problems=$((problems + 1))
                    fi
                fi
                ;;
            extra_args)
                # Raw CLI passthrough. Only one thing is verifiable in general —
                # that the server came up at all, which wait_ready already
                # established. But when the flag names a backend, check that the
                # backend actually loaded, or this row repeats the exact failure
                # it exists to fix: requesting TRITON_ATTN, getting FLASHINFER,
                # and being recorded VALID.
                case "${want}" in
                    *attention-backend=*)
                        local req sel2
                        req="${want##*attention-backend=}"; req="${req%% *}"
                        sel2=$(echo "${logs}" | grep -ioE "Using [A-Z0-9_]+ attention backend" \
                               | head -1 | awk '{print $2}')
                        if [ -z "${sel2}" ]; then
                            VALIDATION_NOTE+="extra_args ${want} unverifiable — no selection line in log; "
                            problems=$((problems + 1))
                        elif [ "${sel2^^}" != "${req^^}" ]; then
                            VALIDATION_NOTE+="extra_args requested ${req} observed ${sel2}; "
                            problems=$((problems + 1))
                        fi
                        ;;
                esac
                ;;
            kv_cache_dtype)
                # Verified in BOTH directions. The old check only fired when
                # fp8 was requested, so the kv-bf16 row (want=auto) was checked
                # by doing nothing and then reported as "confirmed in effect".
                if echo "${logs}" | grep -qiE "kv_cache_dtype=fp8"; then
                    [ "${want}" != "fp8" ] && {
                        VALIDATION_NOTE+="kv_cache_dtype requested=${want} observed=fp8; "
                        problems=$((problems + 1)); }
                elif echo "${logs}" | grep -qiE "kv_cache_dtype=[a-z0-9]+"; then
                    [ "${want}" = "fp8" ] && {
                        VALIDATION_NOTE+="kv_cache_dtype=fp8 requested but log shows otherwise; "
                        problems=$((problems + 1)); }
                else
                    VALIDATION_NOTE+="kv_cache_dtype=${want} unverifiable — not stated in log; "
                    problems=$((problems + 1))
                fi
                ;;
            speculative_config)
                m_spec_drafted
                if [ -z "${want}" ]; then
                    [ "${SPEC_DRAFTED:-0}" != "0" ] && {
                        VALIDATION_NOTE+="speculation requested OFF but ${SPEC_DRAFTED} drafted; "
                        problems=$((problems + 1)); }
                else
                    [ "${SPEC_DRAFTED:-0}" = "0" ] && {
                        VALIDATION_NOTE+="speculation configured but ZERO tokens drafted; "
                        problems=$((problems + 1)); }
                fi
                ;;
        esac
    done

    # Checked every run regardless of overrides: is the advertised context
    # actually reachable? vLLM logs the real KV cache size once allocated, and
    # that — not max_model_len — is the true ceiling. Below it, a single
    # request can never reach the advertised window, and it fails mid-session
    # rather than at startup.
    KV_TOKENS=$(echo "${logs}" | grep -ioE "GPU KV cache size: *[0-9,]+" \
                | grep -oE "[0-9,]+" | tr -d ',' | head -1)
    local ctx; ctx=$(get_field brain max_model_len)
    if [ -n "${KV_TOKENS}" ] && [ -n "${ctx}" ] && [ "${KV_TOKENS}" -lt "${ctx}" ]; then
        VALIDATION_NOTE+="KV cache holds ${KV_TOKENS} tokens < advertised max_model_len ${ctx}; "
        problems=$((problems + 1))
    fi

    if [ "${problems}" = "0" ]; then
        VALIDITY="VALID"
        VALIDATION_NOTE="all ${checks} requested parameter(s) confirmed in effect"
    elif [ "${problems}" -le "${checks}" ]; then
        VALIDITY="PARTIAL"
    else
        VALIDITY="INVALID"
    fi
}

# -- Ledger -------------------------------------------------------------------
# The ledger is keyed on (model, name), never on name alone.
#
# Config names — baseline, spec-off, attn-triton — describe a config, not a
# model, and every model benchmarked reuses all fifteen of them. Without the
# model recorded, benchmarking a second checkpoint appends a second `baseline`
# row and render_report's dedupe silently drops the first. The result is a
# table that looks coherent and mixes two models' numbers, which is exactly the
# "real number attributed to the wrong cause" this file warns about.
#
# Identity is the weights directory, not served_name: served_name is an
# arbitrary label that can be changed without changing what ran, and the same
# weights weigh the same under any label. It is also what the roofline
# denominator is measured from.
ledger_append() {
    local model; model=$(basename "$(get_field brain local_path)" 2>/dev/null)
    MODEL="${model:-unknown}" \
    NAME="$1" ENGINE="$2" OVERRIDES="$3" \
    VALIDITY="${VALIDITY}" VALIDATION_NOTE="${VALIDATION_NOTE}" \
    DECODE_TOKS="${DECODE_TOKS:-}" TTFT_MS="${TTFT_MS:-}" AGG_MAX="${AGG_MAX:-}" \
    PREFIX_REUSE="${PREFIX_REUSE:-}" SPEC_DRAFTED="${SPEC_DRAFTED:-}" \
    PREFIX_HIT_RATE="${PREFIX_HIT_RATE:-}" SPEC_ACCEPT_RATE="${SPEC_ACCEPT_RATE:-}" \
    KV_TOKENS="${KV_TOKENS:-}" BANDWIDTH="${BANDWIDTH:-}" \
    RUNS="${RUNS:-3}" MAX_TOKENS="${MAX_TOKENS:-256}" LEDGER="${LEDGER}" \
    python3 -c "
import json, os, datetime
def num(k):
    try: return float(os.environ.get(k, ''))
    except (TypeError, ValueError): return None
rec = {'model': os.environ['MODEL'],
       'name': os.environ['NAME'], 'engine': os.environ['ENGINE'],
       'overrides': os.environ['OVERRIDES'].strip(),
       'validity': os.environ['VALIDITY'], 'note': os.environ['VALIDATION_NOTE'].strip(),
       'decode_toks': num('DECODE_TOKS'), 'ttft_ms': num('TTFT_MS'),
       'aggregate_toks': num('AGG_MAX'), 'prefix_reuse_x': num('PREFIX_REUSE'),
       'prefix_hit_rate': num('PREFIX_HIT_RATE'),
       'spec_drafted': num('SPEC_DRAFTED'), 'spec_accept_rate': num('SPEC_ACCEPT_RATE'),
       'kv_cache_tokens': num('KV_TOKENS'),
       'bandwidth_gbps': num('BANDWIDTH'),
       'runs': int(os.environ['RUNS']), 'max_tokens': int(os.environ['MAX_TOKENS']),
       'measured_at': datetime.datetime.now().astimezone().isoformat(timespec='seconds')}
with open(os.environ['LEDGER'], 'a', encoding='utf-8') as f:
    f.write(json.dumps(rec) + '\n')
"
}

# -- Report generation --------------------------------------------------------
# docs/BENCHMARKS.md is DERIVED from the ledger, never authored. Editing it by
# hand loses the edit on the next run — durable prose belongs in docs/LESSONS.md.
# Lives here rather than in its own script because benchmark.sh was its only
# caller, and a top-level file that nothing but one script invokes is just
# another thing to explain.
render_report() {
    [ -f "${LEDGER}" ] || { echo "no ledger at ${LEDGER}"; return 1; }
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

# Later measurements of the same config ON THE SAME MODEL supersede earlier
# ones. Keying on name alone would let a second model's `baseline` silently
# replace the first model's. Rows written before the model field existed are
# attributed to the legacy label rather than being merged into any real model.
LEGACY = "(model not recorded)"
by_key = {}
for r in rows:
    r.setdefault("model", LEGACY)
    r.setdefault("name", "?")
    by_key[(r["model"], r["name"])] = r
rows = list(by_key.values())
models = sorted({r["model"] for r in rows})

def f(v, spec="{:.1f}", dash="—"):
    return dash if v is None else spec.format(v)

ranked = sorted(
    [r for r in rows if r.get("validity") == "VALID" and r.get("decode_toks")],
    key=lambda r: r["decode_toks"], reverse=True)

# One recommendation, for one model. Ranking configs across different models
# would crown whichever model is intrinsically fastest and present it as a
# serving-config win. When several models are present the most recently
# measured one is the subject, and the report says so.
rec_model = None
if len(models) > 1 and ranked:
    rec_model = max(rows, key=lambda r: r.get("measured_at") or "")["model"]
    ranked = [r for r in ranked if r["model"] == rec_model]

out = []
w = out.append

if len(models) == 1:
    w(f"# Serving Configuration Benchmarks — {models[0]} on DGX Spark (GB10)")
else:
    w("# Serving Configuration Benchmarks — DGX Spark (GB10)")
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
w("it then silently ignores, and a benchmark of a config that never applied yields ")
w("a real number attributed to the wrong cause — worse than no number, because it ")
w("looks like evidence.")
w("")
w("The same trap catches the checker. Both of the first two PROBLEMs this audit ")
w("ever reported were false: a Prometheus counter summed at six significant digits ")
w("read a live speculative decoder as zero, and a TTFT threshold borrowed from ")
w("dense transformers read a prefix cache serving 55.9% of its tokens as inert. ")
w("Prefer a counter that reports the mechanism over a timing proxy that reports ")
w("its effect, and treat a threshold as a claim about a specific architecture.")
w("")

w("## Results")
w("")
if len(models) > 1:
    w("> **This table covers more than one model: " + ", ".join(f"`{m}`" for m in models) + ".** ")
    w("> Decode rates are NOT comparable across models — a smaller or sparser model is ")
    w("> faster for reasons that have nothing to do with the serving config being tested. ")
    w("> Compare rows only within a single Model value.")
    w("")
w("| Config | Engine | Validity | Decode | TTFT | Aggregate | Prefix hit | Prefix TTFT | Drafted | Accepted | KV cache |")
w("|---|---|---|---|---|---|---|---|---|---|---|")
order = {"VALID": 0, "PARTIAL": 1, "FAILED": 2, "INVALID": 3, "BLOCKED": 4}
# With one model the name alone is unambiguous. With several, the model is
# carried in the row itself so no reader can compare across models by accident.
for r in sorted(rows, key=lambda r: (r["model"],
                                     order.get(r.get("validity"), 9),
                                     -(r.get("decode_toks") or 0))
                      if len(models) > 1 else
                      (order.get(r.get("validity"), 9),
                       -(r.get("decode_toks") or 0))):
    label = r.get("name", "?") if len(models) == 1 else \
        "{} / {}".format(r["model"], r.get("name", "?"))
    w("| `{}` | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
        label, r.get("engine", "?"), r.get("validity", "?"),
        f(r.get("decode_toks"), "{:.1f} tok/s"),
        f(r.get("ttft_ms"), "{:.0f} ms"),
        f(r.get("aggregate_toks"), "{:.1f} tok/s"),
        f(r.get("prefix_hit_rate"), "{:.1%}"),
        f(r.get("prefix_reuse_x"), "{:.2f}x"),
        f(r.get("spec_drafted"), "{:.0f}"),
        f(r.get("spec_accept_rate"), "{:.1%}"),
        f(r.get("kv_cache_tokens"), "{:,.0f} tok")))
w("")
w("**Columns.** *Decode* is single-stream tok/s — what one interactive session feels like. ")
w("*Aggregate* is total tok/s at the highest concurrency tested — what the box can do in ")
w("parallel; it rises with batching and is not comparable to Decode. ")
w("")
w("*Prefix hit* is the share of queried tokens served from cache when an identical long ")
w("prefix is re-sent — **this is the column that says whether prefix caching is running**. ")
w("*Prefix TTFT* is the wall-clock speedup that bought, and it is noisy: two runs against ")
w("the same config measured 0.90x and 4.51x while the hit rate stayed stable. Read the hit ")
w("rate as the on/off switch and the TTFT ratio as an effect size worth repeating before ")
w("citing — never the reverse.")
w("")
w("*Drafted* is speculative tokens proposed during one generation — 0 while ")
w("`speculative_config` is set means speculation is dead. *Accepted* is the share of those ")
w("drafts the target model kept, and it is the one that decides whether speculation pays: ")
w("rejected drafts still cost their verification pass. *KV cache* is the real context ")
w("ceiling in tokens; if it is below `max_model_len`, the advertised context window cannot ")
w("be reached.")
w("")

w("## Recommendation")
w("")
if rec_model:
    w(f"*Scoped to the most recently measured model, `{rec_model}`. Other models in ")
    w("the ledger are reported in the table above but not ranked here.*")
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
    w("`bash scripts/03_vllm_servers.sh`:")
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
    if best.get("prefix_hit_rate") is not None and best["prefix_hit_rate"] < 0.10:
        w(f"> **Warning — the fastest config has a dead prefix cache.** "
          f"`{best['name']}` served {best['prefix_hit_rate']:.1%} of a repeated "
          f"identical prefix from cache. Single-stream decode is not the metric that "
          f"decides agentic coding: without prefix reuse, every turn reprocesses "
          f"the whole conversation, which costs far more wall-clock than the "
          f"decode-rate lead wins back.")
        w("")
        alt = next((r for r in ranked
                    if (r.get("prefix_hit_rate") or 0) >= 0.10), None)
        if alt:
            w(f"> Prefer **`{alt['name']}`** ({alt['decode_toks']:.1f} tok/s, "
              f"{alt['prefix_hit_rate']:.1%} hit rate) for interactive and agentic use, "
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
}

RUNS="${RUNS:-3}"
MAX_TOKENS="${MAX_TOKENS:-256}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"
STREAMS="${STREAMS:-1 4 8}"

CMD="all"
ONLY=""
REDO=0
while [ $# -gt 0 ]; do
    case "$1" in
        audit|quick|bandwidth|matrix|render|list|all) CMD="$1"; shift ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --redo) REDO=1; shift ;;
        # Measure against YOUR workload, not the built-in prompt.
        #
        # This matters most for prompt-lookup (ngram). The default prompt writes
        # fresh prose from nothing, which is prompt-lookup's WORST case — it
        # drafted 10 tokens across an entire generation and scored 12.46 tok/s,
        # barely above no speculation at all. That number says nothing about
        # agentic coding, where output echoes files already in context, which is
        # prompt-lookup's best case. Judging ngram on the default prompt would
        # rule out the one technique most likely to suit how this box is used.
        --prompt-file)
            [ -r "${2:-}" ] || { echo "cannot read prompt file: ${2:-<missing>}"; exit 1; }
            PROMPT=$(cat "$2"); export PROMPT
            echo "  prompt: ${2} ($(wc -c < "$2") bytes)"
            shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

bench_init

# =============================================================================
# THE MATRIX
# =============================================================================
# name | engine | OVERRIDE_field=value ...
#
# ONE FACTOR AT A TIME from the baseline, deliberately, not a full cross
# product. A product of five parameters is hundreds of hours of model loads and
# still would not say WHICH factor moved the number. OFAT attributes cause.
# The INTERACTION rows are the exception: those settings are known to trade
# against each other, so testing them separately would mislead.
#
# An empty value UNSETS the field (spec-off), which is distinct from omitting it.
MATRIX=$(cat <<'EOF'
baseline|vllm|
prefix-off|vllm|OVERRIDE_enable_prefix_caching=false
attn-triton|vllm|OVERRIDE_attention_backend=TRITON_ATTN
attn-triton-cli|vllm|OVERRIDE_extra_args=--attention-backend=TRITON_ATTN
attn-flashinfer|vllm|OVERRIDE_attention_backend=FLASHINFER
kv-bf16|vllm|OVERRIDE_kv_cache_dtype=auto
spec-off|vllm|OVERRIDE_speculative_config=
spec-mtp3|vllm|OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":3}
spec-mtp2|vllm|OVERRIDE_speculative_config={"method":"mtp","num_speculative_tokens":2}
spec-ngram5|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4}
spec-ngram3|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":3,"prompt_lookup_max":4}
spec-ngram8|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":8,"prompt_lookup_max":8,"prompt_lookup_min":2}
spec-ngram-tuned|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":6,"prompt_lookup_max":10,"prompt_lookup_min":5}
spec-ngram-narrow|vllm|OVERRIDE_speculative_config={"method":"ngram","num_speculative_tokens":4,"prompt_lookup_max":10,"prompt_lookup_min":5}
spec-dflash7|vllm|OVERRIDE_speculative_config={"method":"dflash","model":"__DRAFT__","num_speculative_tokens":7}
spec-dflash3|vllm|OVERRIDE_speculative_config={"method":"dflash","model":"__DRAFT__","num_speculative_tokens":3}
util-080|vllm|OVERRIDE_gpu_memory_utilization=0.80
INTERACTION-flashinfer-bf16kv|vllm|OVERRIDE_attention_backend=FLASHINFER OVERRIDE_kv_cache_dtype=auto
INTERACTION-triton-util080|vllm|OVERRIDE_attention_backend=TRITON_ATTN OVERRIDE_gpu_memory_utilization=0.80
sglang-baseline|sglang|
sglang-radix-off|sglang|OVERRIDE_disable_radix_cache=true
EOF
)

# =============================================================================
cmd_list() {
    echo ""
    echo "Matrix ($(echo "${MATRIX}" | grep -c '|') configurations):"
    while IFS='|' read -r n e o; do
        [ -z "${n}" ] && continue
        printf "  %-32s %-9s %s\n" "${n}" "[${e}]" "${o:-<models.yml as committed>}"
    done <<< "${MATRIX}"
    echo ""
    echo "Already measured (${LEDGER}):"
    if [ -s "${LEDGER}" ]; then
        LEDGER="${LEDGER}" python3 -c "
import json, os
for line in open(os.environ['LEDGER'], encoding='utf-8'):
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    d = r.get('decode_toks')
    print(f\"  {r.get('name','?'):<32} {r.get('validity','?'):<8} {d if d else '—'} tok/s\")
"
    else
        echo "  (none yet — run: bash scripts/benchmark.sh)"
    fi
    echo ""
}

cmd_render() { render_report; }

# What does the running server ACTUALLY export? Read-only, instant.
#
# Exists because the alternative is guessing metric names for a new engine, and
# a guessed name that does not match is indistinguishable from a feature that is
# switched off — which is exactly how this tool once reported a live speculative
# decoder as dead. Run this against SGLang before trusting any SGLang row.
cmd_metrics() {
    require_brain || return 2
    echo ""
    echo "-- Metrics exported by the running server --"
    local raw
    raw=$(curl -sf --max-time 10 "${AUTH[@]}" "${BASE}/metrics" 2>/dev/null)
    if [ -z "${raw}" ]; then
        echo "   /metrics returned nothing — wrong port, or the engine does not export Prometheus."
        return 2
    fi
    echo "   $(echo "${raw}" | grep -c '^[a-z]') sample lines total"
    echo ""
    echo "   Cache / speculation / prefix metrics (what the audit needs):"
    echo "${raw}" | grep -oE '^[a-z_]+:?[a-z_0-9]+' | sort -u \
        | grep -iE "cache|spec|draft|accept|prefix|radix" | sed 's/^/     /' \
        || echo "     (none found — the audit will report UNKNOWN, which is correct)"
    echo ""
    echo "   The audit matches these names WITHOUT their engine prefix, so"
    echo "   vllm:X and sglang:X both resolve. If the suffixes differ, the"
    echo "   checks report UNKNOWN rather than guessing."
}

cmd_quick() {
    require_brain || return 2
    echo ""
    echo "-- Quick benchmark: ${BRAIN_NAME} --"
    echo "   ${RUNS} runs x ${MAX_TOKENS} tokens"
    m_decode "${RUNS}" "${MAX_TOKENS}" || { echo "   measurement failed"; return 2; }
    echo "   decode : ${DECODE_TOKS} tok/s"
    echo "   TTFT   : ${TTFT_MS} ms"
}

cmd_bandwidth() {
    echo ""
    echo "-- Bandwidth probe --"
    echo "   Measuring achieved device bandwidth (spec sheet for GB10 is 273 GB/s;"
    echo "   real LPDDR5x sustains 70-85% of spec, which is why this is measured)."
    m_bandwidth
    if [ -z "${BANDWIDTH}" ]; then
        echo "   FAILED. Try a smaller buffer: BUF_GB=1 bash scripts/benchmark.sh bandwidth"
        return 2
    fi
    echo "   achieved: ${BANDWIDTH} GB/s"
    if require_brain 2>/dev/null; then
        m_decode 1 128
        # Speculation must be measured before the arithmetic, not after. The
        # roofline compares bytes read per FORWARD PASS against the weights;
        # the decode rate counts TOKENS. Those are the same number only when
        # each pass emits one token, which is exactly what speculative decoding
        # stops being true. Getting this wrong does not produce a slightly-off
        # ratio, it flips the verdict.
        m_spec_drafted
        local wpath; wpath=$(get_field brain local_path)
        local wgb=""; [ -d "${wpath}" ] && wgb=$(du -sb "${wpath}" 2>/dev/null | awk '{printf "%.1f", $1/1e9}')

        # DENSE vs MoE. The ratio compares bytes-read-per-pass against the
        # weights a pass actually READS. For a dense model that is the whole
        # checkpoint. For a Mixture-of-Experts it is emphatically not: only a
        # few experts fire per token, so a 35B-A3B reads roughly a tenth of its
        # own file per pass.
        #
        # Left uncorrected, an MoE would land near 0.2x, fall into the "< 1.25"
        # branch, and print "the roofline is REAL, config tuning cannot beat
        # it" — a confident verdict computed from the wrong denominator, which
        # is the exact failure this whole file exists to prevent. Worse, it
        # would be printed about the model we are most likely to try next.
        #
        # So: if the checkpoint declares experts and nobody has supplied the
        # active weight size, this reports UNKNOWN and explains why. An honest
        # blank beats a confident wrong number.
        local active_gb; active_gb=$(get_field brain active_weight_gb)
        local moe=""
        [ -f "${wpath}/config.json" ] && moe=$(grep -oE '"(num_experts|n_routed_experts|num_local_experts|num_experts_per_tok)"' \
            "${wpath}/config.json" 2>/dev/null | head -1)

        BANDWIDTH="${BANDWIDTH}" DECODE_TOKS="${DECODE_TOKS}" WGB="${wgb}" \
        MOE="${moe}" ACTIVE_GB="${active_gb}" \
        TPP="${TOKENS_PER_PASS:-}" ACC="${SPEC_ACCEPT_RATE:-}" python3 -c "
import os
bw, toks = float(os.environ['BANDWIDTH']), float(os.environ['DECODE_TOKS'])
tpp_raw = os.environ.get('TPP') or ''
tpp = float(tpp_raw) if tpp_raw else 1.0
print(f'   decode  : {toks:.1f} tok/s')
if tpp_raw and tpp > 1.01:
    acc = os.environ.get('ACC') or '?'
    print(f'   speculation ACTIVE: {tpp:.2f} tokens per forward pass '
          f'(acceptance {acc})')
    print(f'   => forward passes  : {toks / tpp:.1f} /s')
elif tpp_raw:
    print('   speculation measured, but ~1 token per pass (drafts not landing)')
else:
    print('   speculation NOT measurable — assuming 1 token per forward pass.')
    print('   If speculation is in fact running, every figure below understates')
    print('   bytes-per-pass and the verdict may be inverted.')
per = bw * tpp / toks
print(f'   => bytes per FORWARD PASS: {per:.1f} GB')
w = os.environ.get('WGB') or ''
if not w:
    raise SystemExit(0)
weights = float(w)

# An MoE reads only its active experts per pass, so the checkpoint size is the
# wrong denominator and every verdict below would be computed from it.
active = os.environ.get('ACTIVE_GB') or ''
if active:
    weights = float(active)
    print(f'   active weights: {weights:.1f} GB (declared, not the {w} GB checkpoint)')
elif os.environ.get('MOE'):
    print(f'   checkpoint on disk: {weights:.1f} GB')
    print('')
    print('   *** RATIO NOT COMPUTED — this checkpoint declares experts ***')
    print('   A Mixture-of-Experts reads only its active experts per forward')
    print('   pass, so comparing bytes-per-pass against the whole checkpoint')
    print('   understates the ratio several-fold and would print \"the roofline')
    print('   is REAL\" for a model nowhere near it.')
    print('')
    print('   Set brain.active_weight_gb in config/models.yml to the bytes one')
    print('   token actually reads — shared layers plus experts_per_tok worth')
    print('   of expert weights — and re-run. Until then this is UNKNOWN, which')
    print('   is not the same as fine.')
    raise SystemExit(0)
ratio = per / weights
print(f'   checkpoint on disk: {weights:.1f} GB   ratio: {ratio:.2f}x')
print('')
# The ceiling is per-pass. What a user feels is per-token, which speculation
# multiplies, so both are reported and neither is allowed to stand for the other.
ceil_pass = bw / weights
if ratio < 1.25:
    print(f'   Weights are read at roughly their quantized width. The roofline is')
    print(f'   REAL: ~{ceil_pass:.1f} forward passes/s, i.e. ~{ceil_pass * tpp:.1f} tok/s')
    print(f'   at the measured {tpp:.2f} tokens per pass. Config tuning cannot beat')
    print('   it — going faster needs FEWER BYTES (lower-bit quant), or MORE TOKENS')
    print('   PER PASS (higher speculative acceptance).')
elif ratio < 1.6:
    print('   Somewhat more traffic than the weights occupy. Some is legitimate')
    print('   (KV reads, activations). Check the attention backend and quant')
    print('   kernel before concluding you are at a ceiling.')
else:
    print('   *** MOVING FAR MORE DATA THAN THE WEIGHTS OCCUPY ***')
    print('   This is NOT a bandwidth ceiling, it is a serving-path problem, and')
    print('   ordinary config work has real headroom. Check the quant kernel')
    print('   fallback, the attention backend vs kv_cache_dtype, and CUDA-graph')
    print(f'   state. A correct path would sustain ~{ceil_pass * tpp:.1f} tok/s')
    print(f'   at the measured {tpp:.2f} tokens per pass.')
"
    fi
}

cmd_audit() {
    require_brain || return 2
    echo ""
    echo "============================================================"
    echo " Serving Audit — declared vs actual"
    echo "============================================================"
    echo "  models.yml declares:"
    printf "    %-24s %s\n" \
        "max_model_len"          "$(get_field brain max_model_len)" \
        "kv_cache_dtype"         "$(get_field brain kv_cache_dtype)" \
        "enable_prefix_caching"  "$(get_field brain enable_prefix_caching)" \
        "attention_backend"      "$(get_field brain attention_backend || true)" \
        "gpu_memory_utilization" "$(get_field brain gpu_memory_utilization)"
    echo ""
    echo ">>> Startup decisions (redacted)"
    # Patterns and limits both matter here. The CUDA-graph downgrade line
    # (FULL_AND_PIECEWISE -> PIECEWISE under spec-decode) appeared in one audit
    # run and vanished from the next, not because the server stopped doing it
    # but because head -12 cut it off once an extra warning appeared above it.
    # A diagnostic whose findings depend on how many other lines matched is not
    # a diagnostic. Lines are truncated for display so a single 4KB config dump
    # cannot push the decisions out of view; redaction runs before truncation.
    brain_logs | grep -iE "attention backend|using .*attn|flashinfer|kv cache dtype|prefix cach|speculative|cudagraph|artifactory|fall(ing)? ?back|jit" \
        | head -24 | redact | cut -c1-300 | sed 's/^/    /'
    echo ""
    echo ">>> Measured behaviour"
    m_prefix_reuse
    m_spec_drafted
    validate_runtime ""

    # Every check reports one of three states, never two. A check that could
    # not run is UNKNOWN, not a pass — collapsing those into "fine" is how a
    # green result stops meaning anything (LESSONS #17). An earlier version of
    # this function did exactly that: it printed the drafted-token count but
    # never failed on zero, so a dead speculative decoder produced a clean bill
    # of health.
    local problems=0 unknowns=0
    check() {  # check <label> <state OK|PROBLEM|UNKNOWN> <detail>
        printf "    %-16s %-8s %s\n" "$1" "[$2]" "$3"
        [ "$2" = "PROBLEM" ] && problems=$((problems + 1))
        [ "$2" = "UNKNOWN" ] && unknowns=$((unknowns + 1))
        return 0
    }

    # Judged on the hit-rate counter, not on TTFT. An earlier version of this
    # check used a >=1.8x TTFT speedup as the pass mark and called a cache
    # serving 55.9% of its queried tokens "INERT" — the threshold was borrowed
    # from dense-transformer behaviour and this model is a hybrid. The TTFT
    # ratio is still reported, as an effect size rather than a verdict.
    local want_prefix; want_prefix=$(get_field brain enable_prefix_caching)
    local ttft_note=""
    [ -n "${PREFIX_REUSE}" ] && ttft_note=" (TTFT ${PREFIX_REUSE}x)"
    if [ -z "${PREFIX_HIT_RATE}" ]; then
        check "prefix cache" UNKNOWN "vllm:prefix_cache_*_total did not move — Brain busy, or the probe failed"
    elif [ "$(python3 -c "print(1 if ${PREFIX_HIT_RATE} < 0.10 else 0)")" = "1" ]; then
        if [ "${want_prefix}" = "true" ]; then
            check "prefix cache" PROBLEM "hit rate ${PREFIX_HIT_RATE} on a repeated identical prefix — flag is true but the cache is INERT"
        else
            check "prefix cache" OK "hit rate ${PREFIX_HIT_RATE} — off, and not requested"
        fi
    else
        check "prefix cache" OK "hit rate ${PREFIX_HIT_RATE} — serving cached tokens${ttft_note}"
    fi

    local want_spec; want_spec=$(get_field brain speculative_config)
    local acc_note=""
    [ -n "${SPEC_ACCEPT_RATE}" ] && acc_note=", ${SPEC_ACCEPT_RATE} accepted"
    if [ -z "${SPEC_DRAFTED}" ]; then
        check "speculation" UNKNOWN "no vllm:spec_decode_*_total counters exported by this build"
    elif [ -n "${want_spec}" ] && [ "${SPEC_DRAFTED}" = "0" ]; then
        check "speculation" PROBLEM "configured, but ZERO tokens drafted — it is not running"
    elif [ -n "${want_spec}" ]; then
        check "speculation" OK "${SPEC_DRAFTED} tokens drafted${acc_note}"
    else
        check "speculation" OK "not configured, ${SPEC_DRAFTED} drafted"
    fi

    local ctx; ctx=$(get_field brain max_model_len)
    if [ -z "${KV_TOKENS}" ]; then
        check "context" UNKNOWN "no 'GPU KV cache size' line found in the log"
    elif [ "${KV_TOKENS}" -lt "${ctx}" ]; then
        check "context" PROBLEM "KV cache holds ${KV_TOKENS} tokens < advertised ${ctx}"
    else
        check "context" OK "KV cache holds ${KV_TOKENS} tokens >= advertised ${ctx}"
    fi

    echo ""
    if [ "${problems}" -gt 0 ]; then
        echo "  ${problems} PROBLEM(S) FOUND — fix these before tuning anything else."
        [ "${want_prefix}" = "true" ] && [ -n "${PREFIX_HIT_RATE}" ] && \
          [ "$(python3 -c "print(1 if ${PREFIX_HIT_RATE} < 0.10 else 0)")" = "1" ] && {
            echo "  A dead prefix cache means every agent turn reprocesses the whole"
            echo "  conversation. That costs more in real use than any decode tuning wins."; }
        echo "============================================================"
        return 1
    fi
    if [ "${unknowns}" -gt 0 ]; then
        echo "  No problems found, but ${unknowns} check(s) could not be evaluated."
        echo "  This is NOT a clean bill of health — an UNKNOWN is a check that did"
        echo "  not run, not one that passed. Resolve those before trusting results."
        echo "============================================================"
        return 2
    fi
    echo "  All checks passed. Declared config matches observed behaviour."
    echo "============================================================"
    return 0
}

cmd_matrix() {
    echo ""
    echo "============================================================"
    echo " Config Matrix"
    echo "============================================================"
    echo "  Ledger : ${LEDGER}"
    echo "  Report : ${REPORT}"
    echo "  Runs   : ${RUNS} x ${MAX_TOKENS} tokens per configuration"
    echo ""
    echo "  Brain is restarted once per configuration and is DOWN throughout."
    echo "  Expect hours. Ctrl-C is safe: progress is kept and production"
    echo "  config is restored on exit."
    echo ""
    read -r -p "  Continue? [y/N] " C
    case "${C}" in [yY]|[yY][eE][sS]) ;; *) echo "  Aborted."; return 0 ;; esac

    # spark-watchdog.timer restarts Brain from models.yml whenever the port is
    # silent past its grace window. Mid-matrix that replaces the configuration
    # under test with the committed one and misattributes the results —
    # silently. Worse for SGLang rows: watchdog recovery starts vLLM, swapping
    # the ENGINE out from under a measurement.
    WATCHDOG_WAS_ACTIVE=0
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet spark-watchdog.timer 2>/dev/null; then
        WATCHDOG_WAS_ACTIVE=1
        echo ""
        echo ">>> Stopping spark-watchdog.timer for the duration..."
        sudo systemctl stop spark-watchdog.timer || {
            echo "    ERROR: could not stop the watchdog. It would race the matrix"
            echo "    and misattribute results. Aborting."
            return 1
        }
    fi
    cleanup() {
        echo ""
        echo ">>> Restoring production configuration..."
        restore_production
        if [ "${WATCHDOG_WAS_ACTIVE}" = "1" ]; then
            echo ">>> Restarting spark-watchdog.timer..."
            sudo systemctl start spark-watchdog.timer \
                || echo "    WARN: could not restart the timer — start it manually."
        fi
        echo ">>> Report: ${REPORT}"
    }
    trap cleanup EXIT INT TERM

    mkdir -p "$(dirname "${LEDGER}")"; touch "${LEDGER}"
    MATCHED=0

    while IFS='|' read -r NAME ENGINE OVERRIDES; do
        [ -z "${NAME}" ] && continue
        if [ -n "${ONLY}" ] && ! echo ",${ONLY}," | grep -q ",${NAME},"; then continue; fi
        MATCHED=$((MATCHED + 1))
        # Skip only rows that actually HOLD a measurement. BLOCKED and FAILED
        # record the absence of one — a missing image, an engine that would not
        # start — and those are exactly the rows you return to after fixing the
        # blocker. Treating them as "already measured" means pinning the SGLang
        # image and re-running silently skips the row you just enabled, and
        # reports success while measuring nothing.
        PRIOR=$(grep "\"name\": \"${NAME}\"" "${LEDGER}" 2>/dev/null | tail -1)
        if [ "${REDO}" = "0" ] && [ -n "${PRIOR}" ]; then
            if echo "${PRIOR}" | grep -qE '"validity": "(BLOCKED|FAILED)"'; then
                echo ""
                echo "RETRY ${NAME} — previously $(echo "${PRIOR}" \
                    | grep -oE '"validity": "[A-Z]+"' | grep -oE '[A-Z]+'), not a measurement"
            else
                echo ""; echo "SKIP ${NAME} — already measured (--redo to repeat)"; continue
            fi
        fi

        echo ""
        echo "============================================================"
        echo " ${NAME}   [${ENGINE}]"
        echo "   ${OVERRIDES:-<models.yml as committed>}"
        echo "============================================================"

        # Every measured variable resets here. A row whose launch FAILS runs no
        # measurements, and anything left set would be written to the ledger
        # under this row's name — attributing the previous config's numbers to
        # this one. That is the worst possible ledger entry: plausible, wrong,
        # and indistinguishable from a real result later.
        # __DRAFT__ rows need a drafter checkpoint that is not part of this
        # model. Substitute the configured path, or record BLOCKED — the same
        # treatment SGLang gets without a pinned image. BLOCKED is "we did not
        # measure this", which is different from FAILED ("we tried and it broke")
        # and from a slow number. Launching anyway would burn a 5-minute model
        # load on every run to re-learn that no checkpoint is configured.
        if [ "${OVERRIDES}" != "${OVERRIDES/__DRAFT__/}" ]; then
            DRAFT_PATH=$(get_field brain speculative_draft_model)
            if [ -z "${DRAFT_PATH}" ]; then
                VALIDITY="BLOCKED"
                VALIDATION_NOTE="no drafter pinned in config/models.yml (brain.speculative_draft_model)"
                echo "    BLOCKED — ${VALIDATION_NOTE}"
                ledger_append "${NAME}" "${ENGINE}" "${OVERRIDES}"
                continue
            fi
            # HOST path -> CONTAINER path. MODELS_DIR is bind-mounted at
            # /models, so a host path handed to the engine verbatim fails:
            #
            #   Value error, Invalid repository ID or local directory
            #   specified: '/opt/models/qwen38-27b-dflash2'
            #
            # The brain's own weights are already translated at launch
            # (--model "/models/$(basename ...)"), but the draft model rides
            # through the speculative_config JSON untouched, so it needed the
            # same treatment.
            #
            # Only absolute paths are rewritten. An HF repo id such as
            # incoai/Qwen3.8-27B-DFlash2 contains a slash but does not start
            # with one, and must be passed through unchanged for the engine to
            # resolve it from the cache.
            case "${DRAFT_PATH}" in
                /*) DRAFT_PATH="/models/$(basename "${DRAFT_PATH}")" ;;
            esac
            OVERRIDES="${OVERRIDES//__DRAFT__/${DRAFT_PATH}}"
        fi

        VALIDITY=""; VALIDATION_NOTE=""; LAUNCH_NOTE=""
        DECODE_TOKS=""; TTFT_MS=""; AGG_MAX=""; PREFIX_REUSE=""
        SPEC_DRAFTED=""; KV_TOKENS=""; BANDWIDTH=""
        PREFIX_HIT_RATE=""; SPEC_ACCEPT_RATE=""; TOKENS_PER_PASS=""

        launch_engine "${ENGINE}" "${OVERRIDES}"
        case $? in
            0)  if wait_ready "${READY_TIMEOUT}"; then
                    validate_runtime "${OVERRIDES}"
                    echo "    validity: ${VALIDITY} — ${VALIDATION_NOTE}"
                    m_decode "${RUNS}" "${MAX_TOKENS}"
                    m_concurrency "${STREAMS}" 128
                    [ -z "${PREFIX_REUSE}" ] && m_prefix_reuse
                    [ -z "${SPEC_DRAFTED}" ] && m_spec_drafted
                    echo "    decode ${DECODE_TOKS:-?} tok/s | aggregate ${AGG_MAX:-?} | reuse ${PREFIX_REUSE:-?}x | drafted ${SPEC_DRAFTED:-?}"
                else
                    VALIDITY="FAILED"; VALIDATION_NOTE="${LAUNCH_NOTE}"
                    echo "    FAILED — ${LAUNCH_NOTE}"
                fi ;;
            3)  VALIDITY="BLOCKED"; VALIDATION_NOTE="${LAUNCH_NOTE}"
                echo "    BLOCKED — ${LAUNCH_NOTE}" ;;
            *)  VALIDITY="FAILED";  VALIDATION_NOTE="${LAUNCH_NOTE}"
                echo "    FAILED — ${LAUNCH_NOTE}" ;;
        esac

        ledger_append "${NAME}" "${ENGINE}" "${OVERRIDES}"
        cmd_render >/dev/null 2>&1 || true
    done <<< "${MATRIX}"

    # A --only that matches nothing ran zero configurations and, before this
    # check, said so by printing the report and exiting 0. That happened for
    # real: a branch adding two new rows was not pushed, the Spark filtered on
    # names its copy did not have, and the run reported success having measured
    # nothing. Silence is the one thing a benchmark must never mean.
    if [ -n "${ONLY}" ] && [ "${MATCHED}" -eq 0 ]; then
        echo ""
        echo "  ERROR: --only '${ONLY}' matched no configuration in the matrix."
        echo "  Nothing was measured. Known names:"
        echo "${MATRIX}" | cut -d'|' -f1 | grep -v '^$' | sed 's/^/    /'
        echo ""
        echo "  If a name above is missing, this checkout predates it — git pull."
        return 1
    fi

    cmd_render
}

case "${CMD}" in
    list)      cmd_list ;;
    render)    cmd_render ;;
    quick)     cmd_quick ;;
    audit)     cmd_audit ;;
    bandwidth) cmd_bandwidth ;;
    metrics)   cmd_metrics ;;
    matrix)    cmd_matrix ;;
    all)
        # The default: everything needed to fill docs/BENCHMARKS.md.
        # Audit first — it can find a problem that makes the rest moot.
        echo ""
        echo "############################################################"
        echo "# Full benchmark run — audit, then matrix, then report"
        echo "############################################################"
        cmd_audit || echo "  (audit found a mismatch — recorded, continuing)"
        cmd_matrix
        ;;
esac
