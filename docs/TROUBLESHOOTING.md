# Troubleshooting

## Models fail to load — OOM / CUDA out of memory

Check actual GPU memory first:
```bash
nvidia-smi
```

The combined allocation is ~109GB of 128GB. If other processes are consuming GPU memory:
```bash
# Find and kill stray processes holding GPU memory
sudo fuser -k /dev/nvidia*
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
# Then restart the affected container
docker restart qwen-brain
```

If you added another service that uses GPU memory, reduce `gpu_memory_utilization` in `config/models.yml` and re-run `scripts/03_vllm_servers.sh`.

---

## vLLM container crashes immediately

Check logs:
```bash
docker logs qwen-brain --tail 50
docker logs nemotron-nano --tail 50
```

Common causes:
- **NVFP4 kernel not supported**: ensure you're using `avarok/dgx-vllm-nvfp4-kernel:v23` for the brain (not the standard vllm image)
- **Wrong max_model_len**: reduce `max_model_len` in `config/models.yml`
- **Model download incomplete**: re-run `scripts/02_download_models.sh`

---

## pgvector schema errors on re-run

The init.sql uses `IF NOT EXISTS` everywhere — safe to re-run. If you changed the embedding dimensions (e.g., switched to NV-Embed-v2 at 4096-dim), you must recreate the tables:
```bash
docker exec pgvector psql -U postgres -d agent_memory -c "DROP TABLE rag_cache, lessons;"
bash scripts/05_pgvector.sh
```

---

## SearXNG returns no results

```bash
# Check container status
docker logs searxng --tail 30

# Test directly
curl "http://localhost:8080/search?q=nvidia+spark&format=json" | python3 -m json.tool | head -30
```

If the secret key was regenerated, SearXNG needs a restart. Set `SEARXNG_SECRET_KEY` in `.env` to a fixed value to make it stable across restarts.

---

## Swapping a model

1. Edit `config/models.yml` — change `hf_repo`, `local_path`, `docker_image`, etc.
2. Download: `bash scripts/02_download_models.sh`
3. Restart the affected server:
   - Brain: `bash scripts/03_vllm_servers.sh` (or just `docker restart qwen-brain`)
   - Sub-agent: same script or `docker restart nemotron-nano`
4. Update `config/openclaw.json` model names if using NemoClaw
5. Update `config/aider.conf.yml` model names if using Aider
6. Run health check: `bash scripts/check_stack.sh`

---

## Embedding dimension mismatch after swapping embed model

If you switch from nomic-embed (384-dim) to NV-Embed-v2 (4096-dim):
1. Update `dimensions: 4096` in `config/models.yml` under `embeddings`
2. Update the `VECTOR(384)` column definitions in `config/pgvector/init.sql` to `VECTOR(4096)`
3. Drop and recreate the tables (all stored memories will be lost — re-embed if needed)
4. Re-run `scripts/05_pgvector.sh`

---

## NemoClaw won't start

```bash
# Check Node.js
node --version     # needs >= 18

# Check config
cat ~/.openclaw/openclaw.json | python3 -m json.tool

# Restart
nemoclaw restart
# or
nemoclaw stop && nemoclaw start
```

---

## Voice pipeline not streaming

ASR/TTS use WebSocket, not HTTP. Test with:
```bash
# Check container
docker logs voice-pipeline --tail 30

# The models take a few minutes to warm up after container start
# Re-check 2-3 minutes after starting
```

---

## Aider uses wrong endpoint

Aider reads `~/.aider.conf.yml`. Verify:
```bash
cat ~/.aider.conf.yml
```
`openai-api-base` must match the Brain port (default 8000). `openai-api-key` must be `EMPTY` (not blank — the literal string EMPTY).
