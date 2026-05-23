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

# 1. Configure Docker cgroup (required for k3s/Docker on DGX OS)
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
sudo mkdir -p /opt/searxng
sudo chown -R "$(whoami):$(whoami)" "${MODELS_DIR}" /opt/searxng /opt/agent 2>/dev/null || true
echo "    Directories created."

# 3. Resolve pre-installed NeMo/pyannote package conflicts
echo ">>> Resolving pre-installed package conflicts..."
pip install \
    "fsspec==2024.12.0" \
    "protobuf==5.29.5" \
    "numpy>=2.2.2" \
    "scipy>=1.15.1" \
    "typing_extensions>=4.14.0" \
    --break-system-packages --quiet
echo "    Conflicts resolved."

# 4. Install Python tools
echo ">>> Installing Python tools..."
pip install \
    huggingface_hub \
    hf_transfer \
    psycopg2-binary \
    sentence-transformers \
    requests \
    pyyaml \
    --break-system-packages --quiet
echo "    Python tools installed."

# 5. Drop page cache (mandatory before loading large models on Spark)
echo ">>> Dropping page cache..."
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
echo "    Page cache cleared."

# 6. Clone this repo to Spark (if not already there)
if [ ! -d /opt/agent ]; then
    echo ">>> Copying agent files to /opt/agent..."
    sudo mkdir -p /opt/agent
    sudo cp -r "${REPO_ROOT}/agent/"* /opt/agent/ 2>/dev/null || true
    sudo cp "${REPO_ROOT}/config/models.yml" /opt/agent/models.yml
    sudo chown -R "$(whoami):$(whoami)" /opt/agent
fi

# 7. Install Python requirements for agent memory layer
echo ">>> Installing agent Python requirements..."
pip install -r "${REPO_ROOT}/agent/requirements.txt" \
    --break-system-packages --quiet

# 8. Install sequenced startup service — starts lightweight containers on boot,
#    then waits for Brain to be ready before starting voice services + OpenClaw.
#    Prevents simultaneous startup OOM on 128GB unified memory.
echo ">>> Installing spark-sovereign startup service..."
SPARK_REPO="${REPO_ROOT}"
sudo tee /etc/systemd/system/spark-sovereign.service > /dev/null << EOF
[Unit]
Description=spark-sovereign sequenced startup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(whoami)
ExecStart=${SPARK_REPO}/scripts/boot_sequence.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > "${SPARK_REPO}/scripts/boot_sequence.sh" << 'BOOT'
#!/usr/bin/env bash
# Sequenced boot — CPU services first, then Brain, then voice.
# Tolerates failures: if any single step fails, continue with the rest.
# Steady-state health is owned by spark-watchdog.timer (every 2 min).

set -uo pipefail   # NOTE: no -e — one failure must not abort the chain.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[spark-boot] $*"; }

log "Starting CPU-only services..."
for name in searxng; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting Brain..."
if ! bash "${REPO_ROOT}/scripts/start_brain_ad_hoc.sh"; then
    log "  Brain start failed — watchdog will retry"
fi

log "Waiting for Brain to be ready (port 8000, up to 12 min)..."
DEADLINE=$(( $(date +%s) + 720 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if curl -sf --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
        log "Brain ready."
        break
    fi
    if ! docker ps -q --filter "name=^brain$" --filter "status=running" | grep -q .; then
        log "  brain container not running — leaving recovery to watchdog"
        break
    fi
    sleep 10
done
if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    log "  Brain not ready within 12 min — leaving recovery to watchdog"
fi

log "Starting voice services..."
for name in asr-server tts-server; do
    docker start "${name}" 2>/dev/null && log "  started ${name}" || log "  ${name} not found, skipping"
done

log "Starting OpenClaw gateway..."
openclaw gateway start 2>/dev/null || log "  openclaw gateway start failed — watchdog will retry"

log "Boot sequence complete — watchdog owns steady-state health."
exit 0
BOOT

chmod +x "${SPARK_REPO}/scripts/boot_sequence.sh"
chmod +x "${SPARK_REPO}/scripts/watchdog.sh" 2>/dev/null || true

# Watchdog state directory (writable by the runtime user)
echo ">>> Creating watchdog state directory..."
sudo mkdir -p /var/lib/spark-sovereign/state
sudo chown -R "$(whoami):$(whoami)" /var/lib/spark-sovereign

# Install the watchdog service + timer (idempotent, bounded self-heal).
echo ">>> Installing spark-watchdog service and timer..."
sudo tee /etc/systemd/system/spark-watchdog.service > /dev/null << EOF
[Unit]
Description=spark-sovereign service watchdog (idempotent self-heal)
After=docker.service spark-sovereign.service
Requires=docker.service

[Service]
Type=oneshot
User=$(whoami)
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/$(whoami)/.local/bin
ExecStart=${SPARK_REPO}/scripts/watchdog.sh
StandardOutput=journal
StandardError=journal
EOF

sudo tee /etc/systemd/system/spark-watchdog.timer > /dev/null << EOF
[Unit]
Description=Run spark-sovereign watchdog every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min
Unit=spark-watchdog.service
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

# Linger lets any --user services (e.g. openclaw-gateway) survive a power
# cycle without an interactive SSH session.
echo ">>> Enabling user-level service persistence (linger)..."
sudo loginctl enable-linger "$(whoami)" || true

sudo systemctl daemon-reload
sudo systemctl enable spark-sovereign.service
sudo systemctl enable --now spark-watchdog.timer
echo "    Startup service + watchdog installed and enabled."

echo ""
echo "Phase 1 complete. Proceed to: scripts/02_download_models.sh"
