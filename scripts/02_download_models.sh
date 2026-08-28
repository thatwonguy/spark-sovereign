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
#     ARCHIVE_OLD_MODEL=ask|yes|no   default: ask if interactive, no otherwise
#     ARCHIVE_DIR=<path>             default: /opt/model-archive
#   Non-interactive callers (boot_sequence.sh, watchdog.sh, systemd) get the
#   old behavior — delete without prompting — so nothing changes on boot.
#
# Restore-from-archive (the other half of the above):
#   Archiving was one-way until 2026-08-27, so a rollback still re-downloaded
#   everything the archive was holding — the feature only half-worked. Before
#   downloading anything, this now checks ${ARCHIVE_DIR}/<name> and offers to
#   move it back instead. Same filesystem, so it is a rename, not a copy.
#   The prompt prints the archived copy's DOWNLOADED_REVISION.txt, because
#   "restore" and "re-download" are not equivalent: upstream may have moved
#   since it was archived, and only one of those two answers reproduces the
#   weights your benchmarks were measured against.
#     RESTORE_ARCHIVED_MODEL=ask|yes|no   default: ask if interactive, yes otherwise
#   Non-interactive default is `yes` — unlike archive-on-prune, which defaults
#   to the destructive answer to preserve boot behavior. Nothing on the boot
#   path runs this script, and silently re-pulling ~25GB is the worse surprise.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

ARCHIVE_OLD_MODEL="${ARCHIVE_OLD_MODEL:-}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/opt/model-archive}"
RESTORE_ARCHIVED_MODEL="${RESTORE_ARCHIVED_MODEL:-}"

# Ensure user-local Python CLI tools are available (hf, aider, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Optional early check so failures are obvious
# huggingface-cli was removed in huggingface_hub v1.0; `hf` replaces it.
if ! command -v hf >/dev/null 2>&1; then
    echo "ERROR: hf CLI not found in PATH"
    echo "PATH=${PATH}"
    echo "Try: python3 -m pip install --user -U huggingface_hub"
    exit 1
fi

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

# Move a pruned model dir to the single-slot archive, or delete it.
# Interactive terminals get a Y/n prompt; non-interactive callers delete
# (preserving the pre-archive behavior for boot / watchdog / systemd).
archive_or_remove() {
    local dir="$1"
    local name; name="$(basename "${dir}")"
    local decision

    case "${ARCHIVE_OLD_MODEL}" in
        yes|y|1|true|TRUE|True)  decision=archive ;;
        no|n|0|false|FALSE|False) decision=delete ;;
        *)
            if [ -t 0 ] && [ -t 1 ]; then
                local size; size="$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')"
                echo ""
                echo "  About to prune: ${dir}  (${size})"
                echo "  Archive to ${ARCHIVE_DIR}/${name} so you can roll back without re-downloading?"
                local ans
                read -r -p "  Archive? [Y/n] " ans
                case "${ans}" in
                    ""|y|Y|yes|Yes|YES) decision=archive ;;
                    *)                  decision=delete ;;
                esac
            else
                decision=delete
            fi
            ;;
    esac

    if [ "${decision}" = "delete" ]; then
        echo "  REMOVE unused model: ${dir}"
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
            local ans
            read -r -p "  Replace it? [y/N] " ans
            case "${ans}" in
                y|Y|yes|Yes|YES)
                    sudo rm -rf "${dest}"
                    ;;
                *)
                    echo "  Keeping existing archive; deleting pruned model instead: ${dir}"
                    sudo rm -rf "${dir}"
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

# The inverse of archive_or_remove: bring a model back instead of re-pulling it.
# Returns 0 if ${dest} now holds the model (caller should skip downloading),
# 1 if there was nothing archived or the operator asked for a fresh download.
#
# Declining does NOT discard the archived copy — you can always take it later,
# and having both a fresh download and a known-good archive is the state you
# want when a new upstream push turns out to be broken.
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
                local ans
                read -r -p "  Use the archived copy? [Y/n] " ans
                case "${ans}" in
                    ""|y|Y|yes|Yes|YES) decision=restore ;;
                    *)                  decision=download ;;
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

    # Same cross-device guard as archive_or_remove — a silent 25GB copy wearing
    # a rename's clothes is worth failing fast on.
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

download_model() {
    local label="$1"
    local top_key="$2"

    local hf_repo local_path
    hf_repo=$(get_model_field "${top_key}" hf_repo)
    local_path=$(get_model_field "${top_key}" local_path)

    if [ -z "${hf_repo}" ] || [ -z "${local_path}" ]; then
        echo "  SKIP ${label}: not configured in models.yml"
        return
    fi

    if [ -d "${local_path}" ] && [ "$(ls -A "${local_path}" 2>/dev/null)" ]; then
        echo "  SKIP ${label}: already exists at ${local_path}"
        return
    fi

    # Absent from /opt/models is not the same as absent from the box: an earlier
    # prune may have parked it in the archive, where a rename beats a re-pull.
    if restore_from_archive "${local_path}" "${label}"; then
        return
    fi

    # Optional pin. Blank (the normal case) means "latest on main at pull
    # time", which is what you want on a fresh drop: first uploads of new
    # models have shipped broken — see the tokenizer truncation check at the
    # bottom of this script. Set hf_revision only to reproduce a known-good
    # state or to dodge a bad upstream push.
    local hf_revision
    hf_revision=$(get_model_field "${top_key}" hf_revision)

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
        sha=$(python3 - "${hf_repo}" "${hf_revision}" <<'PYEOF' 2>/dev/null || echo ""
import json, sys, urllib.request
repo, rev = sys.argv[1], (sys.argv[2] or "main")
try:
    with urllib.request.urlopen(
            f"https://huggingface.co/api/models/{repo}/revision/{rev}", timeout=15) as r:
        print(json.load(r).get("sha", ""))
except Exception:
    print("")
PYEOF
)
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
ACTIVE_PATHS=$(python3 -c "
import yaml
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
keys = ['brain', 'subagent', 'asr', 'tts']
for k in keys:
    p = cfg.get(k, {}).get('local_path', '')
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
        # Restored — fall through to the architecture-rename check below, which
        # an archived copy still needs if it was archived before that fix.
        :
    else
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
for key in brain asr tts; do
    path=$(get_model_field "${key}" local_path)
    [ -n "${path}" ] && [ -d "${path}" ] && du -sh "${path}" 2>/dev/null || true
done

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

