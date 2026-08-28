#!/usr/bin/env bash
# =============================================================================
# Stack Health Check — spark-sovereign
# Checks Brain, GPU, OpenClaw gateway, Telegram, Whisper STT, and memory.
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
keys = '$1'.split('.')
node = cfg
for k in keys:
    node = node.get(k, {})
print(node if isinstance(node, (str, int, float)) else '')
" 2>/dev/null || echo ""
}

BRAIN_PORT=$(get_field brain.port)
BRAIN_NAME=$(get_field brain.served_name)
BRAIN_HF=$(get_field brain.hf_repo)
BRAIN_CTX=$(get_field brain.max_model_len)
BRAIN_UTIL=$(get_field brain.gpu_memory_utilization)
BRAIN_KV=$(get_field brain.kv_cache_dtype)
OPENCLAW_PORT=$(get_field infrastructure.nemoclaw.ui_port)
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
WHISPER_MODEL="${WHISPER_MODEL:-small}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          spark-sovereign — Stack Health Check            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── System memory ─────────────────────────────────────────────────────────────
echo "── System Memory ───────────────────────────────────────────"
free -h | grep -E "Mem|Swap"
echo ""

# ── GPU ───────────────────────────────────────────────────────────────────────
echo "── GPU / VRAM ──────────────────────────────────────────────"
nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{
        gsub(/ /,"",$2); gsub(/ /,"",$3);
        printf "  %-28s  Util: %s%%   Temp: %s°C\n",$1,$2,$3
    }'
echo ""
echo "  Processes consuming VRAM:"
GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,used_gpu_memory,name \
    --format=csv,noheader,nounits 2>/dev/null || true)
if [ -z "${GPU_PROCS}" ]; then
    echo "    (none)"
else
    while IFS=',' read -r pid mib pname; do
        pid="${pid// /}"; mib="${mib// /}"; pname="${pname## }"
        gb=$(python3 -c "print(f'{int(\"${mib}\")/1024:.1f}')" 2>/dev/null || echo "?")
        proc=$(ps -p "${pid}" -o comm= 2>/dev/null || echo "unknown")
        printf "    PID %-8s  %-24s  %s GiB  (%s)\n" "${pid}" "${pname}" "${gb}" "${proc}"
    done <<< "${GPU_PROCS}"
fi
echo ""

# ── Docker containers ─────────────────────────────────────────────────────────
echo "── Docker Containers ───────────────────────────────────────"
ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}|{{.Status}}|{{.Image}}|{{.RunningFor}}" 2>/dev/null)
if [ -z "${ALL_CONTAINERS}" ]; then
    echo "  (none found)"
else
    printf "  %-22s %-14s %-38s %s\n" "NAME" "STATUS" "IMAGE" "RUNNING FOR"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "${ALL_CONTAINERS}" | while IFS='|' read -r name status image uptime; do
        icon="❌"; echo "${status}" | grep -q "^Up" && icon="✅"
        printf "  ${icon} %-20s %-14s %-38s %s\n" \
            "${name}" "${status:0:13}" "${image:0:37}" "${uptime}"
    done
fi
echo ""

# ── Brain ─────────────────────────────────────────────────────────────────────
echo "── Brain (vLLM) ────────────────────────────────────────────"
BRAIN_RESULT=$(curl -sf --max-time 5 -H "Authorization: Bearer ${BRAIN_API_KEY}" \
    "http://localhost:${BRAIN_PORT}/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" \
    2>/dev/null || echo "")
if [ -n "${BRAIN_RESULT}" ]; then
    printf "  ✅ Brain  (port %-5s)  model: %s\n" "${BRAIN_PORT}" "${BRAIN_RESULT}"
else
    printf "  ❌ Brain  (port %-5s)  not responding\n" "${BRAIN_PORT}"
    echo "     Fix: docker logs brain --tail 50"
fi
echo ""
echo "  HF model     : ${BRAIN_HF}"
echo "  Base URL     : http://localhost:${BRAIN_PORT}/v1"
echo "  Model ID     : ${BRAIN_NAME}"
if [ -n "${BRAIN_API_KEY}" ]; then
    # Masked on purpose — check_stack output gets pasted into issues and chats.
    echo "  API key      : set, ${#BRAIN_API_KEY} chars, ends ...${BRAIN_API_KEY: -4}  (read: grep BRAIN_API_KEY .env)"
else
    echo "  API key      : none configured  (any string works)"
fi
echo "  Context      : ${BRAIN_CTX} tokens"
echo "  KV dtype     : ${BRAIN_KV}"
echo "  GPU util     : ${BRAIN_UTIL} (~$(python3 -c "print(round(121.69 * ${BRAIN_UTIL}))")GB reserved)"
echo ""

# ── OpenClaw gateway ──────────────────────────────────────────────────────────
echo "── OpenClaw Gateway ────────────────────────────────────────"
if command -v openclaw &>/dev/null; then
    GATEWAY_STATE=$(openclaw gateway status 2>/dev/null | grep "Runtime:" | head -1 || echo "")
    if echo "${GATEWAY_STATE}" | grep -q "running"; then
        printf "  ✅ Gateway running  (port %s)\n" "${OPENCLAW_PORT}"
    else
        printf "  ❌ Gateway not running\n"
        echo "     Fix: openclaw gateway start"
    fi

    # Telegram — use `openclaw config get channels.telegram.enabled` as the
    # source of truth. The `openclaw status` text format drifted between
    # OpenClaw versions and previously produced false "not connected"
    # warnings here even when Telegram was working perfectly.
    TG_ENABLED=$(openclaw config get channels.telegram.enabled 2>/dev/null || echo "")
    if [ "${TG_ENABLED}" = "true" ]; then
        # Best-effort live probe for the bot @handle via structured JSON.
        # Safe if the JSON shape drifts — we just omit the handle on failure.
        TG_BOT=$(openclaw status --deep --json --timeout 5000 2>/dev/null | \
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def walk(x):
    if isinstance(x, dict):
        for _, v in x.items():
            if isinstance(v, str) and v.startswith('@'):
                yield v
            yield from walk(v)
    elif isinstance(x, list):
        for i in x:
            yield from walk(i)
for h in walk(data):
    print(h); break
" 2>/dev/null || echo "")
        if [ -n "${TG_BOT}" ]; then
            printf "  ✅ Telegram: enabled  (%s)\n" "${TG_BOT}"
        else
            printf "  ✅ Telegram: enabled\n"
        fi
    elif [ "${TG_ENABLED}" = "false" ]; then
        printf "  ℹ️  Telegram: disabled in config\n"
    else
        printf "  ⚠️  Telegram: config unreadable (is openclaw on PATH?)\n"
    fi

    # Session count — pull from the text status if available; skip on drift.
    SESSIONS=$(openclaw status 2>/dev/null | sed 's/\x1B\[[0-9;]*[mK]//g' | grep "Session store" | grep -oP '\d+ entr' || echo "")
    [ -n "${SESSIONS}" ] && echo "  Sessions: ${SESSIONS}ies"

    # Telegram group policy — informational only. In allowlist mode with no
    # entries, group messages are dropped but 1:1 DMs still work. Only
    # relevant if you want the bot to respond in group chats.
    GROUP_POLICY=$(openclaw config get channels.telegram.groupPolicy 2>/dev/null || echo "")
    GROUP_ALLOW=$(openclaw config get channels.telegram.groupAllowFrom 2>/dev/null || echo "")
    if [ "${GROUP_POLICY}" = "allowlist" ] && [ -z "${GROUP_ALLOW}" ]; then
        echo ""
        echo "  ℹ️  Telegram groups: allowlist mode with no entries (DMs work; group messages dropped)"
        echo "     If you want the bot to answer in groups: openclaw config set channels.telegram.groupPolicy open"
    fi
else
    # Fallback: plain HTTP probe
    OC_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
        "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null || echo "000")
    if [ "${OC_CODE}" = "200" ]; then
        printf "  ✅ OpenClaw responding on port %s\n" "${OPENCLAW_PORT}"
    else
        printf "  ❌ OpenClaw not responding (HTTP %s)\n" "${OC_CODE}"
        echo "     Fix: openclaw gateway start"
    fi
fi
echo ""


# ── OpenClaw routing ──────────────────────────────────────────────────────────
# Everything above this point can be green while the agent is completely dead.
# On 2026-08-27 the Brain was healthy, the gateway was running and Telegram was
# connected — and every message failed, because agents.defaults.model pointed at
# a provider namespace that did not exist. This section is the check that was
# missing: it asks what OpenClaw would ACTUALLY route to, rather than whether
# the parts are individually up.
#
# It also enforces the project's one non-negotiable: nothing off-box. A cloud
# entry in the failover list is not a health issue, it is a data-egress issue,
# and it comes back every time a config wizard writes a default list.
echo "── OpenClaw Routing ────────────────────────────────────────"
if ! command -v openclaw &>/dev/null; then
    echo "  (openclaw not on PATH — skipping)"
else
    # `openclaw config get` prefixes its JSON with a banner line, so every parse
    # starts at the first brace rather than consuming the whole stream.
    OC_PROVIDERS=$(openclaw config get models.providers 2>/dev/null | sed -n '/^{/,$p' || true)
    OC_FALLBACKS=$(openclaw config get agents.defaults.models 2>/dev/null | sed -n '/^{/,$p' || true)
    OC_AGENT=$(openclaw config get agents.defaults.model 2>/dev/null \
        | grep -v '^[[:space:]]*$' | tail -1 | tr -d '"' | tr -d '[:space:]' || true)

    if [ -z "${OC_PROVIDERS}" ]; then
        echo "  ⚠️  could not read models.providers (openclaw config get failed)"
    else
        # One parse for all three questions, so "local" is defined exactly once:
        # a provider whose baseUrl resolves to this host on the Brain's port.
        # Never a name pattern — providers can be called anything.
        printf '%s' "${OC_PROVIDERS}" | python3 -c "
import json, sys
from urllib.parse import urlparse

LOCAL = {'localhost', '127.0.0.1', '0.0.0.0', '::1'}
port, served, agent, fallbacks_raw = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

try:
    providers = json.load(sys.stdin)
except Exception:
    print('  ⚠️  models.providers did not parse as JSON')
    sys.exit(0)

local_names, offbox = [], []
for name, cfg in sorted(providers.items()):
    if not isinstance(cfg, dict):
        continue
    raw = str(cfg.get('baseUrl', ''))
    url = urlparse(raw)
    ids = [m.get('id') for m in (cfg.get('models') or []) if isinstance(m, dict)]
    if url.hostname in LOCAL and (url.port or 0) == port:
        local_names.append(name)
        ok = served in ids
        print('  %s provider %-10s -> %s%s'
              % ('✅' if ok else '⚠️ ', name, raw,
                 '' if ok else '   <- does not list \'%s\'' % served))
    elif url.hostname not in LOCAL:
        offbox.append(name)
        print('  ❌ provider %-10s -> %s   <- OFF-BOX' % (name, raw))

# The check tonight turned on: is the agent aimed at anything that exists?
prov = agent.split('/')[0] if '/' in agent else ''
if not agent:
    print('  ⚠️  agents.defaults.model is unset')
elif prov in local_names:
    print('  ✅ agent model  : %s' % agent)
else:
    print('  ❌ agent model  : %s' % agent)
    print('     Provider \'%s\' is not a local provider. Every request fails with' % prov)
    print('     \"Unknown model\" regardless of how correct the API key is.')
    print('     Fix: openclaw config set agents.defaults.model <provider>/%s' % served)

# Failover list. OpenRouter is BUILT IN to OpenClaw — there is no
# models.providers.openrouter to delete — so an entry here is the only thing
# that makes it selectable, and a wizard run can put it back at any time.
try:
    entries = list(json.loads(fallbacks_raw).keys()) if fallbacks_raw.strip() else []
except Exception:
    entries = []
bad = [e for e in entries if e.split('/')[0] not in local_names]
if bad:
    print('')
    print('  ❌ agents.defaults.models lists %d entr%s not served by this box:'
          % (len(bad), 'y' if len(bad) == 1 else 'ies'))
    for e in bad:
        print('       %s' % e)
    print('     Failover walks this list in order, so these are reached whenever')
    print('     the local model is unavailable. With one brain on this box there')
    print('     is nowhere legitimate to fall back to — trim to the local model.')

if offbox:
    print('')
    print('  ❌ %d off-box provider(s): %s' % (len(offbox), ', '.join(offbox)))
    print('     This project is local-first. Remove them.')
" "${BRAIN_PORT}" "${BRAIN_NAME}" "${OC_AGENT}" "${OC_FALLBACKS}" 2>/dev/null \
            || echo "  ⚠️  routing check failed (is python3 present?)"
    fi
fi
echo ""
# ── Whisper STT ───────────────────────────────────────────────────────────────
echo "── Whisper STT ─────────────────────────────────────────────"
WHISPER_CACHE="${HOME}/.cache/whisper"
if command -v whisper &>/dev/null; then
    WHISPER_BIN="$(command -v whisper)"
    printf "  ✅ whisper CLI : %s\n" "${WHISPER_BIN}"
else
    printf "  ❌ whisper CLI : not found\n"
    echo "     Fix: bash scripts/04_voice_pipeline.sh"
fi
if [ -f "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" ]; then
    SIZE=$(du -sh "${WHISPER_CACHE}/${WHISPER_MODEL}.pt" 2>/dev/null | cut -f1)
    printf "  ✅ model cache : %s/%s.pt  (%s)\n" "${WHISPER_CACHE}" "${WHISPER_MODEL}" "${SIZE}"
else
    printf "  ❌ model cache : %s/%s.pt not found\n" "${WHISPER_CACHE}" "${WHISPER_MODEL}"
    echo "     Fix: bash scripts/04_voice_pipeline.sh"
fi
echo "  Note: OpenClaw auto-detects whisper — no manual config needed."
echo ""

# ── Memory search ─────────────────────────────────────────────────────────────
echo "── Memory Search (embeddings) ──────────────────────────────"
if command -v openclaw &>/dev/null; then
    MEM_ENABLED=$(openclaw config get agents.defaults.memorySearch.enabled 2>/dev/null || echo "")
    MEM_PROVIDER=$(openclaw config get agents.defaults.memorySearch.provider 2>/dev/null || echo "")
    # "auto" or empty means OpenClaw tries cloud API keys — check if any are set in .env
    HAS_EMBED_KEY=false
    for var in OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY VOYAGE_API_KEY MISTRAL_API_KEY; do
        [ -n "${!var:-}" ] && HAS_EMBED_KEY=true && break
    done
    if [ "${MEM_ENABLED}" = "false" ]; then
        echo "  ℹ️  Memory search: disabled"
        echo "     Enable: openclaw config set agents.defaults.memorySearch.enabled true"
    elif [ "${MEM_ENABLED}" = "true" ] && [ -z "${MEM_PROVIDER}" ] && [ "${HAS_EMBED_KEY}" = "false" ]; then
        echo "  ⚠️  Memory search: enabled but no embedding provider ready"
        echo "     Auto mode requires an API key (OpenAI/Gemini/Voyage/Mistral) or local model."
        echo "     Fix (local, no cloud key): openclaw configure --section model"
        echo "     Fix (disable):             openclaw config set agents.defaults.memorySearch.enabled false"
        echo "     Verify:                    openclaw memory status --deep"
    elif [ -n "${MEM_PROVIDER}" ] && [ "${MEM_PROVIDER}" != "auto" ]; then
        printf "  ✅ Memory search: enabled (provider: %s)\n" "${MEM_PROVIDER}"
    elif [ "${HAS_EMBED_KEY}" = "true" ]; then
        # A cloud embedding key IS present and the provider is auto, so OpenClaw
        # will send memory contents off this box. Flag it — local-only is the
        # entire point of this build.
        printf "  ⚠️  Memory search: auto mode with a CLOUD embedding key in .env\n"
        printf "     Memory contents leave the Spark on every index and search.\n"
        printf "     Local instead: openclaw configure --section model\n"
        printf "     Verify:        openclaw memory status --deep\n"
    else
        # Fallthrough: the config lookups returned nothing usable, which happens
        # when OpenClaw does not expose this path (it moved between versions).
        # Previously this branch printed a green "API key found" without ever
        # reading HAS_EMBED_KEY — a false all-clear on a privacy-relevant line.
        printf "  ℹ️  Memory search: state unknown — could not read OpenClaw config\n"
        printf "     No cloud embedding key in .env, so nothing is leaving the box.\n"
        printf "     Confirm with:  openclaw memory status --deep\n"
    fi
else
    echo "  (openclaw not on PATH — skipping)"
fi
echo ""

# ── Skills ────────────────────────────────────────────────────────────────────
# openclaw doctor is interactive — don't run it here, just report from config
echo "── Skills ──────────────────────────────────────────────────"
if command -v openclaw &>/dev/null; then
    echo "  Run for full report: openclaw doctor"
    echo "  Run to auto-fix:     openclaw doctor --repair"
else
    echo "  (openclaw not on PATH — skipping)"
fi
echo ""

# ── Auto-start service ────────────────────────────────────────────────────────
echo "── Auto-Start Service ──────────────────────────────────────"
SVC_STATUS=$(systemctl is-active spark-sovereign 2>/dev/null) || SVC_STATUS="inactive"
SVC_ENABLED=$(systemctl is-enabled spark-sovereign 2>/dev/null) || SVC_ENABLED="unknown"
OC_SVC=$(systemctl --user is-active openclaw-gateway 2>/dev/null) || OC_SVC="inactive"
OC_ENABLED=$(systemctl --user is-enabled openclaw-gateway 2>/dev/null) || OC_ENABLED="unknown"

if [ "${SVC_ENABLED}" = "enabled" ]; then
    printf "  ✅ spark-sovereign.service: enabled (status: %s)\n" "${SVC_STATUS}"
    [ "${SVC_STATUS}" = "inactive" ] && echo "     Normal — oneshot, runs on boot."
else
    printf "  ❌ spark-sovereign.service: not enabled\n"
    echo "     Fix: bash scripts/01_system_prep.sh"
fi

if [ "${OC_ENABLED}" = "enabled" ]; then
    printf "  ✅ openclaw-gateway.service: enabled (status: %s)\n" "${OC_SVC}"
else
    printf "  ⚠️  openclaw-gateway.service: not enabled (%s)\n" "${OC_SVC}"
    echo "     Fix: openclaw doctor --repair"
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Done. See docs/TROUBLESHOOTING.md for common fixes.     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
