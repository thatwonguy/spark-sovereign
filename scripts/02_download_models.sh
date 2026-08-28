#!/usr/bin/env bash
# =============================================================================
# PHASE 2 — Download All Models
# =============================================================================
# Sources model HF repos + local paths from config/models.yml.
# To swap a model: edit config/models.yml, re-run this script.
# Idempotent — skips already-downloaded models, removes unused ones.
#
# Archive-on-prune:
#   Before deleting a pruned model dir, offers to move it to ${ARCHIVE_DIR}
#   (default /opt/model-archive) so a rollback does not require re-downloading
#   ~35GB from HuggingFace. Archive is single-slot: only ONE saved model at a
#   time. If a different model already occupies the slot, you are asked
#   whether to replace it. Env vars:
#     ARCHIVE_OLD_MODEL=ask|yes|no   default: ask if interactive, archive otherwise
#     ARCHIVE_DIR=<path>             default: /opt/model-archive
#   Deleting only ever happens on an explicit no — from the prompt or from
#   ARCHIVE_OLD_MODEL. With no terminal it archives rather than deletes, and any
#   delete that skipped the prompt prints the reason it was not asked.
#   NOTE: .env is sourced before these defaults, so ARCHIVE_OLD_MODEL=no there
#   silently arms deletion for every run.
#
# Restore-from-archive:
#   Checks ${ARCHIVE_DIR}/<name> before downloading and offers to move it back.
#     RESTORE_ARCHIVED_MODEL=ask|yes|no   default: ask if interactive, yes otherwise
#   Non-interactive defaults to yes (opposite of archive-on-prune) — nothing on
#   the boot path runs this script, and a silent 25GB re-pull is worse.
#
# Revision drift:
#   A model already on disk is compared against the SHA models.yml asks for,
#   and you are offered the swap. Detects different, never better.
#     CHECK_REVISION=ask|yes|no           default: ask if interactive, no otherwise
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

ARCHIVE_OLD_MODEL="${ARCHIVE_OLD_MODEL:-}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/opt/model-archive}"
RESTORE_ARCHIVED_MODEL="${RESTORE_ARCHIVED_MODEL:-}"
CHECK_REVISION="${CHECK_REVISION:-}"

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

# Read an answer from the terminal rather than stdin, and discard anything
# already buffered. A pasted multi-line command block leaves its remaining lines
# in the input queue, and a plain `read` consumes the next one as the answer —
# which silently answered destructive prompts with the following command.
# Returns 1 when there is no terminal to ask.
ask() {
    local __var="$2" reply=""
    while read -r -t 0 2>/dev/null; do read -r _ 2>/dev/null || break; done
    # -r /dev/tty can pass on a node that still fails to open, so the open is
    # the real test; the group swallows the redirection error when there is none.
    { read -r -p "$1" reply < /dev/tty; } 2>/dev/null || return 1
    printf -v "${__var}" '%s' "${reply}"
}

# Move a pruned model dir to the single-slot archive, or delete it.
# Interactive terminals get a Y/n prompt; non-interactive callers delete
# (preserving the pre-archive behavior for boot / watchdog / systemd).
archive_or_remove() {
    local dir="$1"
    local name; name="$(basename "${dir}")"
    local decision unasked=""

    case "${ARCHIVE_OLD_MODEL}" in
        yes|y|1|true|TRUE|True)  decision=archive ;;
        no|n|0|false|FALSE|False)
            decision=delete
            unasked="ARCHIVE_OLD_MODEL=${ARCHIVE_OLD_MODEL} (set in the environment or .env)"
            ;;
        *)
            if [ -t 0 ] && [ -t 1 ]; then
                local size; size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"
                echo ""
                echo "  About to prune: ${dir}  (${size})"
                echo "  Archive to ${ARCHIVE_DIR}/${name} so you can roll back without re-downloading?"
                # Only an explicit no deletes. Anything unrecognised takes the
                # capital-Y default, because the other branch is unrecoverable.
                local ans=""
                ask "  Archive? [Y/n] " ans || ans=""
                case "${ans}" in
                    n|N|no|No|NO) decision=delete ;;
                    *)            decision=archive ;;
                esac
            else
                # No terminal to ask, so do not destroy. Nothing on the boot
                # path runs this script, so there is no unattended caller whose
                # behaviour this protects — only disk, which is the cheap side.
                decision=archive
                echo "  No terminal to prompt — archiving ${name} rather than deleting."
            fi
            ;;
    esac

    if [ "${decision}" = "delete" ]; then
        local size; size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"
        echo "  REMOVE unused model: ${dir}  (${size})"
        [ -n "${unasked}" ] && echo "    deleted without asking, because ${unasked}"
        sudo rm -rf "${dir}"
        return
    fi

    sudo mkdir -p "${ARCHIVE_DIR}"
    local dest="${ARCHIVE_DIR}/${name}"

    if [ -e "${dest}" ]; then
        # Single-slot archive: something is already saved. Ask before overwriting.
        if [ -t 0 ] && [ -t 1 ]; then
            local existing_size; existing_size="$(du -sh "${dest}" 2>/dev/null | awk '{print $1}')"
            echo "  Archive slot already contains: ${dest}  (${existing_size})"
            echo "  Only one archived model is kept at a time."
            local ans=""
            ask "  Replace it? [y/N] " ans || ans=""
            case "${ans}" in
                y|Y|yes|Yes|YES)
                    sudo rm -rf "${dest}"
                    ;;
                *)
                    # Neither copy gets destroyed on an unclear answer: leave the
                    # pruned dir in /opt/models and re-offer it next run.
                    echo "  Archive slot occupied — leaving ${dir} in place."
                    return
                    ;;
            esac
        else
            echo "  ERROR: archive slot ${dest} already exists; refusing to overwrite non-interactively."
            echo "  Move it aside or re-run with ARCHIVE_OLD_MODEL=no."
            exit 1
        fi
    fi

    # Reject cross-device moves — an rsync+delete would silently balloon
    # duration and disk use for ~35GB, better to fail fast.
    local src_dev dst_dev
    src_dev="$(stat -c %d "${dir}" 2>/dev/null || echo x)"
    dst_dev="$(stat -c %d "${ARCHIVE_DIR}" 2>/dev/null || echo y)"
    if [ "${src_dev}" != "${dst_dev}" ]; then
        echo "  ERROR: ${dir} and ${ARCHIVE_DIR} are on different filesystems."
        echo "  Point ARCHIVE_DIR at a location on the same disk as /opt/models."
        exit 1
    fi

    echo "  ARCHIVE: ${dir} → ${dest}"
    sudo mv "${dir}" "${dest}"
}

# Inverse of archive_or_remove. Returns 0 if ${dest} now holds the model,
# 1 if nothing was archived or a fresh download was requested.
# Declining keeps the archived copy — it is the rollback if the new pull is bad.
restore_from_archive() {
    local dest="$1"
    local label="$2"
    local name; name="$(basename "${dest}")"
    local src="${ARCHIVE_DIR}/${name}"

    if [ ! -d "${src}" ] || [ -z "$(ls -A "${src}" 2>/dev/null)" ]; then
        return 1
    fi

    local decision
    case "${RESTORE_ARCHIVED_MODEL}" in
        yes|y|1|true|TRUE|True)   decision=restore ;;
        no|n|0|false|FALSE|False) decision=download ;;
        *)
            if [ -t 0 ] && [ -t 1 ]; then
                local size; size="$(du -sh "${src}" 2>/dev/null | awk '{print $1}')"
                echo ""
                echo "  ${label} is not in /opt/models, but an archived copy exists:"
                echo "    ${src}  (${size})"
                if [ -f "${src}/DOWNLOADED_REVISION.txt" ]; then
                    sed 's/^/      /' "${src}/DOWNLOADED_REVISION.txt"
                else
                    echo "      (no DOWNLOADED_REVISION.txt — provenance unrecorded)"
                fi
                echo "  Restoring is an instant rename. Re-downloading fetches whatever is"
                echo "  upstream now, which may not be what the archived copy holds."
                local ans=""
                ask "  Use the archived copy? [Y/n] " ans || ans=""
                case "${ans}" in
                    n|N|no|No|NO) decision=download ;;
                    *)            decision=restore ;;
                esac
            else
                decision=restore
            fi
            ;;
    esac

    if [ "${decision}" = "download" ]; then
        echo "  Keeping the archived copy at ${src}; downloading fresh instead."
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
    echo "  RESTORE: ${src} → ${dest}"
    sudo mv "${src}" "${dest}"
    echo "  OK ${label} (restored from archive — no download)"
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
# Detects that hashes differ, not that the new one is better — upstream
# re-uploads have shipped broken — so it always asks and always archives first.
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
    echo "  Different is not the same as better — upstream re-uploads have shipped"
    echo "  broken. Replacing archives the current copy first, so it stays available."
    local ans=""
    ask "  Replace with the configured revision? [y/N] " ans || ans=""
    case "${ans}" in
        y|Y|yes|Yes|YES) ;;
        *) echo "  Keeping the copy on disk."; return 0 ;;
    esac

    # Before archiving, not after: failing here otherwise strands the working
    # copy in the archive with /opt/models empty.
    require_hf
    ARCHIVE_OLD_MODEL=yes archive_or_remove "${local_path}"
    return 1
}

download_model() {
    local label="$1"
    local top_key="$2"

    local hf_repo local_path hf_revision
    hf_repo=$(get_model_field "${top_key}" hf_repo)
    local_path=$(get_model_field "${top_key}" local_path)

    # Optional pin. Blank (the normal case) means "latest on main at pull time",
    # which is what you want on a fresh drop. Set hf_revision only to reproduce
    # a known-good state or to dodge a bad upstream push.
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
        # Drift accepted: the old copy is archived, fall through and download.
    fi

    # An earlier prune may have parked it in the archive; a rename beats a re-pull.
    if restore_from_archive "${local_path}" "${label}"; then
        return
    fi

    require_hf
    echo "  Downloading ${label} → ${local_path}"
    echo "    HF repo: ${hf_repo}"
    echo "    Revision: ${hf_revision:-<latest on main>}"
    mkdir -p "${local_path}"
    hf download "${hf_repo}" --local-dir "${local_path}" \
        ${hf_revision:+--revision "${hf_revision}"}

    # Record which commit we actually got. Without this the running weights are
    # unattributable: "latest at pull time" is not a state you can return to,
    # and every measured number in docs/LESSONS.md is implicitly against a SHA
    # nobody wrote down. `hf download` leaves the resolved ref in the local
    # cache metadata; fall back to the API when --local-dir has stripped it.
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
# Every field that can name a resident model dir, across all sections. Reading
# only local_path of a fixed key list meant brain.speculative_draft_model was
# never seen, so the drafter was pruned on every run. Err toward keeping: a
# stale dir costs disk, a pruned live one costs a re-download and a dead server.
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
            archive_or_remove "${dir}"
        fi
    done
fi
echo ""

download_model "Brain" brain
download_model "ASR (Nemotron Speech)"           asr
download_model "TTS (Magpie TTS)"                tts

# -----------------------------------------------------------------------------
# Speculative decoding drafter — separate checkpoint, not part of Brain.
# -----------------------------------------------------------------------------
# Brain's own MTP heads ship inside its checkpoint and need nothing here. This
# is the external drafter that replaced them: measured 23.85 tok/s against MTP's
# 19.66 on the same prompt, output unchanged (docs/LESSONS.md #20).
#
# THE RENAME BELOW IS REQUIRED, NOT COSMETIC. The upload declares architecture
# "DSparkDraftModel", a generic name vLLM dispatches to its DeepSeek-V4
# implementation, which then dies reading a DeepSeek-only config field:
#
#   AttributeError: 'Qwen3Config' object has no attribute 'hc_mult'
#
# "Qwen3DSparkModel" is registered in the image and is the Qwen3 path. Renaming
# it here means a fresh install works; leaving it to a manual step means Brain
# fails to start with an error that names DeepSeek and points nowhere useful.
#
# This lives in the model directory rather than the repo, so it cannot be
# committed — which is exactly why it belongs in the script that creates that
# directory. It was found the hard way, after four failed launches.
DRAFT_PATH=$(get_model_field brain speculative_draft_model)
DRAFT_REPO=$(get_model_field brain speculative_draft_repo)
if [ -n "${DRAFT_REPO}" ] && [ -n "${DRAFT_PATH}" ]; then
    echo ""
    if [ -d "${DRAFT_PATH}" ] && [ "$(ls -A "${DRAFT_PATH}" 2>/dev/null)" ]; then
        echo "  SKIP Drafter: already exists at ${DRAFT_PATH}"
    elif restore_from_archive "${DRAFT_PATH}" "Drafter"; then
        :
    else
        require_hf
        echo "  Downloading Drafter → ${DRAFT_PATH}"
        echo "    HF repo: ${DRAFT_REPO}"
        mkdir -p "${DRAFT_PATH}"
        hf download "${DRAFT_REPO}" --local-dir "${DRAFT_PATH}"
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
# Reuses the prune keep-list rather than its own key list, so the summary cannot
# disagree with it — a hardcoded list here silently omitted the drafter.
while IFS= read -r path; do
    [ -n "${path}" ] && [ -d "${path}" ] && du -sh "${path}" 2>/dev/null || true
done <<< "${ACTIVE_PATHS}"

if [ -d "${ARCHIVE_DIR}" ] && [ -n "$(ls -A "${ARCHIVE_DIR}" 2>/dev/null || true)" ]; then
    echo ""
    echo "Archived (re-run this script after switching models.yml and it offers"
    echo "these back automatically; 'sudo mv ${ARCHIVE_DIR}/<name> /opt/models/' still works):"
    for a in "${ARCHIVE_DIR}"/*/; do
        [ -d "${a}" ] && du -sh "${a%/}" 2>/dev/null || true
    done
fi

echo ""
echo "Phase 2 complete. Proceed to: scripts/03_vllm_servers.sh"

