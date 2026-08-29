#!/usr/bin/env bash
# =============================================================================
# spark-sovereign — guided setup wizard
# =============================================================================
# The friendly front end to scripts 01 -> 02 -> 03 (-> 04). It asks a handful
# of plain-language questions, checks the machine can actually do the job, then
# runs the phase scripts in order and shows you the result.
#
# It adds no logic of its own to the stack. Everything it runs is a script you
# could run by hand; the wizard exists so that nobody has to know that.
#
# Run it directly if you already cloned the repo:
#   bash scripts/wizard.sh
#
# Every phase is idempotent, so if this is interrupted at any point, re-running
# it picks up where it left off. That property is why the wizard can be blunt
# about failure instead of trying to unwind anything.
# =============================================================================

# No -e: the wizard handles every failure itself, with an explanation. A bare
# exit on the first non-zero would strand a non-technical user at a blank prompt.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${REPO_ROOT}/scripts/wizard.sh"
LOG="${HOME}/spark-sovereign-install.log"
MIN_FREE_GB=80          # ~22 GB weights + drafter + the arm64 vLLM image + compile cache
START_TS=$SECONDS

# Present on every run but the first. Read it before the checks below so that a
# custom MODELS_DIR is the one whose free space gets measured, and so an answer
# given on a previous run is not asked for again.
source "${REPO_ROOT}/.env" 2>/dev/null || true
[ "${HF_TOKEN:-}" = "your_hf_token_here" ] && HF_TOKEN=""

# Pruning a model the config no longer lists is destructive, and under the
# wizard the phase scripts' stdout is a pipe, so they cannot ask. Choose the
# recoverable answer on the user's behalf: archive to /opt/model-archive.
export ARCHIVE_OLD_MODEL="${ARCHIVE_OLD_MODEL:-yes}"

# ── Presentation ─────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'
    C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; R=""; C=""; D=""; N=""
fi

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "${D}  ------------------------------------------------------------${N}"; }
ok()   { printf '  %s  %s\n' "${G}OK${N}" "$*"; }
warn() { printf '  %s  %s\n' "${Y}!!${N}" "$*"; }
bad()  { printf '  %s  %s\n' "${R}XX${N}" "$*"; }
note() { printf '      %s\n' "${D}$*${N}"; }

step() {
    echo ""
    hr
    printf '  %s  %s\n' "${B}${C}$1${N}" "${B}$2${N}"
    hr
    echo ""
}

fmt_dur() {
    local s=$1
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    else printf '%dm %ds' $((s / 60)) $((s % 60)); fi
}

# ── Input ────────────────────────────────────────────────────────────────────
# ask() / have_tty(), shared with 02_download_models.sh.
source "${REPO_ROOT}/scripts/lib/ask.sh"

# confirm "question" y|n  -> 0 for yes, 1 for no. The second argument is what
# pressing Enter means, and is also the answer when there is no terminal at all.
confirm() {
    local prompt="$1" default="${2:-n}" reply="" hint
    if [ "${default}" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    ask "  ${prompt} ${hint} " reply || reply=""
    reply="${reply:-${default}}"
    case "${reply}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

die() {
    echo ""
    bad "${B}Setup stopped.${N}"
    echo ""
    printf '      %s\n' "$@"
    echo ""
    exit 1
}

# Without a terminal every question below would silently take its default and
# run a 40-minute install nobody asked to start. Refuse instead, and keep the
# unattended path behind an explicit opt-in for scripted rebuilds.
if ! have_tty && [ "${SPARK_UNATTENDED:-0}" != "1" ]; then
    die "This wizard needs an interactive terminal to ask its questions." \
        "" \
        "If you reached here over SSH, connect with a terminal attached:" \
        "  ssh <user>@<your-spark>" \
        "then run:  bash ${SELF}" \
        "" \
        "To install with no questions at all, using the defaults:" \
        "  SPARK_UNATTENDED=1 bash ${SELF}"
fi

# ── 0. Welcome ───────────────────────────────────────────────────────────────
clear 2>/dev/null || true
cat <<BANNER

  ${B}spark-sovereign${N}
  ${D}Your own AI. Your hardware. Nothing leaves this machine.${N}

  This will set up a private AI assistant on this DGX Spark. When it is
  finished you will have a model running here, answering on this machine,
  with no account, no subscription, and no internet dependency.

  ${B}What happens next${N}
    1.  A few quick checks that this machine is ready
    2.  Two short questions
    3.  About ${B}40 minutes${N} of unattended work - you can walk away

  ${B}What you need${N}
    -  This Spark plugged in and on the internet
    -  Your password for this machine, for the steps that need it
    -  About ${MIN_FREE_GB} GB of free disk space

  ${D}Nothing is sent anywhere. The only downloads are the AI model weights${N}
  ${D}and the software that runs them. A full record is written to${N}
  ${D}${LOG}${N}

BANNER

confirm "Ready to begin?" y || { echo ""; say "  No problem - run this again whenever you like."; echo ""; exit 0; }

# ── Keep it alive across a dropped connection ────────────────────────────────
# A 40-minute install over SSH will outlive some people's WiFi. tmux makes that
# survivable and re-attaching is one command. Only offered once.
# have_tty is a hard requirement here, not politeness: tmux cannot start without
# a terminal, and the confirm below would default to yes on its own.
if have_tty && [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ] && [ "${SPARK_WIZARD_TMUX:-0}" != "1" ] \
   && [ -n "${SSH_CONNECTION:-}" ] && command -v tmux >/dev/null 2>&1; then
    echo ""
    say "  ${Y}You are connected over SSH.${N} If that connection drops during the"
    say "  install, it would be interrupted. Running inside ${B}tmux${N} prevents that -"
    say "  the work keeps going on the Spark and you reconnect with one command:"
    say "      ${C}tmux attach -t spark${N}"
    echo ""
    if confirm "Protect the install with tmux? (recommended)" y; then
        export SPARK_WIZARD_TMUX=1
        # `exec bash` afterwards so the session stays open on the summary screen
        # instead of closing the window the moment the wizard finishes.
        exec tmux new-session -A -s spark "bash '${SELF}'; exec bash"
    fi
fi

# ── 1. Checks ────────────────────────────────────────────────────────────────
step "Step 1 of 5" "Checking this machine"

PROBLEMS=0
problem() {
    local line
    bad "$1"; shift
    for line in "$@"; do note "${line}"; done
    PROBLEMS=$((PROBLEMS + 1))
}

# Running as root would install everything into /root and leave the real user
# unable to reach any of it. The phase scripts assume a normal user with sudo.
if [ "$(id -u)" -eq 0 ]; then
    problem "Running as root." \
            "Log in as your normal user and run this again - the scripts ask" \
            "for your password only where they actually need it."
else
    ok "Running as $(whoami)"
fi

ARCH="$(uname -m)"
if [ "${ARCH}" = "aarch64" ] || [ "${ARCH}" = "arm64" ]; then
    ok "DGX Spark hardware (${ARCH})"
elif [ "${SPARK_SKIP_ARCH:-0}" = "1" ]; then
    warn "CPU is ${ARCH}, not aarch64 - continuing because SPARK_SKIP_ARCH=1"
else
    problem "This does not look like a DGX Spark (CPU is ${ARCH}, expected aarch64)." \
            "spark-sovereign is built for the Spark's GB10 chip and will not" \
            "work here. If you know what you are doing, re-run with" \
            "SPARK_SKIP_ARCH=1 set."
fi

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "NVIDIA GPU is responding"
else
    problem "The GPU is not responding to nvidia-smi." \
            "Try rebooting the Spark (sudo reboot) and running this again." \
            "If it keeps happening, the machine needs attention first."
fi

if command -v docker >/dev/null 2>&1; then
    ok "Docker is installed"
else
    problem "Docker is not installed." \
            "It ships with DGX OS, so this is unexpected. Install it with:" \
            "  sudo apt-get update && sudo apt-get install -y docker.io"
fi

if command -v python3 >/dev/null 2>&1; then
    ok "Python 3 is available"
else
    problem "python3 is missing." "Install it with: sudo apt-get install -y python3"
fi

if curl -fsS --max-time 15 -o /dev/null https://huggingface.co 2>/dev/null; then
    ok "Internet connection works"
else
    problem "Cannot reach huggingface.co, where the AI model is downloaded from." \
            "Check this machine's network connection and try again."
fi

# Measure the filesystem that will actually hold the weights, which may not be /.
MODELS_DIR="${MODELS_DIR:-/opt/models}"
SPACE_TARGET="${MODELS_DIR}"
while [ ! -d "${SPACE_TARGET}" ] && [ "${SPACE_TARGET}" != "/" ]; do
    SPACE_TARGET="$(dirname "${SPACE_TARGET}")"
done
FREE_GB=$(df -BG --output=avail "${SPACE_TARGET}" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${FREE_GB}" ] && [ "${FREE_GB}" -ge "${MIN_FREE_GB}" ]; then
    ok "Disk space: ${FREE_GB} GB free"
elif [ -n "${FREE_GB}" ]; then
    problem "Only ${FREE_GB} GB free on ${SPACE_TARGET}, and about ${MIN_FREE_GB} GB is needed." \
            "Free up space and run this again. Old Docker images are usually" \
            "the biggest win:  docker system prune -a"
else
    warn "Could not measure free disk space - continuing anyway"
fi

if [ "${PROBLEMS}" -gt 0 ]; then
    echo ""
    die "${PROBLEMS} problem(s) above need fixing first." \
        "Nothing on this machine has been changed. Fix them and run this again."
fi

# ── Docker permissions ───────────────────────────────────────────────────────
# Being outside the docker group is the most common blocker, and it is fixable
# in place: add the group, then re-exec under it so the new membership applies
# now rather than after a logout nobody explains.
if docker info >/dev/null 2>&1; then
    ok "Docker is usable"
elif [ "${SPARK_WIZARD_REGROUPED:-0}" = "1" ]; then
    die "Docker still is not usable by $(whoami) after adding the group." \
        "Log out of this SSH session, log back in, and run this again:" \
        "  bash ${SELF}"
else
    echo ""
    say "  ${Y}One thing to fix:${N} your user is not allowed to use Docker yet."
    say "  ${D}Fixing it needs your password, and takes a second.${N}"
    echo ""
    if sudo usermod -aG docker "$(whoami)" && command -v sg >/dev/null 2>&1; then
        ok "Fixed - reloading with the new permission"
        export SPARK_WIZARD_REGROUPED=1
        exec sg docker -c "bash '${SELF}'"
    fi
    die "Could not grant Docker access automatically." \
        "Run these two commands, then start this wizard again:" \
        "  sudo usermod -aG docker \$USER" \
        "  newgrp docker"
fi

# ── Password, once ───────────────────────────────────────────────────────────
# Priming sudo now, and refreshing it in the background, means the install does
# not stall at minute 25 on a password prompt nobody is sitting there to answer.
echo ""
say "  ${D}Some steps need your password. You will be asked once, now.${N}"
sudo -v || die "Could not verify your password." \
               "This account needs sudo access to install the system services."
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE=$!
trap 'kill "${SUDO_KEEPALIVE}" 2>/dev/null' EXIT

# ── 2. Questions ─────────────────────────────────────────────────────────────
step "Step 2 of 5" "Two questions"

[ -f "${REPO_ROOT}/.env" ] || cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
chmod 600 "${REPO_ROOT}/.env"

# Written with python3 rather than sed so that a value containing regex-special
# characters cannot corrupt the file it is being written into.
set_env_var() {
    python3 - "${REPO_ROOT}/.env" "$1" "$2" <<'PYEOF'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.read().splitlines()
out, seen = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(key + "=" + value)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(key + "=" + value)
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
PYEOF
}

CURRENT_HF=$(grep -E '^HF_TOKEN=' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2-)
[ "${CURRENT_HF}" = "your_hf_token_here" ] && CURRENT_HF=""
HF_TOKEN="${HF_TOKEN:-${CURRENT_HF}}"

say "  ${B}1. Hugging Face account${N} ${D}(optional)${N}"
echo ""
say "  Hugging Face is where the AI model gets downloaded from. The model this"
say "  uses is public, so ${B}you do not need an account${N} - but signing in makes"
say "  the model download noticeably faster and more reliable."
echo ""
if [ -n "${HF_TOKEN}" ]; then
    ok "A token is already saved - using it"
else
    say "  ${D}To get one: sign up free at huggingface.co, then open${N}"
    say "  ${C}https://huggingface.co/settings/tokens${N} ${D}and create a 'Read' token.${N}"
    say "  ${D}It looks like:  hf_xxxxxxxxxxxxxxxxxxxxxxxx${N}"
    echo ""
    ask "  Paste your token, or press Enter to skip: " HF_TOKEN || HF_TOKEN=""
fi

if [ -n "${HF_TOKEN}" ]; then
    HF_USER=$(curl -fsS --max-time 15 -H "Authorization: Bearer ${HF_TOKEN}" \
                   https://huggingface.co/api/whoami-v2 2>/dev/null \
              | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "${HF_USER}" ]; then
        ok "Signed in to Hugging Face as ${HF_USER}"
        set_env_var HF_TOKEN "${HF_TOKEN}"
    else
        warn "That token was not accepted - continuing without it"
        note "The download still works, just anonymously. You can add a token"
        note "later by editing the HF_TOKEN line in ${REPO_ROOT}/.env"
        HF_TOKEN=""
    fi
else
    ok "Continuing without an account"
fi
export HF_TOKEN

echo ""
say "  ${B}2. Voice${N} ${D}(optional, adds a few minutes)${N}"
echo ""
say "  Installs local speech-to-text, so you can talk to your AI instead of"
say "  typing. Like everything else here, it runs on this machine only."
echo ""
WANT_VOICE=0
confirm "Install voice support?" n && WANT_VOICE=1

# ── 3. Confirm ───────────────────────────────────────────────────────────────
step "Step 3 of 5" "Ready to install"

say "  Here is what will happen. ${B}You do not need to do anything${N} during it."
echo ""
say "    ${C}1.${N}  Prepare the system            ${D}quick${N}"
say "    ${C}2.${N}  Download the AI model         ${D}the long one - go do something else${N}"
say "    ${C}3.${N}  Start it up                   ${D}a few minutes${N}"
if [ "${WANT_VOICE}" -eq 1 ]; then
say "    ${C}4.${N}  Install voice support         ${D}quick${N}"
fi
echo ""
say "  ${D}The output will look technical and noisy. That is normal - it is the${N}"
say "  ${D}installer talking to itself. What matters is the summary at the end.${N}"
echo ""
say "  ${D}If anything is interrupted, run this wizard again. It resumes.${N}"
echo ""
confirm "Start the install?" y || { echo ""; say "  Stopped. Nothing was changed."; echo ""; exit 0; }

{ echo ""; echo "=== spark-sovereign wizard $(date -Iseconds) ==="; } >> "${LOG}"

# ── 4. Run ───────────────────────────────────────────────────────────────────
# Phase output is streamed AND logged: a 30-minute download with a blank screen
# reads as a hang, and the progress bars are the only reassurance on offer.
PHASE_TOTAL=3
[ "${WANT_VOICE}" -eq 1 ] && PHASE_TOTAL=4
PHASE_N=0

run_phase() {
    local title="$1" script="$2" t0=$SECONDS rc
    PHASE_N=$((PHASE_N + 1))
    step "Step 4 of 5" "${title}  ${D}(${PHASE_N} of ${PHASE_TOTAL})${N}"
    bash "${REPO_ROOT}/${script}" 2>&1 | tee -a "${LOG}"
    rc=${PIPESTATUS[0]}
    echo ""
    if [ "${rc}" -eq 0 ]; then
        ok "${title} - finished in $(fmt_dur $((SECONDS - t0)))"
        return 0
    fi
    echo ""
    bad "${B}This step did not finish.${N}  (${script}, exit code ${rc})"
    echo ""
    note "Nothing is broken - every step here can be safely repeated."
    note ""
    note "Try this first:   bash ${SELF}"
    note "It skips whatever already succeeded and retries this step."
    note ""
    note "If it fails the same way twice, the full record is in:"
    note "  ${LOG}"
    note "Open an issue with that file attached:"
    note "  https://github.com/thatwonguy/spark-sovereign/issues"
    echo ""
    exit 1
}

run_phase "Preparing the system"     scripts/01_system_prep.sh
run_phase "Downloading the AI model" scripts/02_download_models.sh
run_phase "Starting your AI"         scripts/03_vllm_servers.sh
if [ "${WANT_VOICE}" -eq 1 ]; then
    run_phase "Installing voice support" scripts/04_voice_stt.sh
fi

# ── 5. Done ──────────────────────────────────────────────────────────────────
step "Step 5 of 5" "Checking everything works"

bash "${REPO_ROOT}/scripts/check_stack.sh" 2>&1 | tee -a "${LOG}"
[ "${PIPESTATUS[0]}" -eq 0 ] || warn "The health check reported problems - see the detail above"

echo ""
hr
printf '  %s   %s\n' "${G}${B}Done. Your AI is running.${N}" "${D}Total time: $(fmt_dur $((SECONDS - START_TS)))${N}"
hr
cat <<DONE

  ${B}One last step - connect something to it.${N}

  Your AI is answering on this machine now, but nothing is talking to it yet.
  ${B}Scroll up a little.${N} The health check just above printed the exact values to
  connect with - Base URL, Model ID and API key - along with what to do about
  each one. Those four lines are the only thing you need.

  ${D}They are printed by the stack itself, so they stay correct if you ever swap${N}
  ${D}the model or rotate the key. To see them again at any time:${N}

      ${C}cd ${REPO_ROOT} && bash scripts/check_stack.sh${N}

  ${B}Good to know${N}

    -  It starts by itself. Power-cycle the Spark and it comes back on its own,
       in a few minutes. There is nothing to remember.
    -  It repairs itself. A watchdog checks on it regularly and restarts
       anything that stopped.
    -  To check on it any time:   ${C}cd ${REPO_ROOT} && bash scripts/check_stack.sh${N}
    -  If something looks wrong:  ${C}docs/TROUBLESHOOTING.md${N}

  ${D}Full log of this install: ${LOG}${N}

DONE
