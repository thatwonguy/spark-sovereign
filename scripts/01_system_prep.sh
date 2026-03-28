#!/usr/bin/env bash
# =============================================================================
# PHASE 1 — System Prep
# =============================================================================
# Idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || true

MODELS_DIR="${MODELS_DIR:-/opt/models}"

echo "========================================================"
echo " spark-sovereign — Phase 1: System Prep"
echo "========================================================"

# 1. Configure Docker cgroup (required for NemoClaw/k3s on DGX OS)
echo ">>> Configuring Docker cgroup..."
sudo nvidia-ctk runtime configure --runtime=docker

sudo python3 -c "
import json, os
p = '/etc/docker/daemon.json'
d = json.load(open(p)) if os.path.exists(p) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(p,'w'), indent=2)
print('  daemon.json updated.')
"
sudo systemctl restart docker
echo "    Docker restarted."

# 2. Create persistent storage directories on 4TB NVMe
echo ">>> Creating model/data directories on NVMe..."
sudo mkdir -p "${MODELS_DIR}"
sudo mkdir -p /opt/pgvector
sudo mkdir -p /opt/searxng
sudo chown -R "$(whoami):$(whoami)" "${MODELS_DIR}" /opt/pgvector /opt/searxng /opt/agent 2>/dev/null || true
echo "    Directories created."

# 3. Install Python tools
echo ">>> Installing Python tools..."
pip install \
    huggingface_hub \
    hf_transfer \
    aider-chat \
    psycopg2-binary \
    sentence-transformers \
    requests \
    pyyaml \
    --break-system-packages --quiet
echo "    Python tools installed."

# 4. Drop page cache (mandatory before loading large models on Spark)
echo ">>> Dropping page cache..."
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
echo "    Page cache cleared."

# 5. Clone this repo to Spark (if not already there)
if [ ! -d /opt/agent ]; then
    echo ">>> Copying agent files to /opt/agent..."
    sudo mkdir -p /opt/agent
    sudo cp -r "${REPO_ROOT}/agent/"* /opt/agent/
    sudo cp "${REPO_ROOT}/config/models.yml" /opt/agent/models.yml
    sudo chown -R "$(whoami):$(whoami)" /opt/agent
fi

# 6. Install Python requirements for agent memory layer
echo ">>> Installing agent Python requirements..."
pip install -r "${REPO_ROOT}/agent/requirements.txt" \
    --break-system-packages --quiet

echo ""
echo "Phase 1 complete. Proceed to: scripts/02_download_models.sh"
