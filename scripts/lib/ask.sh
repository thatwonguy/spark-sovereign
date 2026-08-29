#!/usr/bin/env bash
# =============================================================================
# Shared terminal-input helpers
# =============================================================================
# Sourced by any script that has to ask a human a question. It lives here
# because getting this right is subtle and getting it wrong is dangerous:
# an earlier copy of this logic silently answered a destructive prompt with
# the next line of a pasted command block. Fix it once, here.
#
# Usage:
#   source "${REPO_ROOT}/scripts/lib/ask.sh"
#   have_tty || echo "nobody to ask"
#   ask "Your name: " REPLY_VAR
# =============================================================================

# True when there is a terminal to talk to. `-r /dev/tty` can pass on a node
# that still fails to open it, so opening it is the real test. The subshell
# matters: redirecting stderr around a later read would swallow the prompt,
# because `read -p` writes to stderr.
have_tty() { ( : < /dev/tty ) 2>/dev/null; }

# ask <prompt> <varname> — read one answer from the terminal into <varname>.
# Returns 1 when there is no terminal, so callers can pick their own fallback.
#
# Reads from /dev/tty rather than stdin, and discards anything already buffered
# there. Under `curl ... | bash`, or from a pasted multi-line command block,
# stdin holds the rest of the script; a plain `read` consumes the next line of
# it as the answer.
ask() {
    local __var="$2" reply=""
    have_tty || return 1
    while read -r -t 0 2>/dev/null; do read -r _ 2>/dev/null || break; done
    # Prompt to the terminal, not stdout: piping the caller would otherwise
    # buffer the question into the pipe while read blocks on the tty, leaving
    # it waiting on a prompt nobody can see.
    printf '%s' "$1" > /dev/tty
    read -r reply < /dev/tty || return 1
    printf -v "${__var}" '%s' "${reply}"
}
