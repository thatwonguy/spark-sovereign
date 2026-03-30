# Memory System — Getting Smarter Every Session

Your agent **automatically learns** from every interaction. This guide shows how to activate and use it.

## How It Works

1. **Session starts** → Agent recalls relevant lessons from pgvector
2. **During session** → Agent uses recalled knowledge to inform responses
3. **Session ends** → Agent curates durable lessons from what happened
4. **Lessons stored** → Next session will recall these new learnings

## Architecture

### Two Memory Layers

**1. OpenClaw memory** (`~/.openclaw/memory/`)
- File-based indexing (USER.md, SOUL.md, IDENTITY.md)
- Automatic context loading at session start
- **Status:** Files indexed, but embeddings disabled (no API key)

**2. spark-sovereign pgvector** (`~/spark-sovereign/config/pgvector/`)
- PostgreSQL + pgvector 0.8.2 on port 5432
- Tables: `lessons`, `rag_cache`
- 384-dim embeddings (nomic-embed-text-v1.5)
- **Status:** Ready to use, not yet integrated into agent loop

### Current Setup

```
Session → Recall context from pgvector → Agent responds
    ↓
Session ends → curate_session() → Store lessons in pgvector
```

## Activation Steps

### 1. Add Memory MCP Server to NemoClaw

```bash
# Copy the MCP config to NemoClaw
cp ~/spark-sovereign/config/mcp_servers_memory.json \
   ~/.nemoclaw/config/mcp_servers.json
```

This exposes pgvector memory as an MCP tool callable by the agent.

### 2. Configure Memory Hook in NemoClaw

Edit `~/.nemoclaw/config/policies.yaml` and add:

```yaml
hooks:
  on_session_end:
    - type: script
      script: ~/spark-sovereign/scripts/memory_hook.sh
      args: ["${SESSION_LOG}", "${DOMAIN}"]
```

### 3. (Optional) Auto-Curate Sessions

Run this after each session:

```bash
# Manually
python3 ~/spark-sovereign/scripts/curate_session.py \
    --summary "Session summary text" \
    --domain "your-domain"

# Or with log file
python3 ~/spark-sovereign/scripts/curate_session.py \
    --file session_log.jsonl \
    --domain "your-domain"
```

## Querying Memory

### Check stats
```bash
python3 ~/spark-sovereign/agent/memory.py stats
```

### Recall by query
```bash
python3 ~/spark-sovereign/agent/memory.py recall "stripe webhooks"
python3 ~/spark-sovereign/agent/memory.py recall "local AI deployment" --domain "infrastructure"
```

### Store a lesson manually
```bash
python3 ~/spark-sovereign/agent/memory.py lesson \
    "User prefers local AI over cloud APIs" \
    --outcome preference \
    --domain preferences \
    --importance 0.9
```

## Example Workflow

**Session:** You ask about Stripe webhook handling

1. **Start:** Agent queries pgvector for "stripe webhooks"
   - Finds previous lessons about Stripe errors
   - Recalls what worked and what failed

2. **During:** Agent uses that knowledge
   - Suggests retry logic based on past failures
   - References specific error patterns it's learned from

3. **End:** curate_session() extracts:
   - "Stripe webhooks need exponential backoff retry" (importance=0.9)
   - "webhook.secret validation failed when using wrong encoding" (importance=1.0)

4. **Next session:** These lessons are recalled when discussing Stripe

## Tips

- **Domains help organization** — tag lessons by area (stripe, devops, python, preferences)
- **Failure lessons are highest priority** — importance=1.0 ensures they're recalled first
- **Verified web results** — mark correct web search results to boost their recall ranking
- **Session summaries** — more detailed summaries = better lesson extraction

## Troubleshooting

**No lessons showing up?**
- Check pgvector is running: `docker exec pgvector psql -U postgres -d agent_memory -c "SELECT COUNT(*) FROM lessons;"`
- Run `curate_session.py` manually to test
- Check logs: `~/spark-sovereign/logs/agent.log`

**Recall returning nothing?**
- Query needs to match lesson content semantically
- Try broader query terms
- Increase `top_k` parameter

**Importance scores not working?**
- Failures automatically get importance=1.0
- Success lessons default to 0.8
- Adjust manually with `--importance` flag
