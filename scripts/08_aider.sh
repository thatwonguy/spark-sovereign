#!/usr/bin/env bash
# =============================================================================
# PHASE 8 — Aider CLI Coding Setup
# =============================================================================
# Installs aider config pointing at local vLLM endpoints.
# aider was installed in Phase 1 via pip.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "========================================================"
echo " spark-sovereign — Phase 8: Aider"
echo "========================================================"

# Install aider config to home directory
echo ">>> Installing aider config..."
cp "${REPO_ROOT}/config/aider.conf.yml" ~/.aider.conf.yml
echo "    ~/.aider.conf.yml installed."

# Verify aider is installed
if ! command -v aider &>/dev/null; then
    echo "    Installing aider..."
    pip install aider-chat --break-system-packages --quiet
fi

AIDER_VER=$(aider --version 2>/dev/null || echo "unknown")
echo "    aider version: ${AIDER_VER}"

echo ""
echo "Aider is ready. Usage:"
echo "  cd ~/projects/my-saas"
echo "  aider                                         # interactive TUI, uses qwen35-35b-a3b"
echo "  aider --message \"Add Stripe webhook handler\"  # inline command"
echo ""
echo "Phase 8 complete. Proceed to: scripts/check_stack.sh"
