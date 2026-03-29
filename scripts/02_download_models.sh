#!/usr/bin/env bash
# =============================================================================
# PHASE 2 — Download All Models
# =============================================================================
# Sources model HF repos + local paths from config/models.yml.
# To swap a model: edit config/models.yml, re-run this script.
# Idempotent — skips already-downloaded models.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

# Ensure user-local Python CLI tools are available (huggingface-cli, aider, etc.)
export PATH="$HOME/.local/bin:$PATH"

# Optional early check so failures are obvious
if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "ERROR: huggingface-cli not found in PATH"
    echo "PATH=${PATH}"
    echo "Try: python3 -m pip install --user huggingface_hub[hf_transfer]"
    exit 1
fi

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export HF_TOKEN="${HF_TOKEN:-}"

# Helper: read a value from models.yml without requiring yq
# Usage: get_model_field <top_key> <field>
get_model_field() {
    python3 -c "
import yaml, sys
with open('${REPO_ROOT}/config/models.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('$1', {}).get('$2', ''))
"
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

    echo "  Downloading ${label} → ${local_path}"
    echo "    HF repo: ${hf_repo}"
    mkdir -p "${local_path}"
    huggingface-cli download "${hf_repo}" --local-dir "${local_path}"
    echo "  OK ${label}"
}

echo "========================================================"
echo " spark-sovereign — Phase 2: Download Models"
echo "========================================================"
echo "  HF_HUB_ENABLE_HF_TRANSFER=${HF_HUB_ENABLE_HF_TRANSFER}"
echo ""

download_model "Brain (Qwen3.5-122B NVFP4)"    brain
download_model "Sub-agents (Nemotron Nano NVFP4)" subagent
download_model "ASR (Nemotron Speech)"           asr
download_model "TTS (Magpie TTS)"                tts
download_model "Embeddings (Nomic Embed)"        embeddings

echo ""
echo "All models downloaded."
echo ""
echo "Disk usage summary:"
du -sh "$(get_model_field brain local_path)" \
       "$(get_model_field subagent local_path)" \
       "$(get_model_field asr local_path)" \
       "$(get_model_field tts local_path)" \
       "$(get_model_field embeddings local_path)" 2>/dev/null || true

echo ""
echo "Phase 2 complete. Proceed to: scripts/03_vllm_servers.sh"
