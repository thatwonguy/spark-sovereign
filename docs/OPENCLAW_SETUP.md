# OpenClaw Integration Setup

## Overview

This document describes how OpenClaw integrates with the spark-sovereign infrastructure.

## Architecture

```
spark-sovereign (infrastructure layer)
├── Docker containers
│   ├── vLLM (port 8000) - LLM inference
│   ├── ASR server (port 8002) - Speech-to-text
│   ├── TTS server (port 8003) - Text-to-speech
│   ├── pgvector (port 5432) - Vector database
│   └── searxng (port 8888) - Search engine
│
└── OpenClaw (agent layer)
    ├── Gateway (port 18789) - Agent routing
    ├── Agent configuration
    ├── MCP servers (filesystem, fetch, memory, postgres)
    └── Channels (Telegram, webchat)
```

## 07_openclaw.sh Script

This script configures OpenClaw for agent operations:

```bash
#!/bin/bash
set -euo pipefail

# 1. Install OpenClaw CLI if not present
if ! command -v openclaw &> /dev/null; then
    echo "Installing OpenClaw CLI..."
    npm install -g openclaw@latest
fi

# 2. Initialize OpenClaw workspace
mkdir -p ~/.openclaw/workspace
# Copy identity files if they don't exist
[ ! -f ~/.openclaw/workspace/SOUL.md ] && cp ${REPO_ROOT}/config/workspace/SOUL.md ~/.openclaw/workspace/SOUL.md
[ ! -f ~/.openclaw/workspace/USER.md ] && cp ${REPO_ROOT}/config/workspace/USER.md ~/.openclaw/workspace/USER.md
[ ! -f ~/.openclaw/workspace/IDENTITY.md ] && cp ${REPO_ROOT}/config/workspace/IDENTITY.md ~/.openclaw/workspace/IDENTITY.md

# 3. Install openclaw.json config
cp ${REPO_ROOT}/config/openclaw.json ~/.openclaw/openclaw.json

# 4. Install workspace identity files
cp ${REPO_ROOT}/config/workspace/IDENTITY.md ~/.openclaw/workspace/IDENTITY.md
cp ${REPO_ROOT}/config/workspace/SOUL.md ~/.openclaw/workspace/SOUL.md

# 5. Register MCP servers
openclaw mcp set filesystem --type node --args '{"path": "/home/thatwonguy/projects"}'
openclaw mcp set fetch --type node --args '{"allowedUrls": ["https://docs.openclaw.ai"]}'
openclaw mcp set memory --type node --args '{"path": "/home/thatwonguy/.openclaw/workspace/memory"}'
openclaw mcp set postgres --type node --args '{"connectionString": "postgresql://openclaw:openclaw@127.0.0.1:5432/agent_memory"}'

# 6. Add Telegram bot token
openclaw channels add --channel telegram --token "${TELEGRAM_BOT_TOKEN}"

# 7. Start OpenClaw gateway
openclaw gateway start
```

## Preprompt Mechanism

**What gets auto-injected into the LLM context:**

### Bootstrap Files (Auto-Injected)
These files are automatically added to every message via the preprompt:
- `SOUL.md` - Agent identity and behavior
- `USER.md` - User profile and preferences
- `AGENTS.md` - Workspace conventions and rules
- `TOOLS.md` - Local configuration (cameras, SSH, etc.)
- `IDENTITY.md` - Hardware and deployment details
- `HEARTBEAT.md` - Periodic check reminders
- `MEMORY.md` - Long-term curated memories

### NOT Auto-Injected
These files must be accessed via tools:
- `memory/YYYY-MM-DD.md` - Daily memory files
- Accessed via `memory_search` and `memory_get` tools

## Correct Behavior Pattern

### Session Startup (Once)
1. Read `SOUL.md`, `USER.md` (already auto-injected, verify)
2. Read `memory/YYYY-MM-DD.md` (today's file)
3. Read `MEMORY.md` (if main session)
4. Respond to user

### Every Message (After Startup)
1. Answer user's question directly
2. No memory reads unless user explicitly asks about history
3. Write memory flush only if NEW durable decision made

## Configuration

### Models Configuration (`~/.openclaw/openclaw.json`)

```json
{
  "agents": {
    "defaults": {
      "model": "local-vllm/qwen35-35b-a3b"
    },
    "providers": {
      "local-vllm": {
        "baseUrl": "127.0.0.1:8000",
        "modelId": "qwen35-35b-a3b"
      }
    }
  }
}
```

**Critical:** Do not change `baseUrl` port (8000) - this is vLLM container port.

## Troubleshooting

### Common Issues

#### 1. "Memory read takes 2+ minutes"
**Cause:** Reading `memory/YYYY-MM-DD.md` on every turn
**Fix:** Only read on session startup, use `memory_search` tool on demand

#### 2. "OpenClaw not connecting to brain"
**Cause:** vLLM container not running or wrong port
**Fix:** `docker ps | grep vllm` then `curl http://localhost:8888/v1/models`

#### 3. "Precompaction prompt fires on every message"
**Cause:** Memory flush mechanism triggering unnecessarily
**Fix:** Document correct pattern in `memory/2026-03-30.md`, stop manual writes

#### 4. "Skills not working (local-stt, local-tts)"
**Cause:** Skills not registered or path wrong
**Fix:** `openclaw channels add --channel local-stt --path ~/.openclaw/workspace/local-stt.skill`

### Safe vs Risky Operations

#### Safe
- `openclaw onboard` (doesn't overwrite unless user says so)
- `openclaw doctor --fix` (only sets env vars)
- Adding new channels
- Updating skill files

#### Risky
- Changing `baseUrl` port in config
- Running onboard with `--workspace` pointing to different path
- Deleting `~/.openclaw/openclaw.json` without backup

## Onboarding Safety

**What `openclaw onboard` does:**
- Reads existing `~/.openclaw/openclaw.json`
- Can update model provider config
- Can add/change channels
- Does NOT touch Docker containers

**What `openclaw doctor --fix` does:**
- Sets env vars like `NODE_COMPILE_CACHE`
- May adjust service configs
- Does NOT touch Docker containers

**Recommendation:** Run `openclaw onboard --skip-skills` if you need a behavioral reset. It won't break your Docker setup.

## Backup & Recovery

### Backup
```bash
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.backup
cp ~/.openclaw/workspace/local-stt.skill ~/.openclaw/workspace/local-stt.skill.backup
cp ~/.openclaw/workspace/local-tts.skill ~/.openclaw/workspace/local-tts.skill.backup
```

### Recovery
```bash
# Restore config
cp ~/.openclaw/openclaw.json.backup ~/.openclaw/openclaw.json

# Restore skills (if needed)
openclaw skills add --path ~/.openclaw/workspace/local-stt.skill
openclaw skills add --path ~/.openclaw/workspace/local-tts.skill

# Restart gateway
openclaw gateway restart
```

## Files Reference

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main OpenClaw configuration |
| `~/.openclaw/workspace/` | Agent workspace (SOUL.md, USER.md, etc.) |
| `~/.openclaw/workspace/memory/` | Daily memory files |
| `/home/thatwonguy/projects/` | User projects (restricted access) |

## Version

- OpenClaw: 2026.3.28 (f9b1079)
- Last updated: 2026-03-30
