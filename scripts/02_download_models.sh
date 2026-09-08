#!/usr/bin/env bash
# =============================================================================
# PHASE 2 — Download All Models
# =============================================================================
# Sources model HF repos + local paths from config/models.yml.
# To swap a model: edit config/models.yml, re-run this script. Idempotent.
#
# THIS SCRIPT NEVER DELETES MODEL WEIGHTS. There is no code path that does, and
# no flag or prompt answer that reaches one. A model is either serving, under
# /opt/models, or set aside in the vault at ${ARCHIVE_DIR}. Freeing space is
# manual: sudo rm -rf ${ARCHIVE_DIR}/<name>. Do not add a delete path here.
#
# The vault is searched BY COMMIT, not by directory name: each entry records its
# resolved SHA in DOWNLOADED_REVISION.txt, and that is what is matched. On a hit
# the user chooses reuse (a rename) or a fresh download. A different commit is
# offered too, labelled as such — an upstream that has been deleted, gated or
# blocked still leaves something serveable, which is the point of the vault.
#
#   REUSE_FROM_VAULT=ask|yes|no   default: ask if interactive; non-interactive
#                                 reuses only on an exact commit match
#   CHECK_REVISION=ask|yes|no     compare a resident model against the pinned
#                                 SHA. default: ask if interactive, else no
#   ARCHIVE_DIR=<path>            default /opt/model-archive. MUST be the same
#                                 filesystem as /opt/models — moves are renames
#
# Rationale, and the bugs that shaped this file: docs/LESSONS.md #21.
# User-facing behaviour: README "Downloaded once, kept forever".
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

ARCHIVE_DIR="${ARCHIVE_DIR:-/opt/model-archive}"
CHECK_REVISION="${CHECK_REVISION:-}"

# RESTORE_ARCHIVED_MODEL was the old spelling; honour it so an existing .env
# keeps working, but REUSE_FROM_VAULT is the name now.
REUSE_FROM_VAULT="${REUSE_FROM_VAULT:-${RESTORE_ARCHIVED_MODEL:-}}"

# Deletion was removed outright. Say so rather than ignoring it in silence — a
# box carrying ARCHIVE_OLD_MODEL=no in .env has been deleting weights on every
# run, and its owner should learn that stopped.
if [ -n "${ARCHIVE_OLD_MODEL:-}" ]; then
    echo "  NOTE: ARCHIVE_OLD_MODEL=${ARCHIVE_OLD_MODEL} is set, and no longer does anything."
    echo "        This script cannot delete model weights any more. Pruned models"
    echo "        are moved to ${ARCHIVE_DIR} and kept. Remove the line from .env."
    echo ""
fi

# Ensure user-local Python CLI tools are available (hf, aider, etc.)
export PATH="$HOME/.local/bin:$PATH"

# huggingface-cli was removed in huggingface_hub v1.0; `hf` replaces it.
# Checked at point of use, not startup: pruning, skipping and restoring need no
# downloader, and an early exit made restore-from-archive unreachable.
require_hf() {
    command -v hf >/dev/null 2>&1 && return 0
    echo ""
    echo "  ERROR: hf CLI not found in PATH, and this step needs to download."
    echo "  PATH=${PATH}"
    echo ""
    echo "  This box is PEP 668 externally-managed, so --user fails outright."
    echo "  01_system_prep.sh installs huggingface_hub with --break-system-packages;"
    echo "  match it:"
    echo "    pip install -U huggingface_hub --break-system-packages"
    echo ""
    echo "  If huggingface_hub is already installed, it is likely <1.0, which ships"
    echo "  huggingface-cli and not hf. Check with:"
    echo "    python3 -c 'import huggingface_hub as h; print(h.__version__)'"
    echo "  The upgrade above is the fix either way."
    exit 1
}

# hf_transfer was removed in v1.0; HF_HUB_ENABLE_HF_TRANSFER is now a silent no-op.
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_TOKEN="${HF_TOKEN:-}"

# Helper: read a value from models.yml without requiring yq
# Usage: get_model_field <top_key> <field>
get_model_field() {
    python3 -c "
import yaml, sys
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
val = cfg.get('$1', {}).get('$2', '')
# A key present but empty in YAML parses as None, which would print the literal
# string 'None' and get treated as a real value by every caller below.
print(val if val is not None else '')
"
}

# Read an answer from the terminal, not stdin, discarding anything buffered: a
# pasted multi-line block otherwise answers the prompt with its own next line.
# Returns 1 when there is no terminal to ask. LESSONS.md #21.
ask() {
    local __var="$2" reply=""
    # Opening /dev/tty is the real test; -r can pass where the open fails.
    ( : < /dev/tty ) 2>/dev/null || return 1
    while read -r -t 0 2>/dev/null; do read -r _ 2>/dev/null || break; done
    # Prompt to the terminal, not stdout, or piping the script hides the question.
    printf '%s' "$1" > /dev/tty
    read -r reply < /dev/tty || return 1
    printf -v "${__var}" '%s' "${reply}"
}

# Read one field out of a vault entry's (or model dir's) revision record.
# Empty when the file or the field is absent — entries predating that record
# exist, and "unknown" is a legitimate answer everywhere it is consumed.
revision_field() {
    local dir="$1" key="$2"
    [ -f "${dir}/DOWNLOADED_REVISION.txt" ] || return 0
    sed -n "s/^${key}=//p" "${dir}/DOWNLOADED_REVISION.txt" | head -1
}

# Move a model dir into the vault. There is no delete path and no prompt: this
# only ever relocates bytes that are staying on the disk either way.
keep_in_vault() {
    local dir="$1"
    local name; name="$(basename "${dir}")"
    local size; size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"

    sudo mkdir -p "${ARCHIVE_DIR}"

    # Reject cross-device moves — an rsync+delete would silently balloon
    # duration and disk use for ~35GB, better to fail fast.
    local src_dev dst_dev
    src_dev="$(stat -c %d "${dir}" 2>/dev/null || echo x)"
    dst_dev="$(stat -c %d "${ARCHIVE_DIR}" 2>/dev/null || echo y)"
    if [ "${src_dev}" != "${dst_dev}" ]; then
        echo "  ERROR: ${dir} and ${ARCHIVE_DIR} are on different filesystems."
        echo "  A move across devices is a 35GB copy wearing a rename's clothes."
        echo "  Point ARCHIVE_DIR at a location on the same disk as /opt/models."
        exit 1
    fi

    local sha; sha="$(revision_field "${dir}" resolved_sha)"
    local dest="${ARCHIVE_DIR}/${name}"

    if [ -e "${dest}" ]; then
        local existing_sha; existing_sha="$(revision_field "${dest}" resolved_sha)"

        if [ -n "${sha}" ] && [ "${sha}" = "${existing_sha}" ]; then
            # Same weights twice. Both kept — "it is only a duplicate" is the
            # reasoning that eventually deletes the wrong thing.
            echo ""
            echo "  ${name}: the vault already holds this exact revision."
            echo "    already kept: ${dest}"
            echo "    duplicate:    ${dir}  (${size})"
            echo "    revision:     ${sha}"
            echo "    Nothing deleted. To reclaim ${size}, you remove it yourself:"
            echo "      sudo rm -rf ${dir}"
            return
        fi

        # A different (or unrecorded) revision under a name already taken.
        # Suffix rather than overwrite, so both stay reachable.
        local suffix="${sha:0:12}"
        [ -n "${suffix}" ] || suffix="unknown-$(date +%Y%m%d%H%M%S)"
        dest="${ARCHIVE_DIR}/${name}@${suffix}"
        local n=2
        while [ -e "${dest}" ]; do
            dest="${ARCHIVE_DIR}/${name}@${suffix}-${n}"
            n=$(( n + 1 ))
        done
    fi

    echo "  KEEP: ${dir} → ${dest}  (${size})"
    sudo mv "${dir}" "${dest}"
}

# Every vault entry holding weights for a given HF repo.
# Prints, one per line:  <dir> <TAB> <resolved_sha> <TAB> <downloaded_at>
#
# Matched on the repo recorded INSIDE each entry, not on the directory name —
# the name is whatever local_path was at the time. Entries with no revision
# record predate it: matched by directory name, reported unknown, never skipped.
vault_entries_for() {
    local want_repo="$1" want_name="$2"
    [ -d "${ARCHIVE_DIR}" ] || return 0

    local d
    for d in "${ARCHIVE_DIR}"/*/; do
        d="${d%/}"
        [ -d "${d}" ] || continue
        [ -n "$(ls -A "${d}" 2>/dev/null)" ] || continue

        local repo; repo="$(revision_field "${d}" repo)"
        if [ -z "${repo}" ]; then
            # Legacy entry. The directory name is the only identity it has, and
            # keep_in_vault may have suffixed it with @<sha>.
            local base="${d##*/}"
            [ "${base%%@*}" = "${want_name}" ] || continue
        elif [ "${repo}" != "${want_repo}" ]; then
            continue
        fi

        printf '%s\t%s\t%s\n' "${d}" \
            "$(revision_field "${d}" resolved_sha)" \
            "$(revision_field "${d}" downloaded)"
    done
}

# Look in the vault before downloading. Returns 0 if ${dest} now holds the
# model (nothing left to download), 1 to fall through and pull from HuggingFace.
# Neither answer destroys anything: declining leaves the saved copy in place.
reuse_from_vault() {
    local dest="$1" label="$2" hf_repo="$3" target_sha="$4"
    local name; name="$(basename "${dest}")"

    local entries; entries="$(vault_entries_for "${hf_repo}" "${name}")"
    [ -n "${entries}" ] || return 1

    # Exact commit wins. Failing that, the newest copy of this repo — labelled
    # as a different build, never passed off as what was asked for.
    local src="" src_sha="" src_when="" exact=0
    if [ -n "${target_sha}" ]; then
        local d s w
        while IFS=$'\t' read -r d s w; do
            [ "${s}" = "${target_sha}" ] || continue
            src="${d}"; src_sha="${s}"; src_when="${w}"; exact=1
            break
        done <<< "${entries}"
    fi
    if [ -z "${src}" ]; then
        local newest; newest="$(printf '%s\n' "${entries}" | sort -t"$(printf '\t')" -k3,3r | head -1)"
        src="$(printf '%s' "${newest}" | cut -f1)"
        src_sha="$(printf '%s' "${newest}" | cut -f2)"
        src_when="$(printf '%s' "${newest}" | cut -f3)"
    fi

    local size; size="$(du -sh "${src}" 2>/dev/null | awk '{print $1}')"
    local count; count="$(printf '%s\n' "${entries}" | grep -c . || true)"

    local decision
    case "${REUSE_FROM_VAULT}" in
        yes|y|1|true|TRUE|True)   decision=reuse ;;
        no|n|0|false|FALSE|False) decision=download ;;
        *)
            if [ -t 0 ] && [ -t 1 ]; then
                echo ""
                if [ "${exact}" -eq 1 ]; then
                    echo "  ${label} is not in /opt/models — but these EXACT weights are"
                    echo "  already on this box. Same commit config/models.yml asks for."
                else
                    echo "  ${label} is not in /opt/models. This box has weights for"
                    echo "  ${hf_repo}, but NOT at the commit config/models.yml asks for:"
                    echo "    on hand:   ${src_sha:-unrecorded}"
                    echo "    asked for: ${target_sha:-unknown — could not reach HuggingFace}"
                fi
                echo ""
                echo "    ${src}  (${size})"
                echo "    revision: ${src_sha:-no record of which version this is}"
                [ -n "${src_when}" ] && echo "    saved:    ${src_when}"
                [ "${count}" -gt 1 ] && echo "    (${count} saved copies of this model — see ${ARCHIVE_DIR})"
                echo ""
                echo "    y  = USE WHAT IS ALREADY HERE. A rename. Downloads nothing,"
                echo "         and works with HuggingFace unreachable or the repo gone."
                echo "    n  = DOWNLOAD A FRESH COPY from HuggingFace instead."
                echo "         The saved copy is kept either way — nothing is deleted."
                echo ""
                local ans=""
                if [ "${exact}" -eq 1 ]; then
                    ask "  Type y or n and press Enter (Enter = use what is here): " ans || ans=""
                    case "${ans}" in
                        n|N|no|No|NO) decision=download ;;
                        *)            decision=reuse ;;
                    esac
                else
                    # Not what was pinned, so no silent default: Enter downloads.
                    ask "  Type y to use the saved copy, or Enter to download what was asked for: " ans || ans=""
                    case "${ans}" in
                        y|Y|yes|Yes|YES) decision=reuse ;;
                        *)               decision=download ;;
                    esac
                fi
            elif [ "${exact}" -eq 1 ]; then
                decision=reuse
            else
                decision=download
            fi
            ;;
    esac

    if [ "${decision}" = "download" ]; then
        echo "  Keeping the saved copy at ${src}; downloading fresh instead."
        return 1
    fi

    # Cross-device guard: a rename that is secretly a 25GB copy fails fast.
    local src_dev dst_dev
    src_dev="$(stat -c %d "${src}" 2>/dev/null || echo x)"
    dst_dev="$(stat -c %d "$(dirname "${dest}")" 2>/dev/null || echo y)"
    if [ "${src_dev}" != "${dst_dev}" ]; then
        echo "  ERROR: ${src} and $(dirname "${dest}") are on different filesystems."
        echo "  Point ARCHIVE_DIR at a location on the same disk as /opt/models."
        exit 1
    fi

    sudo mkdir -p "$(dirname "${dest}")"
    echo "  REUSE: ${src} → ${dest}"
    sudo mv "${src}" "${dest}"
    if [ "${exact}" -eq 1 ]; then
        echo "  OK ${label} (exact revision reused from the vault — no download)"
    else
        echo "  OK ${label} (reused from the vault at revision ${src_sha:-unknown},"
        echo "     which is NOT what models.yml pins — no download)"
    fi
    return 0
}

# Prints empty on any failure (offline, rate-limited, gated). Callers must treat
# empty as "unknown", never "changed" — otherwise a dropped network proposes
# replacing good weights.
resolve_upstream_sha() {
    python3 - "$1" "${2:-}" <<'PYEOF' 2>/dev/null || echo ""
import json, sys, urllib.request
repo, rev = sys.argv[1], (sys.argv[2] or "main")
try:
    with urllib.request.urlopen(
            f"https://huggingface.co/api/models/{repo}/revision/{rev}", timeout=15) as r:
        print(json.load(r).get("sha", ""))
except Exception:
    print("")
PYEOF
}

# Returns 0 to keep what is on disk, 1 to fall through and download.
# Detects that hashes DIFFER, not that the new one is better — upstream
# re-uploads have shipped broken — so it asks, and vaults the old copy first.
check_revision_drift() {
    local local_path="$1" hf_repo="$2" hf_revision="$3" label="$4"

    case "${CHECK_REVISION}" in
        no|n|0|false|FALSE|False) return 0 ;;
        yes|y|1|true|TRUE|True)   ;;
        *) [ -t 0 ] && [ -t 1 ] || return 0 ;;   # never prompt non-interactively
    esac

    local resident=""
    if [ -f "${local_path}/DOWNLOADED_REVISION.txt" ]; then
        resident=$(sed -n 's/^resolved_sha=//p' "${local_path}/DOWNLOADED_REVISION.txt" | head -1)
    fi
    if [ -z "${resident}" ]; then
        echo "    (no recorded SHA for ${label} — cannot compare revisions)"
        return 0
    fi

    # A 40-hex hf_revision is already the answer; anything else is a ref name.
    local target=""
    if printf '%s' "${hf_revision}" | grep -qE '^[0-9a-f]{40}$'; then
        target="${hf_revision}"
    else
        target=$(resolve_upstream_sha "${hf_repo}" "${hf_revision}")
    fi

    [ -z "${target}" ] && return 0                 # unknown: leave it alone
    [ "${target}" = "${resident}" ] && return 0    # match: nothing to do

    echo ""
    echo "  ${label} on disk is a different revision than models.yml asks for:"
    echo "    on disk:     ${resident}"
    if [ "${hf_revision}" = "${target}" ]; then
        echo "    configured:  ${target}"
    else
        echo "    configured:  ${target}  (${hf_revision:-latest on main})"
    fi
    echo "  Different does not mean better — re-uploads have shipped broken before."
    echo ""
    echo "    y  = SWITCH to the configured version and download it."
    echo "         The copy you have now is saved first, so you can go back."
    echo "    n  = KEEP what you have. Nothing is downloaded or changed."
    echo ""
    local ans=""
    ask "  Type y or n and press Enter (or just press Enter to keep what you have): " ans || ans=""
    case "${ans}" in
        y|Y|yes|Yes|YES) ;;
        *) echo "  Keeping the copy on disk."; return 0 ;;
    esac

    # Before moving it aside, not after: failing here otherwise strands the
    # working copy in the vault with /opt/models empty.
    require_hf
    keep_in_vault "${local_path}"
    return 1
}

download_model() {
    local label="$1"
    local top_key="$2"

    local hf_repo local_path hf_revision
    hf_repo=$(get_model_field "${top_key}" hf_repo)
    local_path=$(get_model_field "${top_key}" local_path)

    # Optional pin. Blank = latest on main at pull time. Set it only to
    # reproduce a known-good state or dodge a bad upstream push.
    hf_revision=$(get_model_field "${top_key}" hf_revision)

    if [ -z "${hf_repo}" ] || [ -z "${local_path}" ]; then
        echo "  SKIP ${label}: not configured in models.yml"
        return
    fi

    if [ -d "${local_path}" ] && [ "$(ls -A "${local_path}" 2>/dev/null)" ]; then
        if check_revision_drift "${local_path}" "${hf_repo}" "${hf_revision}" "${label}"; then
            echo "  SKIP ${label}: already exists at ${local_path}"
            return
        fi
        # Drift accepted: the old copy is in the vault, fall through and download.
    fi

    # What commit is models.yml asking for? A 40-hex pin already is one; anything
    # else resolves upstream. EMPTY IS NORMAL, not an error — HuggingFace being
    # unreachable or the repo gone is the case the vault exists for. Resolved
    # here, not at startup, so a fully resident stack makes no network calls.
    local target_sha=""
    if printf '%s' "${hf_revision}" | grep -qE '^[0-9a-f]{40}$'; then
        target_sha="${hf_revision}"
    else
        target_sha=$(resolve_upstream_sha "${hf_repo}" "${hf_revision}")
    fi

    # Already downloaded once? A rename beats a re-pull, and works whether or
    # not HuggingFace will still serve it.
    if reuse_from_vault "${local_path}" "${label}" "${hf_repo}" "${target_sha}"; then
        return
    fi

    require_hf
    echo "  Downloading ${label} → ${local_path}"
    echo "    HF repo: ${hf_repo}"
    echo "    Revision: ${hf_revision:-<latest on main>}"
    mkdir -p "${local_path}"
    hf download "${hf_repo}" --local-dir "${local_path}" \
        ${hf_revision:+--revision "${hf_revision}"}

    # Record which commit we got: "latest at pull time" is not a state you can
    # return to, and the vault matches on this SHA. `hf download` leaves the
    # resolved ref in cache metadata; fall back to the API when --local-dir
    # has stripped it.
    local sha=""
    if [ -f "${local_path}/.cache/huggingface/.gitattributes.metadata" ]; then
        sha=$(head -1 "${local_path}/.cache/huggingface/.gitattributes.metadata" 2>/dev/null || echo "")
    fi
    if [ -z "${sha}" ]; then
        sha=$(resolve_upstream_sha "${hf_repo}" "${hf_revision}")
    fi

    if [ -n "${sha}" ]; then
        printf 'repo=%s\nrevision=%s\nresolved_sha=%s\ndownloaded=%s\n' \
            "${hf_repo}" "${hf_revision:-main}" "${sha}" "$(date -Iseconds)" \
            > "${local_path}/DOWNLOADED_REVISION.txt"
        echo "    Resolved SHA: ${sha}"
        echo "    Recorded in ${local_path}/DOWNLOADED_REVISION.txt"
    else
        echo "    WARN: could not resolve the commit SHA — this download is"
        echo "          not reproducible. Pin hf_revision in models.yml if you"
        echo "          need to come back to exactly these weights."
    fi

    echo "  OK ${label}"
}

echo "========================================================"
echo " spark-sovereign — Phase 2: Download Models"
echo "========================================================"
echo "  HF_XET_HIGH_PERFORMANCE=${HF_XET_HIGH_PERFORMANCE}"
echo ""

# ── Prune model directories no longer in models.yml ──────────────────────────
echo ">>> Checking for unused model directories in /opt/models..."
# EVERY field that can name a resident model dir, across ALL sections. A fixed
# key list reading only local_path missed brain.speculative_draft_model and
# pruned the drafter every run. Err toward keeping. LESSONS.md #21.
ACTIVE_PATHS=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
FIELDS = ('local_path', 'speculative_draft_model', 'speculative_draft_model_path')
for section in cfg.values():
    if not isinstance(section, dict):
        continue
    for field in FIELDS:
        p = section.get(field)
        if p:
            print(p)
")

if [ -d /opt/models ]; then
    for dir in /opt/models/*/; do
        dir="${dir%/}"
        if ! echo "${ACTIVE_PATHS}" | grep -qxF "${dir}"; then
            keep_in_vault "${dir}"
        fi
    done
fi
echo ""

download_model "Brain" brain
download_model "ASR (Nemotron Speech)"           asr
download_model "TTS (Magpie TTS)"                tts

# -----------------------------------------------------------------------------
# Speculative decoding drafter — separate checkpoint, not part of Brain.
# Why it exists and what it bought: docs/LESSONS.md #20.
# -----------------------------------------------------------------------------
# THE RENAME BELOW IS REQUIRED, NOT COSMETIC. DO NOT REMOVE IT. The upload
# declares architecture "DSparkDraftModel", which vLLM dispatches to its
# DeepSeek-V4 implementation, which then dies on a DeepSeek-only config field:
#
#   AttributeError: 'Qwen3Config' object has no attribute 'hc_mult'
#
# "Qwen3DSparkModel" is the Qwen3 path registered in the image. It is patched
# here, in the script that creates the directory, because it lives in the model
# directory and so cannot be committed to the repo.
DRAFT_PATH=$(get_model_field brain speculative_draft_model)
DRAFT_REPO=$(get_model_field brain speculative_draft_repo)
if [ -n "${DRAFT_REPO}" ] && [ -n "${DRAFT_PATH}" ]; then
    echo ""
    if [ -d "${DRAFT_PATH}" ] && [ "$(ls -A "${DRAFT_PATH}" 2>/dev/null)" ]; then
        echo "  SKIP Drafter: already exists at ${DRAFT_PATH}"
    elif reuse_from_vault "${DRAFT_PATH}" "Drafter" "${DRAFT_REPO}" \
            "$(resolve_upstream_sha "${DRAFT_REPO}" "")"; then
        :
    else
        require_hf
        echo "  Downloading Drafter → ${DRAFT_PATH}"
        echo "    HF repo: ${DRAFT_REPO}"
        mkdir -p "${DRAFT_PATH}"
        hf download "${DRAFT_REPO}" --local-dir "${DRAFT_PATH}"

        # vault_entries_for matches on the repo written here. Without this file
        # the drafter is findable only by directory name, never by commit.
        DRAFT_SHA="$(resolve_upstream_sha "${DRAFT_REPO}" "")"
        if [ -n "${DRAFT_SHA}" ]; then
            printf 'repo=%s\nrevision=%s\nresolved_sha=%s\ndownloaded=%s\n' \
                "${DRAFT_REPO}" "main" "${DRAFT_SHA}" "$(date -Iseconds)" \
                > "${DRAFT_PATH}/DOWNLOADED_REVISION.txt"
            echo "    Resolved SHA: ${DRAFT_SHA}"
        fi
    fi

    if [ -f "${DRAFT_PATH}/config.json" ]; then
        if grep -q '"DSparkDraftModel"' "${DRAFT_PATH}/config.json"; then
            sed -i 's/"DSparkDraftModel"/"Qwen3DSparkModel"/' "${DRAFT_PATH}/config.json"
            echo "    Renamed architecture DSparkDraftModel -> Qwen3DSparkModel (required)"
        fi
        if ! grep -q '"Qwen3DSparkModel"' "${DRAFT_PATH}/config.json"; then
            echo "    WARNING: drafter declares an unexpected architecture:"
            grep -A2 '"architectures"' "${DRAFT_PATH}/config.json" | sed 's/^/      /'
            echo "    Brain will fail to start with speculative_config set to dspark."
        fi
    fi
fi

echo ""
echo "All models downloaded."

# A pinned `truncation` in tokenizer.json silently caps prompt length while the
# server still advertises the full context window — no error, no warning.
echo ""
echo "Verifying Brain tokenizer has no hardcoded truncation..."
BRAIN_MODEL_PATH=$(get_model_field brain local_path)
if [ -n "${BRAIN_MODEL_PATH}" ] && [ -f "${BRAIN_MODEL_PATH}/tokenizer.json" ]; then
    python3 - "${BRAIN_MODEL_PATH}/tokenizer.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        trunc = json.load(f).get('truncation')
except Exception as e:
    print(f"  WARN: could not read tokenizer.json ({e}) — check manually")
    sys.exit(0)
if trunc:
    print(f"  *** WARNING: tokenizer.json pins truncation: {trunc}")
    print("  *** Prompts will be SILENTLY truncated at that length.")
    print("  *** Re-download the model — upstream published a fix for this.")
else:
    print("  OK: no truncation pinned (expected None).")
PYEOF
else
    echo "  SKIP: no tokenizer.json at ${BRAIN_MODEL_PATH:-<unset>}"
fi

echo ""
echo "Disk usage summary:"
# Reuses the prune keep-list, so the summary cannot disagree with it.
while IFS= read -r path; do
    [ -n "${path}" ] && [ -d "${path}" ] && du -sh "${path}" 2>/dev/null || true
done <<< "${ACTIVE_PATHS}"

if [ -d "${ARCHIVE_DIR}" ] && [ -n "$(ls -A "${ARCHIVE_DIR}" 2>/dev/null || true)" ]; then
    echo ""
    echo "Already downloaded and kept in ${ARCHIVE_DIR} — point models.yml at any"
    echo "of these and re-run this script; it offers them back without downloading,"
    echo "whether or not HuggingFace still has them:"
    for a in "${ARCHIVE_DIR}"/*/; do
        [ -d "${a}" ] || continue
        printf '  %s\n' "$(du -sh "${a%/}" 2>/dev/null || echo "     ?  ${a%/}")"
        rev="$(revision_field "${a%/}" resolved_sha)"
        repo="$(revision_field "${a%/}" repo)"
        [ -n "${repo}" ] && printf '      %s @ %s\n' "${repo}" "${rev:-unknown revision}"
    done
    echo ""
    echo "Nothing here is ever deleted by this script. To reclaim the space:"
    echo "  sudo rm -rf ${ARCHIVE_DIR}/<name>"
fi

echo ""
echo "Phase 2 complete. Proceed to: scripts/03_vllm_servers.sh"

