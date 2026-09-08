#!/usr/bin/env bash
# =============================================================================
# AD-HOC — Put HuggingFace models into the vault, for later use or testing
# =============================================================================
# NOT part of the numbered setup sequence (00 -> 04). A helper you run when you
# want weights on this box before — or without — committing to serving them.
#
# WHY THE VAULT AND NOT /opt/models: 02_download_models.sh moves any
# /opt/models directory that no models.yml section claims into the vault on its
# next run. A model parked in /opt/models "to test later" is churn; the vault is
# where an unused model is meant to live. Nothing here touches /opt/models, and
# nothing here deletes anything.
#
# HOW 02 FINDS WHAT THIS WRITES: not by directory name — by the repo and commit
# recorded in <dir>/DOWNLOADED_REVISION.txt. That file is the contract between
# this script and 02's vault_entries_for(); its four keys are load-bearing, and
# a directory without it can only ever be matched by name.
#
# USAGE
#   bash scripts/vault_add.sh <hf-repo> [<hf-repo> ...] [options]
#   bash scripts/vault_add.sh --list                  # what is in the vault
#
#   -y, --yes        do not ask before downloading (for unattended batches)
#   -n, --dry-run    resolve, size and disk-check everything; download nothing
#   --revision <r>   pin a ref or SHA        (single repo only)
#   --name <dir>     vault directory name    (single repo only)
#
# Many repos in one run is the point: they are planned together, confirmed once,
# downloaded one at a time, and summarised at the end with what landed and what
# did not. A gated repo does not stop the batch.
#
# EXIT CODES: 0 everything landed or was already here, 2 bad arguments,
# 3 some were skipped (gated/unreachable — not a breakage), 1 a real failure.
#
# TOKENS — nothing is ever stored by this script:
#   Public models need none. For a gated repo you are prompted once per run;
#   the value is not echoed, not saved, and used for that process only. Press
#   Enter to skip the model instead.
#   For a batch, export it for the session so you are not asked per repo:
#       read -rs HF_TOKEN && export HF_TOKEN     # not echoed, not in history
#       bash scripts/vault_add.sh repo1 repo2 --yes
#   An exported HF_TOKEN takes precedence over .env.
#
#   A TOKEN DOES NOT BYPASS GATING. "requires approval" means the account is
#   not approved: request access on the model's page first.
#
# ENV
#   ARCHIVE_DIR   default /opt/model-archive. MUST be the same filesystem as
#                 /opt/models, or 02 cannot rename it into service later.
#   MODELS_DIR    default /opt/models. Read only, to skip what is already live.
#
# Rationale: docs/LESSONS.md #21. Behaviour: README "Downloaded once, kept forever".
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Capture before sourcing. `.env` assigns HF_TOKEN unconditionally, so without
# this an HF_TOKEN exported in the caller's shell is silently replaced by
# whatever is on disk — which defeats the entire "paste it for this session
# only, never store it" workflow.
_HF_TOKEN_FROM_SHELL="${HF_TOKEN:-}"
source "${REPO_ROOT}/.env" 2>/dev/null || true
if [ -n "${_HF_TOKEN_FROM_SHELL}" ]; then
    HF_TOKEN="${_HF_TOKEN_FROM_SHELL}"
fi

ARCHIVE_DIR="${ARCHIVE_DIR:-/opt/model-archive}"
MODELS_DIR="${MODELS_DIR:-/opt/models}"
STAGING_DIR="${ARCHIVE_DIR}/.staging"

export PATH="$HOME/.local/bin:$PATH"
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_TOKEN="${HF_TOKEN:-}"

# A non-empty non-token is worse than none: it authenticates as nobody and
# suppresses every "you have no token" path, including the prompt that would
# fix it. Real tokens are hf_ prefixed.
if [ -n "${HF_TOKEN}" ] && ! printf '%s' "${HF_TOKEN}" | grep -qE '^hf_[A-Za-z0-9_-]+$'; then
    echo "  NOTE: HF_TOKEN is set but is not a token (they start with 'hf_')."
    echo "        Ignoring it and continuing unauthenticated. If it came from"
    echo "        .env, blank the line: HF_TOKEN="
    echo ""
    HF_TOKEN=""
    export HF_TOKEN
fi

# Guards re-prompting within one run. Keyed on "have we asked", NOT on whether
# a token exists: a wrong or unapproved token is worth asking about once.
TOKEN_PROMPTED=0

REPOS=()
NAME=""
REVISION=""
DRY_RUN=0
LIST=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l)     LIST=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --name)        NAME="${2:-}"; shift ;;
        --name=*)      NAME="${1#--name=}" ;;
        --revision)    REVISION="${2:-}"; shift ;;
        --revision=*)  REVISION="${1#--revision=}" ;;
        -h|--help)     sed -n '2,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)            echo "Unknown option: $1 (try --help)"; exit 2 ;;
        *)             REPOS+=("$1") ;;
    esac
    shift
done

# ── Helpers ──────────────────────────────────────────────────────────────────

# Same reader 02 uses. The format is the contract between the two scripts.
revision_field() {
    local dir="$1" key="$2"
    [ -f "${dir}/DOWNLOADED_REVISION.txt" ] || return 0
    sed -n "s/^${key}=//p" "${dir}/DOWNLOADED_REVISION.txt" | head -1
}

human() {
    python3 -c "
b = float(${1:-0})
if b <= 0:
    print('unknown')
else:
    for u in ('B', 'KB', 'MB', 'GB', 'TB'):
        if b < 1000 or u == 'TB':
            print('%.1f %s' % (b, u)); break
        b /= 1000.0
" 2>/dev/null || echo "unknown"
}

vault_listing() {
    echo "Vault: ${ARCHIVE_DIR}"
    if [ ! -d "${ARCHIVE_DIR}" ] || [ -z "$(ls -A "${ARCHIVE_DIR}" 2>/dev/null)" ]; then
        echo "  (empty)"
        return 0
    fi
    local d
    for d in "${ARCHIVE_DIR}"/*/; do
        d="${d%/}"
        [ -d "${d}" ] || continue
        printf '\n  %s\n' "$(basename "${d}")"
        printf '    size:     %s\n' "$(du -sh "${d}" 2>/dev/null | awk '{print $1}')"
        printf '    repo:     %s\n' "$(revision_field "${d}" repo)"
        printf '    revision: %s\n' "$(revision_field "${d}" resolved_sha)"
        printf '    saved:    %s\n' "$(revision_field "${d}" downloaded)"
        if [ -z "$(revision_field "${d}" repo)" ]; then
            echo "    NOTE: no revision record — 02 can only match this by directory"
            echo "          name, never by commit."
        fi
    done
    # Total and headroom: the only decision this listing supports is what to
    # keep, and neither number is guessable from the per-entry sizes.
    echo ""
    printf '  TOTAL: %s in the vault\n' \
        "$(du -sh "${ARCHIVE_DIR}" 2>/dev/null | awk '{print $1}')"
    local avail
    avail="$(df -Pk "${ARCHIVE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 * 1024}')"
    [ -n "${avail}" ] && [ "${avail}" -gt 0 ] 2>/dev/null &&
        printf '  FREE:  %s on that filesystem\n' "$(human "${avail}")"
}

if [ "${LIST}" -eq 1 ]; then
    vault_listing
    echo ""
    echo "Nothing here is ever deleted automatically. To reclaim space:"
    echo "  sudo rm -rf ${ARCHIVE_DIR}/<name>"
    exit 0
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "ERROR: no model given."
    echo "  bash scripts/vault_add.sh <hf-repo> [<hf-repo> ...] [-y] [-n]"
    echo "  bash scripts/vault_add.sh --list"
    exit 2
fi

# --name and --revision identify ONE build, so they cannot apply to a list.
if [ "${#REPOS[@]}" -gt 1 ]; then
    if [ -n "${NAME}" ]; then
        echo "ERROR: --name applies to a single repo, but ${#REPOS[@]} were given."
        exit 2
    fi
    if [ -n "${REVISION}" ]; then
        echo "ERROR: --revision applies to a single repo, but ${#REPOS[@]} were given."
        echo "Pin one at a time; the rest resolve to latest on main."
        exit 2
    fi
fi

case "${NAME}" in
    "") ;;
    */*|.|..) echo "ERROR: --name must be a plain directory name, got '${NAME}'."; exit 2 ;;
esac

for r in "${REPOS[@]}"; do
    if ! printf '%s' "${r}" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
        echo "ERROR: '${r}' does not look like a HuggingFace repo id."
        echo "Expected <org>/<model>, e.g. unsloth/Qwen3.8-27B-NVFP4."
        exit 2
    fi
done

require_hf() {
    command -v hf >/dev/null 2>&1 && return 0
    echo ""
    echo "  ERROR: hf CLI not found in PATH, and this needs to download."
    echo "  PATH=${PATH}"
    echo ""
    echo "  Same fix as 02_download_models.sh — this box is PEP 668"
    echo "  externally-managed, so --user fails outright:"
    echo "    pip install -U huggingface_hub --break-system-packages"
    exit 1
}

ask() {
    local __var="$2" reply=""
    ( : < /dev/tty ) 2>/dev/null || return 1
    while read -r -t 0 2>/dev/null; do read -r _ 2>/dev/null || break; done
    printf '%s' "$1" > /dev/tty
    read -r reply < /dev/tty || return 1
    printf -v "${__var}" '%s' "${reply}"
}

# Ask for a token at the one moment it is needed, and keep it for this process
# only. DELIBERATELY NOT PERSISTED: a credential in a dotfile outlives the
# reason it was created. Read with -s so it is neither echoed nor left in
# shell history. Asks at most once per run, whether or not a token already
# exists — an unapproved token is worth asking about, but only once.
prompt_for_token() {
    [ "${TOKEN_PROMPTED}" -eq 0 ] || return 1
    TOKEN_PROMPTED=1
    ( : < /dev/tty ) 2>/dev/null || return 1
    local t=""
    {
        echo ""
        if [ -n "${HF_TOKEN}" ]; then
            echo "  ${1} refused the token already in use — that account is not"
            echo "  approved for it. A token does NOT bypass gating."
        else
            echo "  ${1} is gated or private, so it needs a token."
        fi
        echo "  Paste a token for an APPROVED account, or press Enter to skip."
        echo "  Not echoed, not saved, not written to .env — this run only."
        echo "  Tokens: https://huggingface.co/settings/tokens (Read is enough)"
        echo "  Access: request it on the model's page first, or this will fail again."
        printf '  token: '
    } > /dev/tty
    read -rs t < /dev/tty || { echo "" > /dev/tty; return 1; }
    echo "" > /dev/tty
    [ -n "${t}" ] || return 1
    HF_TOKEN="${t}"
    export HF_TOKEN
    return 0
}

# Empty on any failure. Empty means "unknown", never "changed" — same rule as 02.
resolve_upstream_sha() {
    python3 - "$1" "${2:-}" <<'PYEOF' 2>/dev/null || echo ""
import json, os, sys, urllib.request
repo, rev = sys.argv[1], (sys.argv[2] or "main")
hdrs = {}
tok = os.environ.get("HF_TOKEN", "")
if tok:
    hdrs["Authorization"] = f"Bearer {tok}"
try:
    req = urllib.request.Request(
        f"https://huggingface.co/api/models/{repo}/revision/{rev}", headers=hdrs)
    with urllib.request.urlopen(req, timeout=15) as r:
        print(json.load(r).get("sha", ""))
except Exception:
    print("")
PYEOF
}

# Total bytes from the repo file listing. 0 when unknown — the disk check is
# then skipped rather than guessed at.
resolve_repo_size() {
    python3 - "$1" "${2:-}" <<'PYEOF' 2>/dev/null || echo 0
import json, os, sys, urllib.request
repo, rev = sys.argv[1], (sys.argv[2] or "main")
hdrs = {}
tok = os.environ.get("HF_TOKEN", "")
if tok:
    hdrs["Authorization"] = f"Bearer {tok}"
try:
    url = f"https://huggingface.co/api/models/{repo}/revision/{rev}?blobs=true"
    with urllib.request.urlopen(
            urllib.request.Request(url, headers=hdrs), timeout=20) as r:
        data = json.load(r)
    print(sum(s.get("size") or 0 for s in data.get("siblings", [])))
except Exception:
    print(0)
PYEOF
}

# Where these exact weights already sit, if anywhere. Matched on repo + SHA the
# same way 02 does it, so "already have it" means the same in both scripts.
already_present() {
    local repo="$1" sha="$2" d
    [ -n "${sha}" ] || return 1
    for d in "${ARCHIVE_DIR}"/*/ "${MODELS_DIR}"/*/; do
        d="${d%/}"
        [ -d "${d}" ] || continue
        [ "$(revision_field "${d}" repo)" = "${repo}" ] || continue
        [ "$(revision_field "${d}" resolved_sha)" = "${sha}" ] || continue
        printf '%s' "${d}"
        return 0
    done
    return 1
}

echo "========================================================"
echo " vault_add — ${#REPOS[@]} model(s)"
echo "========================================================"
echo "  vault: ${ARCHIVE_DIR}"
[ -z "${HF_TOKEN}" ] && echo "  token: none (gated repos will prompt once, or be skipped)"
[ -n "${HF_TOKEN}" ] && echo "  token: present"
echo ""

# ── Preflight, once for the whole batch ──────────────────────────────────────
sudo mkdir -p "${ARCHIVE_DIR}" || exit 1
if [ -d "${MODELS_DIR}" ]; then
    a_dev="$(stat -c %d "${ARCHIVE_DIR}" 2>/dev/null || echo x)"
    m_dev="$(stat -c %d "${MODELS_DIR}" 2>/dev/null || echo y)"
    if [ "${a_dev}" != "${m_dev}" ]; then
        echo "  ERROR: ${ARCHIVE_DIR} and ${MODELS_DIR} are on different filesystems."
        echo "  02 puts a vaulted model into service by renaming it, and refuses to"
        echo "  cross devices — anything downloaded here could never be used."
        exit 1
    fi
fi

# ── Plan: resolve every repo before downloading any ──────────────────────────
PLAN_REPO=()
PLAN_SHA=()
PLAN_DEST=()
PLAN_SIZE=()
SKIPPED=()
TOTAL=0

echo "  Planning:"
for repo in "${REPOS[@]}"; do
    sha=""
    if printf '%s' "${REVISION}" | grep -qE '^[0-9a-f]{40}$'; then
        sha="${REVISION}"
    else
        sha="$(resolve_upstream_sha "${repo}" "${REVISION}")"
    fi

    # A private repo exposes no metadata at all unauthenticated, so it fails
    # HERE rather than at download time — and would be skipped without ever
    # offering the token that would fix it. Ask now, then resolve again.
    if [ -z "${sha}" ] && prompt_for_token "${repo}"; then
        sha="$(resolve_upstream_sha "${repo}" "${REVISION}")"
    fi

    if [ -z "${sha}" ]; then
        printf '    %-52s UNRESOLVED\n' "${repo}"
        SKIPPED+=("${repo}  (could not resolve — gated, private, gone or offline)")
        continue
    fi

    if where="$(already_present "${repo}" "${sha}")"; then
        printf '    %-52s HAVE  %s\n' "${repo}" "$(basename "${where}")"
        continue
    fi

    name="${NAME}"
    [ -n "${name}" ] || name="${repo%%/*}__${repo##*/}"
    dest="${ARCHIVE_DIR}/${name}"
    if [ -e "${dest}" ]; then
        dest="${ARCHIVE_DIR}/${name}@${sha:0:12}"
        n=2
        while [ -e "${dest}" ]; do
            dest="${ARCHIVE_DIR}/${name}@${sha:0:12}-${n}"
            n=$(( n + 1 ))
        done
    fi

    size="$(resolve_repo_size "${repo}" "${sha}")"
    printf '    %-52s FETCH %s\n' "${repo}" "$(human "${size}")"
    PLAN_REPO+=("${repo}")
    PLAN_SHA+=("${sha}")
    PLAN_DEST+=("${dest}")
    PLAN_SIZE+=("${size}")
    TOTAL=$(( TOTAL + size ))
done

if [ "${#PLAN_REPO[@]}" -eq 0 ]; then
    echo ""
    echo "  Nothing to download."
    if [ "${#SKIPPED[@]}" -gt 0 ]; then
        echo ""
        echo "  Could not be resolved:"
        printf '    %s\n' "${SKIPPED[@]}"
        exit 3
    fi
    exit 0
fi

echo ""
echo "  To download: ${#PLAN_REPO[@]} model(s), $(human "${TOTAL}")"
AVAIL="$(df -Pk "${ARCHIVE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 * 1024}')"
if [ -n "${AVAIL}" ] && [ "${AVAIL}" -gt 0 ] 2>/dev/null; then
    echo "  Free on disk: $(human "${AVAIL}")"
    if [ "${TOTAL}" -gt 0 ] && [ "${AVAIL}" -lt $(( TOTAL + TOTAL / 10 )) ]; then
        echo ""
        echo "  ERROR: not enough free space, counting a 10% margin."
        exit 1
    fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    echo ""
    echo "  Dry run — nothing downloaded."
    [ "${#SKIPPED[@]}" -gt 0 ] && printf '  skipped: %s\n' "${SKIPPED[@]}"
    exit 0
fi

# One confirmation for the batch, not one per model.
if [ "${ASSUME_YES}" -eq 0 ] && [ -t 1 ]; then
    echo ""
    echo "  Downloads into the vault only. Does not touch ${MODELS_DIR},"
    echo "  models.yml, or anything running."
    ans=""
    ask "  Type y to start, anything else to stop: " ans || ans="y"
    case "${ans}" in
        y|Y|yes|Yes|YES) ;;
        *) echo "  Stopped. Nothing downloaded."; exit 0 ;;
    esac
fi

require_hf
sudo mkdir -p "${STAGING_DIR}" || exit 1
sudo chown "$(id -u):$(id -g)" "${STAGING_DIR}" || exit 1

# ── Download ─────────────────────────────────────────────────────────────────
DONE=()
FAILED=()

i=0
while [ "${i}" -lt "${#PLAN_REPO[@]}" ]; do
    repo="${PLAN_REPO[$i]}"
    sha="${PLAN_SHA[$i]}"
    dest="${PLAN_DEST[$i]}"
    stage="${STAGING_DIR}/$(basename "${dest}")"
    i=$(( i + 1 ))

    echo ""
    echo "  ── [${i}/${#PLAN_REPO[@]}] ${repo}"
    mkdir -p "${stage}" || { FAILED+=("${repo}  (cannot create staging dir)"); continue; }

    # Staged then renamed in. An interrupted pull must never look complete: 02's
    # reuse path only checks that a directory is non-empty, so a half-downloaded
    # tree in the vault would be offered as a working model.
    if ! hf download "${repo}" --local-dir "${stage}" ${REVISION:+--revision "${REVISION}"}; then
        if prompt_for_token "${repo}" &&
           hf download "${repo}" --local-dir "${stage}" ${REVISION:+--revision "${REVISION}"}; then
            :
        else
            echo "  SKIPPED ${repo} — not downloaded. Partial left in ${stage}"
            SKIPPED+=("${repo}  (access denied / requires approval)")
            continue
        fi
    fi

    # The contract with 02. Without these four keys the directory is findable
    # only by name, never by commit.
    printf 'repo=%s\nrevision=%s\nresolved_sha=%s\ndownloaded=%s\n' \
        "${repo}" "${REVISION:-main}" "${sha}" "$(date -Iseconds)" \
        > "${stage}/DOWNLOADED_REVISION.txt"

    if ! sudo mv "${stage}" "${dest}"; then
        FAILED+=("${repo}  (could not move into the vault)")
        continue
    fi
    echo "  OK ${repo} -> ${dest}"
    DONE+=("${repo}")
done

rmdir "${STAGING_DIR}" 2>/dev/null || true

# ── Summary, then what the vault actually holds ──────────────────────────────
echo ""
echo "========================================================"
echo " Summary"
echo "========================================================"
[ "${#DONE[@]}" -gt 0 ]    && { echo "  Downloaded (${#DONE[@]}):";    printf '    %s\n' "${DONE[@]}"; }
[ "${#SKIPPED[@]}" -gt 0 ] && { echo "  Skipped (${#SKIPPED[@]}):";    printf '    %s\n' "${SKIPPED[@]}"; }
[ "${#FAILED[@]}" -gt 0 ]  && { echo "  Failed (${#FAILED[@]}):";      printf '    %s\n' "${FAILED[@]}"; }
echo ""
vault_listing
echo ""
echo "  To serve any of these: point config/models.yml at its hf_repo and run"
echo "  02. It matches on the recorded commit and offers it back — answer y."

[ "${#FAILED[@]}" -gt 0 ]  && exit 1
[ "${#SKIPPED[@]}" -gt 0 ] && exit 3
exit 0
