# Troubleshooting

Quick reference for the spark-sovereign stack. Only Brain (port 8000) runs as a
managed container — everything else is handled by OpenClaw.

---

## Brain won't start / container exits immediately

```bash
docker logs brain --tail 50
```

Common causes:

**Model download incomplete:**
```bash
bash scripts/02_download_models.sh   # re-downloads and verifies
```

**OOM — not enough GPU memory:**
Reduce `gpu_memory_utilization` in `config/models.yml`, then restart:
```bash
bash scripts/start_brain_ad_hoc.sh
```

**Wrong max_model_len:**
Reduce `max_model_len` in `config/models.yml` and restart Brain.

**Stale container from previous run:**
```bash
docker rm -f brain
bash scripts/start_brain_ad_hoc.sh
```

---

## Brain is running but not responding on port 8000

Model is still loading — it takes 3–5 minutes after container start to load
weights into memory (varies by model — ~35GB for the current Qwen3.6-35B-A3B-FP8). Check progress:
```bash
docker logs brain -f
```
Wait until you see `Application startup complete` or `Uvicorn running`.

---

## OOM during model load

Check what's holding GPU memory:
```bash
nvidia-smi
```

Kill stray processes and free page cache, then restart:
```bash
sudo fuser -k /dev/nvidia*
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
bash scripts/start_brain_ad_hoc.sh
```

---

## Auto-start not working after reboot

Check the systemd service installed by `01_system_prep.sh`:
```bash
systemctl status spark-sovereign
journalctl -u spark-sovereign -f
```

If the service isn't found, re-run:
```bash
bash scripts/01_system_prep.sh
```

---

## Swapping the model

1. Edit `config/models.yml` — update `hf_repo`, `name`, `local_path`, `served_name`, `gpu_memory_utilization`
2. Download new model (auto-prunes old):
   ```bash
   bash scripts/02_download_models.sh
   ```
3. Restart Brain:
   ```bash
   bash scripts/start_brain_ad_hoc.sh
   ```
4. In OpenClaw — update the model ID to match the new `served_name`
5. Verify:
   ```bash
   bash scripts/check_stack.sh
   ```

---

## OpenClaw not connecting to Brain

Verify Brain is up and returning models:
```bash
curl http://localhost:8000/v1/models
```

If Brain is up, check OpenClaw's configured endpoint matches:
- Base URL: `http://localhost:8000/v1`
- Model ID: matches `served_name` in `config/models.yml`

---

## Health check

```bash
bash scripts/check_stack.sh
```

Shows Brain endpoint status, container uptime, GPU utilization, and OpenClaw
gateway status.
