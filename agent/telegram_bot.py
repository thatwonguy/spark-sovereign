#!/usr/bin/env python3
"""
Telegram bot — direct vLLM bridge. Zero cloud relay, zero NVIDIA dependency.
Telegram API ↔ this bot ↔ Brain (vLLM) / ASR / TTS — all local.

Features:
  - Text → Brain → text reply
  - Photo (+ optional caption) → Brain multimodal → text reply
  - Voice note → ASR → Brain → TTS → voice reply
  - Allowed user ID whitelist (TELEGRAM_ALLOWED_USER_IDS in .env)
  - Typing indicator while Brain is thinking
"""

import asyncio
import base64
import json
import logging
import os
import sys
import tempfile

import aiohttp

# ── Config ────────────────────────────────────────────────────────────────────

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED_IDS = {
    int(x.strip())
    for x in os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").split(",")
    if x.strip().isdigit()
}

BRAIN_URL   = os.environ.get("BRAIN_URL",   "http://localhost:8000/v1")
BRAIN_MODEL = os.environ.get("BRAIN_MODEL", "qwen35-35b-a3b")
ASR_WS      = os.environ.get("ASR_WS",      "ws://localhost:8002")
TTS_URL     = os.environ.get("TTS_URL",     "http://localhost:8003/v1/audio/speech")
TTS_VOICE   = os.environ.get("TTS_VOICE",   "alloy")

TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}"

# ── Logging ───────────────────────────────────────────────────────────────────

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("telegram_bot")

# ── Helpers ───────────────────────────────────────────────────────────────────

def allowed(user_id: int) -> bool:
    return not ALLOWED_IDS or user_id in ALLOWED_IDS


async def tg(session: aiohttp.ClientSession, method: str, **kwargs) -> dict:
    """Call a Telegram Bot API method."""
    async with session.post(f"{TELEGRAM_API}/{method}", json=kwargs) as r:
        return await r.json()


async def tg_file(session: aiohttp.ClientSession, method: str, **kwargs) -> dict:
    """Telegram API call using form-data (for sending files)."""
    data = aiohttp.FormData()
    for k, v in kwargs.items():
        if isinstance(v, bytes):
            data.add_field(k, v, filename="audio.ogg", content_type="audio/ogg")
        else:
            data.add_field(k, str(v))
    async with session.post(f"{TELEGRAM_API}/{method}", data=data) as r:
        return await r.json()


async def download_file(session: aiohttp.ClientSession, file_id: str) -> bytes:
    """Download a Telegram file by file_id."""
    info = await tg(session, "getFile", file_id=file_id)
    path = info["result"]["file_path"]
    url  = f"https://api.telegram.org/file/bot{TELEGRAM_BOT_TOKEN}/{path}"
    async with session.get(url) as r:
        return await r.read()


async def send_typing(session: aiohttp.ClientSession, chat_id: int):
    await tg(session, "sendChatAction", chat_id=chat_id, action="typing")


# ── Brain ─────────────────────────────────────────────────────────────────────

async def call_brain(messages: list, timeout: int = 120) -> str:
    async with aiohttp.ClientSession() as session:
        payload = {
            "model": BRAIN_MODEL,
            "messages": messages,
            "stream": False,
        }
        async with session.post(
            f"{BRAIN_URL}/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as r:
            data = await r.json()
    return data["choices"][0]["message"]["content"]


# ── ASR ───────────────────────────────────────────────────────────────────────

async def transcribe(audio_bytes: bytes) -> str:
    """Send audio to local ASR WebSocket, return transcript."""
    try:
        import websockets
        async with websockets.connect(ASR_WS, ping_interval=None) as ws:
            chunk = 4096
            for i in range(0, len(audio_bytes), chunk):
                await ws.send(audio_bytes[i : i + chunk])
            await ws.send(b"")          # EOF signal

            transcript = ""
            async for raw in ws:
                if isinstance(raw, (bytes, bytearray)):
                    raw = raw.decode()
                msg = json.loads(raw)
                if msg.get("type") in ("final", "transcript"):
                    transcript = msg.get("text", msg.get("transcript", ""))
                    break
            return transcript.strip()
    except Exception as e:
        log.warning(f"ASR failed: {e}")
        return ""


# ── TTS ───────────────────────────────────────────────────────────────────────

async def synthesize(text: str) -> bytes | None:
    """Call local TTS server, return OGG/MP3 audio bytes (or None on failure)."""
    try:
        async with aiohttp.ClientSession() as session:
            payload = {"model": "magpie-tts", "input": text, "voice": TTS_VOICE}
            async with session.post(
                TTS_URL,
                json=payload,
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
        log.info(f"Blocked user {user_id}")
        return

    log.info(f"Text [{user_id}]: {text[:80]}")
    await send_typing(session, chat_id)

    try:
        reply = await call_brain([{"role": "user", "content": text}])
        await tg(session, "sendMessage", chat_id=chat_id, text=reply)
    except Exception as e:
        log.error(f"Brain error: {e}")
        await tg(session, "sendMessage", chat_id=chat_id, text=f"⚠️ {e}")


async def on_photo(session: aiohttp.ClientSession, msg: dict):
    user_id = msg["from"]["id"]
    chat_id = msg["chat"]["id"]
    caption = msg.get("caption") or "What's in this image?"

    if not allowed(user_id):
        return

    log.info(f"Photo [{user_id}]: {caption[:60]}")
    await send_typing(session, chat_id)

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
        reply = await call_brain(messages)
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
    await send_typing(session, chat_id)

    try:
        file_id    = msg["voice"]["file_id"]
        audio_data = await download_file(session, file_id)

        transcript = await transcribe(audio_data)
        if not transcript:
            await tg(session, "sendMessage", chat_id=chat_id,
                     text="⚠️ Couldn't transcribe audio — try speaking more clearly.")
            return

        log.info(f"Transcript: {transcript[:80]}")
        await tg(session, "sendMessage", chat_id=chat_id,
                 text=f"🎤 _{transcript}_", parse_mode="Markdown")

        reply = await call_brain([{"role": "user", "content": transcript}])

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


# ── Polling loop ──────────────────────────────────────────────────────────────

async def poll():
    if not TELEGRAM_BOT_TOKEN:
        log.error("TELEGRAM_BOT_TOKEN not set — exiting.")
        sys.exit(1)

    offset = 0
    log.info(f"Bot starting. Allowed users: {ALLOWED_IDS or 'all'}")

    async with aiohttp.ClientSession() as session:
        # Confirm token works
        me = await tg(session, "getMe")
        if not me.get("ok"):
            log.error(f"Bad token: {me}")
            sys.exit(1)
        log.info(f"Logged in as @{me['result']['username']}")

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
