#!/usr/bin/env bash
# =============================================================================
# spark-sovereign — one-command installer
# =============================================================================
#   curl -fsSL https://raw.githubusercontent.com/thatwonguy/spark-sovereign/main/install.sh | bash
#
# This file is deliberately small and boring. All it does is:
#   1. confirm you are on the Spark and not on your laptop
#   2. fetch the repo at the latest release tag
#   3. hand over to scripts/wizard.sh, which asks the questions
#
# It is meant to be read before it is run. The paranoid path is:
#   curl -fsSL <url> -o install.sh && less install.sh && bash install.sh
#
# Environment overrides (all optional):
#   SPARK_TAG=v5.4.1        pin a specific release instead of the latest
#   SPARK_DIR=~/somewhere   install somewhere other than ~/spark-sovereign
#   HF_TOKEN=hf_xxx         skip the token question in the wizard
# =============================================================================

set -uo pipefail

OWNER_REPO="thatwonguy/spark-sovereign"
REPO_URL="${SPARK_REPO_URL:-https://github.com/${OWNER_REPO}.git}"
DIR="${SPARK_DIR:-${HOME}/spark-sovereign}"
# Used only when the releases API is unreachable — offline-ish boxes and rate
# limited IPs still get a known-good tag rather than a moving main.
FALLBACK_TAG="v5.4.1"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; R=""; D=""; N=""
fi

die() {
    echo ""
    echo "${R}${B}  Stopped.${N}"
    echo ""
    printf '  %s\n' "$@"
    echo ""
    exit 1
}

echo ""
echo "${B}  spark-sovereign${N}  ${D}— your own private AI, on your own hardware${N}"
echo ""

# ── Are we even on the right machine? ────────────────────────────────────────
# By far the most common mistake: pasting this into the laptop terminal instead
# of into an SSH session on the Spark. Catch it here with the actual next steps,
# not with a confusing failure forty seconds later.
if [ "$(uname -s)" != "Linux" ]; then
    die "This installer runs ${B}on the DGX Spark itself${N}, over SSH — not on your laptop." \
        "You appear to be on: $(uname -s)" \
        "" \
        "To get an SSH shell on your Spark:" \
        "  1. Power on the Spark and finish the on-screen setup wizard" \
        "     (language, username/password, WiFi). Write the password down." \
        "  2. On this computer, install NVIDIA Sync:" \
        "       https://build.nvidia.com/spark/connect-to-your-spark/sync" \
        "  3. In NVIDIA Sync: Settings -> Devices -> Add Device, enter the" \
        "     hostname from the sticker in the box (spark-XXXX.local)." \
        "  4. Select the device -> click ${B}Terminal${N}." \
        "" \
        "Then paste this same command into that terminal window."
fi

for cmd in git curl; do
    command -v "$cmd" >/dev/null 2>&1 || die \
        "'${cmd}' is not installed, and this installer needs it." \
        "Install it with:  sudo apt-get update && sudo apt-get install -y ${cmd}"
done

# ── Which release? ───────────────────────────────────────────────────────────
resolve_tag() {
    if [ -n "${SPARK_TAG:-}" ]; then printf '%s' "${SPARK_TAG}"; return; fi
    local t
    t=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${OWNER_REPO}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    printf '%s' "${t:-${FALLBACK_TAG}}"
}
TAG="$(resolve_tag)"

echo "  ${D}version${N}  ${TAG}"
echo "  ${D}folder ${N}  ${DIR}"
echo ""

# ── Fetch ────────────────────────────────────────────────────────────────────
if [ -d "${DIR}/.git" ]; then
    echo "  Updating existing install..."
    git -C "${DIR}" fetch --tags --quiet origin 2>/dev/null || die \
        "Could not reach GitHub to update ${DIR}." \
        "Check this machine's internet connection and try again."
    # A dirty tree here is almost always someone's edited config. Refuse rather
    # than throw their changes away; the wizard is re-runnable, their edits are not.
    if ! git -C "${DIR}" diff --quiet || ! git -C "${DIR}" diff --cached --quiet; then
        die "${DIR} has uncommitted local changes, so it cannot be updated safely." \
            "" \
            "Keep them:     cd ${DIR} && git stash" \
            "Throw away:    cd ${DIR} && git checkout ." \
            "Then re-run this installer."
    fi
    git -C "${DIR}" checkout --quiet "${TAG}" 2>/dev/null || die \
        "Could not switch ${DIR} to ${TAG}."
else
    echo "  Downloading spark-sovereign..."
    git clone --quiet "${REPO_URL}" "${DIR}" 2>/dev/null || die \
        "Could not download the repo into ${DIR}." \
        "Check internet access, or that ${DIR} is writable and not already occupied."
    git -C "${DIR}" checkout --quiet "${TAG}" 2>/dev/null || true
fi

echo "  ${G}Ready.${N}"

[ -f "${DIR}/scripts/wizard.sh" ] || die \
    "This release (${TAG}) predates the setup wizard." \
    "Re-run with a newer version:  SPARK_TAG=main bash install.sh"

# exec, not call: the wizard takes over the terminal from here, and may re-exec
# itself into tmux or a docker-group shell. Nothing below it would ever run.
exec bash "${DIR}/scripts/wizard.sh"
