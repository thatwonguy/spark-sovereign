#!/usr/bin/env bash
#
# Memory hook — called at end of NemoClaw sessions
# Extracts lessons and stores them in pgvector
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SESSION_LOG="${1:-}"
DOMAIN="${2:-agent}"

if [ -z "$SESSION_LOG" ]; then
    echo "Usage: $0 <session_log_file> [domain]"
    exit 1
fi

echo "=== Memory Hook ==="
echo "Session log: $SESSION_LOG"
echo "Domain: $DOMAIN"
echo ""

python3 "${PROJECT_ROOT}/scripts/curate_session.py" \
    --file "$SESSION_LOG" \
    --domain "$DOMAIN"

echo ""
echo "=== Done ==="
