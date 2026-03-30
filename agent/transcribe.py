#!/usr/bin/env python3
"""
Transcribe an audio file (OGG/MP3/WAV) using the local ASR server at ws://localhost:8002.
Usage: python3 transcribe.py <file_path_or_url>
Output: transcript text on stdout, or error on stderr with exit code 1.
"""

import asyncio
import json
import subprocess
import sys
import tempfile
import os


ASR_WS = os.environ.get("ASR_WS", "ws://localhost:8002")


def to_pcm(input_path: str) -> bytes:
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", input_path,
         "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1"],
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode()[:300])
    return result.stdout


async def transcribe(pcm: bytes) -> str:
    import websockets
    async with websockets.connect(ASR_WS, ping_interval=None) as ws:
        chunk = 4096
        for i in range(0, len(pcm), chunk):
            await ws.send(pcm[i:i + chunk])
        await ws.send(b"")
        async for raw in ws:
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode()
            msg = json.loads(raw)
            if msg.get("type") in ("final", "transcript"):
                return msg.get("text", msg.get("transcript", "")).strip()
    return ""


async def main():
    if len(sys.argv) < 2:
        print("Usage: transcribe.py <file_path_or_url>", file=sys.stderr)
        sys.exit(1)

    src = sys.argv[1]

    # Download if URL
    if src.startswith("http://") or src.startswith("https://"):
        import urllib.request
        suffix = ".ogg" if "ogg" in src else ".mp3"
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
        urllib.request.urlretrieve(src, tmp.name)
        src = tmp.name

    try:
        pcm = to_pcm(src)
        text = await transcribe(pcm)
        if text:
            print(text)
        else:
            print("(no transcript)", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
