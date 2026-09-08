#!/usr/bin/env bash
# =============================================================================
# AD-HOC — Put any HuggingFace model into the vault, for later use or testing
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
#   bash scripts/vault_add.sh <hf-repo> [--name <dir>] [--revision <ref|sha>]
#   bash scripts/vault_add.sh <hf-repo> --dry-run     # size + disk check only
#   bash scripts/vault_add.sh --list                  # what is in the vault
#
# EXAMPLES
#   bash scripts/vault_add.sh lyf/Qwen3.8-27B-Heretic-ARA-NVFP4-MTP-VL
#   bash scripts/vault_add.sh unsloth/Qwen3.8-27B-NVFP4 --revision 9e3f1c0b
#   bash scripts/vault_add.sh some/model --name my-test-build
#
# ENV
#   ARCHIVE_DIR   default /opt/model-archive. MUST be the same filesystem as
#                 /opt/models, or 02 cannot rename it into service later.
#   MODELS_DIR    default /opt/models. Read only, to report what is already live.
#   HF_TOKEN      read from .env; needed for gated repos.
#
# Rationale: docs/LESSONS.md #21. User-facing behaviour: README "Downloaded
# once, kept forever".
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

ARCHIVE_DIR="${ARCHIVE_DIR:-/opt/model-archive}"
MODELS_DIR="${MODELS_DIR:-/opt/models}"
STAGING_DIR="${ARCHIVE_DIR}/.staging"

export PATH="$HOME/.local/bin:$PATH"
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_TOKEN="${HF_TOKEN:-}"

REPO=""
NAME=""
REVISION=""
DRY_RUN=0
LIST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l)     LIST=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        --name)        NAME="${2:-}"; shift ;;
        --name=*)      NAME="${1#--name=}" ;;
        --revision)    REVISION="${2:-}"; shift ;;
        --revision=*)  REVISION="${1#--revision=}" ;;
        -h|--help)     sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)            echo "Unknown option: $1 (try --help)"; exit 2 ;;
        *)
            if [ -n "${REPO}" ]; then
                echo "ERROR: more than one repo given ('${REPO}' and '$1')."
                echo "This takes one model at a time. Run it again for the next."
                exit 2
            fi
            REPO="$1"
            ;;
    esac
    shift
done

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

# ── --list ───────────────────────────────────────────────────────────────────
if [ "${LIST}" -eq 1 ]; then
    echo "Vault: ${ARCHIVE_DIR}"
    if [ ! -d "${ARCHIVE_DIR}" ] || [ -z "$(ls -A "${ARCHIVE_DIR}" 2>/dev/null)" ]; then
        echo "  (empty)"
        exit 0
    fi
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
    # Total and headroom, because the only decision this listing supports is
    # what to keep, and neither number is guessable from the per-entry sizes.
    echo ""
    printf '  TOTAL: %s in the vault\n' \
        "$(du -sh "${ARCHIVE_DIR}" 2>/dev/null | awk '{print $1}')"
    avail="$(df -Pk "${ARCHIVE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 * 1024}')"
    [ -n "${avail}" ] && [ "${avail}" -gt 0 ] 2>/dev/null &&
        printf '  FREE:  %s on that filesystem\n' "$(human "${avail}")"
    echo ""
    echo "Nothing here is ever deleted automatically. To reclaim space:"
    echo "  sudo rm -rf ${ARCHIVE_DIR}/<name>"
    exit 0
fi

if [ -z "${REPO}" ]; then
    echo "ERROR: no model given."
    echo "  bash scripts/vault_add.sh <hf-repo> [--name <dir>] [--revision <ref>]"
    echo "  bash scripts/vault_add.sh --list"
    exit 2
fi

case "${NAME}" in
    "") ;;
    */*|.|..) echo "ERROR: --name must be a plain directory name, got '${NAME}'."; exit 2 ;;
esac

if ! printf '%s' "${REPO}" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
    echo "ERROR: '${REPO}' does not look like a HuggingFace repo id."
    echo "Expected <org>/<model>, e.g. unsloth/Qwen3.8-27B-NVFP4."
    exit 2
fi

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

# Empty on any failure. Empty means "unknown", never "changed" — same rule as 02.
resolve_upstream_sha() {
    python3 - "$1" "${2:-}" <<'PYEOF' 2>/dev/null || echo ""
import json, os, sys, urllib.request
repo, rev = sys.argv[1], (sys.argv[2] or "main")
# Authenticated when a token exists: a gated repo often exposes no metadata at
# all unauthenticated, and an unresolvable SHA looks identical to a dead repo.
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

# Total size in bytes from the repo's file listing. 0 when unknown — the disk
# check is skipped rather than guessed at.
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

echo "========================================================"
echo " vault_add — ${REPO}"
echo "========================================================"
echo "  vault: ${ARCHIVE_DIR}"
echo ""

# ── Resolve what we are actually being asked for ─────────────────────────────
TARGET_SHA=""
if printf '%s' "${REVISION}" | grep -qE '^[0-9a-f]{40}$'; then
    TARGET_SHA="${REVISION}"
else
    TARGET_SHA="$(resolve_upstream_sha "${REPO}" "${REVISION}")"
fi

if [ -z "${TARGET_SHA}" ]; then
    echo "  Could not resolve ${REPO}${REVISION:+ @ ${REVISION}} on HuggingFace."
    echo "  It may be gated, private, renamed, deleted, or simply unreachable"
    echo "  from here. Nothing was downloaded."
    echo ""
    echo "  If you already have these weights, check the vault — that is what it"
    echo "  is for:"
    echo "    bash scripts/vault_add.sh --list"
    exit 1
fi
echo "  resolved commit: ${TARGET_SHA}"

# ── Do we already have this exact commit anywhere? ───────────────────────────
# Matched on repo + SHA recorded inside each entry, the same way 02 does it,
# so "already have it" means the same thing in both scripts.
for d in "${ARCHIVE_DIR}"/*/ "${MODELS_DIR}"/*/; do
    d="${d%/}"
    [ -d "${d}" ] || continue
    [ "$(revision_field "${d}" repo)" = "${REPO}" ] || continue
    [ "$(revision_field "${d}" resolved_sha)" = "${TARGET_SHA}" ] || continue
    echo ""
    echo "  Already on this box — nothing to download:"
    echo "    ${d}  ($(du -sh "${d}" 2>/dev/null | awk '{print $1}'))"
    echo "    saved: $(revision_field "${d}" downloaded)"
    case "${d}" in
        "${MODELS_DIR}"/*) echo "    (this one is live in ${MODELS_DIR})" ;;
    esac
    exit 0
done

# ── Where it will land ───────────────────────────────────────────────────────
# Org-qualified by default: two orgs publish models under the same name, and the
# directory name is cosmetic anyway — 02 matches on the recorded repo, and
# renames the directory to models.yml's local_path when it puts it into service.
if [ -z "${NAME}" ]; then
    NAME="${REPO%%/*}__${REPO##*/}"
fi
DEST="${ARCHIVE_DIR}/${NAME}"
if [ -e "${DEST}" ]; then
    # Occupied by something that is NOT this commit (the exact-match check above
    # already returned). Suffix rather than overwrite — same convention as 02's
    # keep_in_vault, and consistent with never destroying anything.
    DEST="${ARCHIVE_DIR}/${NAME}@${TARGET_SHA:0:12}"
    n=2
    while [ -e "${DEST}" ]; do
        DEST="${ARCHIVE_DIR}/${NAME}@${TARGET_SHA:0:12}-${n}"
        n=$(( n + 1 ))
    done
    echo "  ${ARCHIVE_DIR}/${NAME} is taken by another revision — using $(basename "${DEST}")"
fi
echo "  destination:     ${DEST}"

# ── Preflight ────────────────────────────────────────────────────────────────
sudo mkdir -p "${ARCHIVE_DIR}" || exit 1

# Same-filesystem check. 02 puts a vaulted model into service with a rename and
# refuses to cross devices, so a vault on another disk is a download that can
# never be used. Failing here costs a second; failing there costs the download.
if [ -d "${MODELS_DIR}" ]; then
    a_dev="$(stat -c %d "${ARCHIVE_DIR}" 2>/dev/null || echo x)"
    m_dev="$(stat -c %d "${MODELS_DIR}" 2>/dev/null || echo y)"
    if [ "${a_dev}" != "${m_dev}" ]; then
        echo ""
        echo "  ERROR: ${ARCHIVE_DIR} and ${MODELS_DIR} are on different filesystems."
        echo "  02 puts a vaulted model into service by renaming it, and refuses to"
        echo "  cross devices — anything downloaded here could never be used."
        echo "  Point ARCHIVE_DIR at the same disk as ${MODELS_DIR}."
        exit 1
    fi
fi

SIZE="$(resolve_repo_size "${REPO}" "${TARGET_SHA}")"
echo "  download size:   $(human "${SIZE}")"

AVAIL="$(df -Pk "${ARCHIVE_DIR}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 * 1024}')"
if [ -n "${AVAIL}" ]; then
    echo "  free on disk:    $(human "${AVAIL}")"
    if [ "${SIZE}" -gt 0 ] && [ "${AVAIL}" -lt $(( SIZE + SIZE / 10 )) ]; then
        echo ""
        echo "  ERROR: not enough free space, counting a 10% margin."
        echo "  See what the vault is holding and free some yourself:"
        echo "    bash scripts/vault_add.sh --list"
        exit 1
    fi
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    echo ""
    echo "  Dry run — nothing downloaded."
    exit 0
fi

# Said before the download, not after it fails. An unset token is the cause of
# both failure modes worth predicting here: a gated repo refuses outright, and
# an unauthenticated pull is rate-limited — which is felt across a 20GB file.
if [ -z "${HF_TOKEN}" ]; then
    echo ""
    echo "  NOTE: HF_TOKEN is not set, so this downloads unauthenticated."
    echo "    - gated repos ('requires approval') will REFUSE, not slow down"
    echo "    - throughput is rate-limited, which shows on 20GB files"
    echo "  Set it once in .env and every script here picks it up:"
    echo "    HF_TOKEN=hf_...   (huggingface.co/settings/tokens)"
fi

if [ -t 0 ] && [ -t 1 ]; then
    echo ""
    echo "  This downloads into the vault. It does not touch ${MODELS_DIR},"
    echo "  models.yml, or anything that is running."
    ans=""
    ask "  Type y to start, anything else to stop: " ans || ans="y"
    case "${ans}" in
        y|Y|yes|Yes|YES) ;;
        *) echo "  Stopped. Nothing downloaded."; exit 0 ;;
    esac
fi

# ── Download ─────────────────────────────────────────────────────────────────
require_hf
sudo mkdir -p "${STAGING_DIR}" || exit 1
sudo chown "$(id -u):$(id -g)" "${STAGING_DIR}" || exit 1

STAGE="${STAGING_DIR}/${NAME}"
mkdir -p "${STAGE}" || exit 1

# Staged, then renamed in. An interrupted pull must never look complete: 02's
# reuse path only checks that a directory is non-empty, so a half-downloaded
# tree sitting directly in the vault would be offered as a working model.
echo ""
echo "  Downloading into ${STAGE}"
if ! hf download "${REPO}" --local-dir "${STAGE}" \
        ${REVISION:+--revision "${REVISION}"}; then
    echo ""
    echo "  FAILED. The partial download is kept at:"
    echo "    ${STAGE}"
    echo "  It is NOT in the vault, so 02 will not see or offer it."
    echo ""
    # "Re-run to resume" is wrong advice for the most common failure. A gated
    # repo refuses every attempt identically until access is granted, so saying
    # "resume" sends the operator round a loop that cannot terminate.
    if [ -z "${HF_TOKEN}" ]; then
        echo "  HF_TOKEN IS NOT SET, and that is the first thing to rule out."
        echo "  If the error above says access denied / requires approval, this"
        echo "  repo is gated and re-running changes nothing. Two steps:"
        echo "    1. Open https://huggingface.co/${REPO} and request access"
        echo "    2. Put a token in .env:  HF_TOKEN=hf_..."
        echo "  Then run this command again."
    else
        echo "  If the error says access denied / requires approval, the repo is"
        echo "  gated: open https://huggingface.co/${REPO}, request access, and"
        echo "  make sure .env's HF_TOKEN belongs to the approved account."
    fi
    echo "  For an interrupted transfer, re-running resumes where it stopped."
    exit 1
fi

# The contract with 02. Without these four keys the directory is findable only
# by name, never by commit — which is the bug that made the drafter invisible.
printf 'repo=%s\nrevision=%s\nresolved_sha=%s\ndownloaded=%s\n' \
    "${REPO}" "${REVISION:-main}" "${TARGET_SHA}" "$(date -Iseconds)" \
    > "${STAGE}/DOWNLOADED_REVISION.txt"

sudo mv "${STAGE}" "${DEST}" || exit 1
rmdir "${STAGING_DIR}" 2>/dev/null || true

echo ""
echo "========================================================"
echo "  IN THE VAULT: ${DEST}"
echo "    repo:     ${REPO}"
echo "    revision: ${TARGET_SHA}"
echo "    size:     $(du -sh "${DEST}" 2>/dev/null | awk '{print $1}')"
echo ""
echo "  These weights are now local. It no longer matters whether HuggingFace"
echo "  keeps, gates or removes this repo."
echo ""
echo "  To serve it: point the relevant section of config/models.yml at"
echo "    hf_repo: ${REPO}"
echo "  and run 02. It matches this entry on the recorded commit and offers it"
echo "  back without downloading — answer y."
echo ""
echo "  Pin the exact build by also setting:"
echo "    hf_revision: ${TARGET_SHA}"
echo "========================================================"
