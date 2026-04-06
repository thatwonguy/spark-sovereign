# Agentic Framework Setup

## Overview

spark-sovereign serves a local LLM via vLLM on `http://localhost:8000/v1` using the standard OpenAI-compatible API. Any agentic framework that speaks this protocol can connect to it.

**Tested:** [OpenClaw](https://github.com/openclaw/openclaw) — open source, no API key required, runs fully local.

**Also compatible:** Any framework that supports OpenAI-compatible endpoints — LangChain, AutoGen, CrewAI, Open Interpreter, LobeChat, text-generation-webui, SillyTavern, or your own code using the OpenAI Python/JS SDK.

## Architecture (v3.0)

```
spark-sovereign (infrastructure layer)
└── Docker: vLLM (port 8000) — LLM inference
         |
    Your agentic framework of choice
    ├── Agent orchestration
    ├── Tool calling / MCP servers
    ├── Memory / RAG
    ├── Voice (STT / TTS)
    ├── Channels (Telegram, CLI, web UI)
    └── Whatever else your framework supports
```

Brain is the only required container. Everything else is handled by your chosen framework.

## Connecting Any Framework

After running `scripts/03_vllm_servers.sh`, Brain is serving at:

| Setting | Value |
|---|---|
| **Base URL** | `http://localhost:8000/v1` |
| **Model ID** | Value of `served_name` in `config/models.yml` (currently `qwen35-35b`) |
| **API key** | Any string (e.g. `local`) — not validated |
| **Context window** | Value of `max_model_len` in `config/models.yml` (currently `131072`) |

### Quick test (works from any language/framework)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer local" \
  -d '{
    "model": "qwen35-35b",
    "messages": [{"role": "user", "content": "Hello, who are you?"}]
  }'
```

### Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="local")
response = client.chat.completions.create(
    model="qwen35-35b",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)
```

### Node.js (OpenAI SDK)

```javascript
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://localhost:8000/v1", apiKey: "local" });
const response = await client.chat.completions.create({
  model: "qwen35-35b",
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(response.choices[0].message.content);
```

## OpenClaw Setup (Recommended)

OpenClaw is the tested agentic layer for this project. It provides voice, memory, Telegram, web search, MCP tools, and agent orchestration out of the box.

### Install

```bash
npm install -g openclaw@latest
```

### Onboard

```bash
openclaw onboard
```

When the wizard asks:

| Prompt | Enter |
|---|---|
| Provider type | OpenAI-compatible endpoint |
| Base URL | `http://localhost:8000/v1` |
| Model ID | `qwen35-35b` (or your `served_name` from `config/models.yml`) |
| API key | `local` (any string) |
| Context window | `131072` (or your `max_model_len` from `config/models.yml`) |

Everything else (agent name, personality, voice, memory, Telegram, workspace) is configured inside the OpenClaw wizard.

### Verify

```bash
openclaw doctor
openclaw tui   # interactive terminal chat
```

### Optional: Voice (STT)

```bash
bash scripts/04_voice_stt.sh
```

This installs local Whisper CLI for speech-to-text. OpenClaw auto-detects it — no manual config needed.

### Optional: MCP Servers

See `config/mcp_servers.json` for a catalog of MCP servers (filesystem, git, GitHub, Slack, AWS, Stripe, etc.). Copy the blocks you want into your OpenClaw config.

## Troubleshooting

### Brain not responding

```bash
curl http://localhost:8000/v1/models
docker logs brain --tail 50
```

### OpenClaw not connecting

Verify Brain is up, then check that OpenClaw's configured base URL and model ID match:
- Base URL: `http://localhost:8000/v1`
- Model ID: must match `served_name` in `config/models.yml`

### Full health check

```bash
bash scripts/check_stack.sh
```

## Version

- Current model: Qwen3.5-35B-A3B-FP8 (v3.0)
- Last updated: April 2026
