# Troubleshooting

Quick reference for the spark-sovereign stack. Brain (port 8000) is the model
server; `watchdog.sh` also self-heals the SearXNG container. Voice, memory, RAG
and Telegram are OpenClaw's, not this repo's.

**Brain requires an API key.** `scripts/03_vllm_servers.sh` generates
`BRAIN_API_KEY` into `.env` and passes it to vLLM, so every `/v1` route returns
401 without an `Authorization` header. A bare `curl` failing is not evidence
that Brain is down — see below.

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

Model is still loading. The port binds only after weights are read off NVMe
*and* torch.compile, cudagraph capture and KV-cache profiling finish; the
container shows `Up` for that whole window. `boot_sequence.sh` allows up to 12
minutes before handing over to the watchdog. The current brain is
Qwen3.8-27B-NVFP4 (`config/models.yml`), ~55 GB resident at `0.45` util. Check
progress:
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

1. Edit `config/models.yml` — update `hf_repo`, `name`, `local_path`,
   `served_name`, `gpu_memory_utilization`, and `docker_image` if the new model
   needs a different vLLM build.

   ⚠️ **Also swap or clear `speculative_config` and `speculative_draft_model`.**
   The pinned drafter is trained against the *current* checkpoint. Left in place
   across a swap it still produces correct output — every draft is verified —
   but acceptance collapses and decode drops toward the 12.0 tok/s
   non-speculative floor.
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

Verify Brain is up and returning models. **The key is required** — without it
this returns 401 and tells you nothing about whether Brain is healthy:
```bash
curl -s -H "Authorization: Bearer $(grep BRAIN_API_KEY .env | cut -d= -f2)" \
     http://localhost:8000/v1/models
```

A bare `curl http://localhost:8000/v1/models` returning 401 is the *expected*
response from a working Brain. `scripts/03_vllm_servers.sh` prints both forms
when it finishes, and `check_stack.sh` sends the header for you.

If Brain answers, check OpenClaw's configured endpoint matches:
- Base URL: `http://localhost:8000/v1`
- API key: the `BRAIN_API_KEY` value in `.env`
- Model ID: matches `served_name` in `config/models.yml` (currently `qwen38-27b`)

---

## Health check

```bash
bash scripts/check_stack.sh
```

Shows Brain endpoint status, container uptime, GPU utilization, and OpenClaw
gateway status.
