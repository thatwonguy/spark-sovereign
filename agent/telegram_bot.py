#!/usr/bin/env python3
"""
Telegram bot — thin wrapper over OpenClaw API.
Zero NVIDIA relay. Messages go: Telegram → OpenClaw (local) → Telegram.

OpenClaw handles everything: tools, memory, web search, GitHub, SOUL.md, IDENTITY.md.
This bot only handles:
  - Telegram polling + message routing
  - Voice: OGG→PCM→ASR (local), then text into OpenClaw, then TTS→voice reply
  - Photo: base64 encode + multimodal content into OpenClaw

Sessions are stable per Telegram user ID so OpenClaw maintains conversation context.
"""

import asyncio
import base64
import json
import logging
import os
import subprocess
import sys

import aiohttp

# ── Config ────────────────────────────────────────────────────────────────────

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED_IDS = {
    int(x.strip())
    for x in os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").split(",")
    if x.strip().isdigit()
}

# OpenClaw gateway — all AI logic lives here (tools, memory, system prompt)
OPENCLAW_URL   = os.environ.get("OPENCLAW_URL",   "http://localhost:18789")
OPENCLAW_TOKEN = os.environ.get("OPENCLAW_TOKEN", "")
OPENCLAW_MODEL = os.environ.get("OPENCLAW_MODEL", "openclaw/default")

# Voice pipeline (local, no cloud)
ASR_WS  = os.environ.get("ASR_WS",  "ws://localhost:8002")
TTS_URL = os.environ.get("TTS_URL", "http://localhost:8003/v1/audio/speech")

TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}"

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("telegram_bot")

# ── Telegram helpers ──────────────────────────────────────────────────────────

def allowed(user_id: int) -> bool:
    return not ALLOWED_IDS or user_id in ALLOWED_IDS


async def tg(session: aiohttp.ClientSession, method: str, **kwargs) -> dict:
    async with session.post(f"{TELEGRAM_API}/{method}", json=kwargs) as r:
        return await r.json()


async def tg_file(session: aiohttp.ClientSession, method: str, **kwargs) -> dict:
    data = aiohttp.FormData()
    for k, v in kwargs.items():
        if isinstance(v, bytes):
            data.add_field(k, v, filename="audio.ogg", content_type="audio/ogg")
        else:
            data.add_field(k, str(v))
    async with session.post(f"{TELEGRAM_API}/{method}", data=data) as r:
        return await r.json()


async def download_file(session: aiohttp.ClientSession, file_id: str) -> bytes:
    info = await tg(session, "getFile", file_id=file_id)
    path = info["result"]["file_path"]
    url  = f"https://api.telegram.org/file/bot{TELEGRAM_BOT_TOKEN}/{path}"
    async with session.get(url) as r:
        return await r.read()


# ── OpenClaw API ──────────────────────────────────────────────────────────────

async def call_openclaw(messages: list, user_id: int, timeout: int = 120) -> str:
    """
    Route messages through OpenClaw — gets tools, memory, SOUL.md, all MCP servers.
    user_id gives each Telegram user a stable session (OpenClaw maintains context).
    """
    headers = {"Content-Type": "application/json"}
    if OPENCLAW_TOKEN:
        headers["Authorization"] = f"Bearer {OPENCLAW_TOKEN}"

    payload = {
        "model": OPENCLAW_MODEL,
        "messages": messages,
        "stream": False,
        "user": f"tg-{user_id}",   # stable session per Telegram user
    }

    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{OPENCLAW_URL}/v1/chat/completions",
            headers=headers,
            json=payload,
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as r:
            if r.status != 200:
                text = await r.text()
                raise RuntimeError(f"OpenClaw HTTP {r.status}: {text[:200]}")
            data = await r.json()

    return data["choices"][0]["message"]["content"]


# ── ASR ───────────────────────────────────────────────────────────────────────

def ogg_to_pcm(ogg_bytes: bytes) -> bytes:
    """Convert Telegram OGG/Opus voice note to 16kHz mono PCM for ASR."""
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", "pipe:0",
         "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1"],
        input=ogg_bytes, capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg: {result.stderr.decode()[:200]}")
    return result.stdout


async def transcribe(audio_bytes: bytes) -> str:
    try:
        pcm = await asyncio.to_thread(ogg_to_pcm, audio_bytes)
    except Exception as e:
        log.warning(f"Audio conversion failed: {e}")
        return ""
    try:
        import websockets
        async with websockets.connect(ASR_WS, ping_interval=None) as ws:
            chunk = 4096
            for i in range(0, len(pcm), chunk):
                await ws.send(pcm[i : i + chunk])
            await ws.send(b"")
            async for raw in ws:
                if isinstance(raw, (bytes, bytearray)):
                    raw = raw.decode()
                msg = json.loads(raw)
                if msg.get("type") in ("final", "transcript"):
                    return msg.get("text", msg.get("transcript", "")).strip()
    except Exception as e:
        log.warning(f"ASR failed: {e}")
    return ""


# ── TTS ───────────────────────────────────────────────────────────────────────

async def synthesize(text: str) -> bytes | None:
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                TTS_URL,
                json={"model": "magpie-tts", "input": text, "voice": "alloy"},
                timeout=aiohttp.ClientTimeout(total=60),
            ) as r:
                if r.status == 200:
                    return await r.read()
    except Exception as e:
        log.warning(f"TTS failed: {e}")
    return None


# ── Message handlers ──────────────────────────────────────────────────────────

async def on_text(session: aiohttp.ClientSession, msg: dict):
    user_id = msg["from"]["id"]
    chat_id = msg["chat"]["id"]
    text    = msg.get("text", "")

    if not allowed(user_id):
        return

    log.info(f"Text [{user_id}]: {text[:80]}")
    await tg(session, "sendChatAction", chat_id=chat_id, action="typing")

    try:
        reply = await call_openclaw(
            [{"role": "user", "content": text}], user_id
        )
        # Telegram max message length is 4096 — split if needed
        for chunk in [reply[i:i+4000] for i in range(0, len(reply), 4000)]:
            await tg(session, "sendMessage", chat_id=chat_id, text=chunk)
    except Exception as e:
        log.error(f"OpenClaw error: {e}")
        await tg(session, "sendMessage", chat_id=chat_id, text=f"⚠️ {e}")


async def on_photo(session: aiohttp.ClientSession, msg: dict):
    user_id = msg["from"]["id"]
    chat_id = msg["chat"]["id"]
    caption = msg.get("caption") or "What's in this image?"

    if not allowed(user_id):
        return

    log.info(f"Photo [{user_id}]: {caption[:60]}")
    await tg(session, "sendChatAction", chat_id=chat_id, action="typing")

    try:
        file_id   = msg["photo"][-1]["file_id"]
        img_bytes = await download_file(session, file_id)
        b64       = base64.b64encode(img_bytes).decode()

        messages = [{
            "role": "user",
            "content": [
                {"type": "text",      "text": caption},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ],
        }]
        reply = await call_openclaw(messages, user_id)
        await tg(session, "sendMessage", chat_id=chat_id, text=reply)
    except Exception as e:
        log.error(f"Vision error: {e}")
        await tg(session, "sendMessage", chat_id=chat_id, text=f"⚠️ {e}")


async def on_voice(session: aiohttp.ClientSession, msg: dict):
    user_id = msg["from"]["id"]
    chat_id = msg["chat"]["id"]

    if not allowed(user_id):
        return

    log.info(f"Voice [{user_id}]")
    await tg(session, "sendChatAction", chat_id=chat_id, action="typing")

    try:
        audio_data = await download_file(session, msg["voice"]["file_id"])
        transcript = await transcribe(audio_data)

        if not transcript:
            await tg(session, "sendMessage", chat_id=chat_id,
                     text="⚠️ Couldn't transcribe — try speaking more clearly.")
            return

        log.info(f"Transcript: {transcript[:80]}")
        await tg(session, "sendMessage", chat_id=chat_id,
                 text=f"🎤 _{transcript}_", parse_mode="Markdown")

        reply = await call_openclaw(
            [{"role": "user", "content": transcript}], user_id
        )

        audio_out = await synthesize(reply)
        if audio_out:
            await tg_file(session, "sendVoice", chat_id=chat_id, voice=audio_out)
        else:
            await tg(session, "sendMessage", chat_id=chat_id, text=reply)

    except Exception as e:
        log.error(f"Voice error: {e}")
        await tg(session, "sendMessage", chat_id=chat_id, text=f"⚠️ {e}")


async def dispatch(session: aiohttp.ClientSession, update: dict):
    msg = update.get("message") or update.get("edited_message")
    if not msg:
        return
    if "text" in msg:
        await on_text(session, msg)
    elif "photo" in msg:
        await on_photo(session, msg)
    elif "voice" in msg:
        await on_voice(session, msg)


# ── Port forward watchdog ─────────────────────────────────────────────────────

async def ensure_port_forward():
    """Keep openshell forward 18789 deep alive — restarts if it dies."""
    while True:
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(f"{OPENCLAW_URL}/", timeout=aiohttp.ClientTimeout(total=3)) as r:
                    if r.status < 500:
                        await asyncio.sleep(30)
                        continue
        except Exception:
            pass
        log.info("OpenClaw port forward down — restarting...")
        subprocess.Popen(
            ["openshell", "forward", "18789", "deep"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        await asyncio.sleep(10)


# ── Polling loop ──────────────────────────────────────────────────────────────

async def poll():
    if not TELEGRAM_BOT_TOKEN:
        log.error("TELEGRAM_BOT_TOKEN not set")
        sys.exit(1)
    if not OPENCLAW_TOKEN:
        log.warning("OPENCLAW_TOKEN not set — requests may be rejected by OpenClaw")

    # Start port-forward watchdog
    asyncio.create_task(ensure_port_forward())

    offset = 0
    async with aiohttp.ClientSession() as session:
        me = await tg(session, "getMe")
        if not me.get("ok"):
            log.error(f"Bad token: {me}")
            sys.exit(1)
        log.info(f"Bot @{me['result']['username']} ready — routing through OpenClaw")

        while True:
            try:
                updates = await tg(
                    session, "getUpdates",
                    offset=offset, timeout=30, limit=10,
                )
                if updates.get("ok"):
                    for u in updates["result"]:
                        offset = u["update_id"] + 1
                        asyncio.create_task(dispatch(session, u))
            except asyncio.CancelledError:
                break
            except Exception as e:
                log.warning(f"Poll error: {e}")
                await asyncio.sleep(5)


def main():
    asyncio.run(poll())


if __name__ == "__main__":
    main()
