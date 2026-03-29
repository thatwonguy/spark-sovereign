"""
agent/router.py — spark-sovereign model router

Priority order for every message:
  1. Explicit trigger word -> immediate route, no classification
  2. No trigger + AUTO_ROUTE=True -> Nano classifies the task (single token)
  3. No trigger + AUTO_ROUTE=False -> use current persistent mode

Modes (persistent until changed):
  FAST  — Nano (default). Images: Brain extracts -> text -> Nano responds.
  DEEP  — Brain 122B. Images: Brain handles directly.

Auto-classification:
  Nano receives the message with a tight classification prompt.
  Responds with a single token: "fast" or "deep".
  ~200-400ms overhead. Only runs when no explicit trigger detected.
  Nano self-selects deep only when it genuinely needs the larger model.

Explicit triggers:

  DEEP:  deep mode, /deep, thinking mode, /thinking,
         use the big model, use 122, full model, switch to deep

  FAST:  fast mode, /fast, quick mode, use nano,
         back to fast, switch to fast
"""

import requests

MODELS = {
    "nano": "http://localhost:8001/v1/nemotron-nano",
    "deep": "http://localhost:8000/v1/qwen35-122b",
}

DEEP_TRIGGERS = [
    "/deep", "/thinking",
    "deep mode", "thinking mode",
    "use the big model", "use 122",
    "full model", "switch to deep",
]

FAST_TRIGGERS = [
    "/fast", "fast mode", "quick mode",
    "use nano", "back to fast", "switch to fast",
]

# Resets to auto-classify (clears explicit session lock)
AUTO_TRIGGERS = ["/auto", "auto mode", "auto route"]

# Persistent session mode
_mode: str = "nano"

# True once user explicitly sets a mode — suppresses auto-classify for session.
# Reset to False by /auto, or at session start.
_user_locked: bool = False

# Set False to disable auto-classification entirely
AUTO_ROUTE: bool = True

_CLASSIFY_PROMPT = """\
You are a routing classifier. Decide whether this task needs the large 122B \
model (deep) or you can handle it well yourself (fast).

Choose DEEP only if the task genuinely requires:
- Vision or image understanding
- Novel hard multi-step reasoning across a large codebase
- Frontier-level architecture design across many files
- Overnight autonomous build tasks

Everything else — chat, email, coding tasks, sub-agents, tool calls, \
translation, summaries, quick questions — answer: fast

Reply with exactly one word: fast or deep

Task: {message}"""


def _classify(message: str) -> str:
    """Ask Nano to classify the task. Returns 'fast' or 'deep'."""
    try:
        resp = requests.post(
            f"{MODELS['nano']}/chat/completions",
            json={
                "model": "nemotron-nano",
                "messages": [
                    {"role": "user", "content": _CLASSIFY_PROMPT.format(message=message)}
                ],
                "max_tokens": 1,
                "temperature": 0.0,
            },
            timeout=10,
        )
        resp.raise_for_status()
        answer = resp.json()["choices"][0]["message"]["content"].strip().lower()
        return "deep" if answer.startswith("deep") else "fast"
    except Exception:
        # If classification fails for any reason, stay on current mode
        return _mode


def route(message: str, has_image: bool = False) -> dict:
    """Route a message. Returns routing decision dict.

    Keys:
        mode        "nano" | "deep"    current persistent mode after routing
        classified  True if auto-classification was used
        clean_msg   Message with trigger flags stripped
        vision_step True if caller should run two-step vision pipeline
        model_url   Endpoint for the final LLM call
    """
    global _mode, _user_locked
    msg_lower = message.lower().strip()

    # ── 1. /auto — release session lock, re-enable auto-classify ────────────
    for trigger in AUTO_TRIGGERS:
        if trigger in msg_lower:
            _user_locked = False
            _mode = "nano"
            clean = msg_lower.replace(trigger, "").strip()
            return _decision("nano", clean or message, classified=False,
                             has_image=has_image)

    # ── 2. Explicit mode triggers — lock session to this mode ────────────────
    #    /deep at session start -> stays deep all session until user changes it
    for trigger in DEEP_TRIGGERS:
        if trigger in msg_lower:
            _mode = "deep"
            _user_locked = True          # suppress auto-classify for session
            clean = msg_lower.replace(trigger, "").strip()
            return _decision("deep", clean or message, classified=False,
                             has_image=has_image)

    for trigger in FAST_TRIGGERS:
        if trigger in msg_lower:
            _mode = "nano"
            _user_locked = True          # explicit fast lock — no auto-switching
            clean = msg_lower.replace(trigger, "").strip()
            return _decision("nano", clean or message, classified=False,
                             has_image=has_image)

    # ── 3. Auto-classification — only if user hasn't locked a mode ───────────
    if AUTO_ROUTE and not _user_locked:
        decided = _classify(message)
        # Note: auto-classify does NOT set _user_locked — it floats per message
        return _decision(decided, message, classified=True, has_image=has_image)

    # ── 4. Fallback — honour locked session mode ─────────────────────────────
    return _decision(_mode, message, classified=False, has_image=has_image)


def _decision(mode: str, clean_msg: str, classified: bool,
              has_image: bool) -> dict:
    """Build the routing decision dict."""
    if mode == "deep":
        # Deep mode: Brain handles everything directly (images too)
        return {
            "mode": "deep",
            "classified": classified,
            "clean_msg": clean_msg,
            "vision_step": False,
            "model_url": MODELS["deep"],
        }
    else:
        # Fast mode: Nano responds. Images go through two-step pipeline.
        return {
            "mode": "nano",
            "classified": classified,
            "clean_msg": clean_msg,
            "vision_step": has_image,
            "model_url": MODELS["nano"],
        }


def handle_vision(image_b64: str, user_question: str) -> str:
    """Two-step vision pipeline — used only in fast mode.

    Step 1: Brain parses image -> thorough text description.
    Step 2: Nano answers user question using that description.
    """
    brain_resp = requests.post(
        f"{MODELS['deep']}/chat/completions",
        json={
            "model": "qwen35-122b",
            "messages": [{
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                    {
                        "type": "text",
                        "text": (
                            "Describe everything in this image with maximum detail. "
                            "Include all visible text, code, error messages, layout, "
                            "colors, objects, diagrams, numbers, and any other detail "
                            "a text-only model would need to fully understand it."
                        ),
                    },
                ],
            }],
            "max_tokens": 1024,
            "temperature": 0.1,
        },
        timeout=60,
    )
    brain_resp.raise_for_status()
    description = brain_resp.json()["choices"][0]["message"]["content"]

    nano_resp = requests.post(
        f"{MODELS['nano']}/chat/completions",
        json={
            "model": "nemotron-nano",
            "messages": [
                {
                    "role": "system",
                    "content": f"The user sent an image. Full description:\n\n{description}",
                },
                {
                    "role": "user",
                    "content": user_question or "What do you see?",
                },
            ],
            "max_tokens": 2048,
            "temperature": 0.7,
        },
        timeout=60,
    )
    nano_resp.raise_for_status()
    return nano_resp.json()["choices"][0]["message"]["content"]


def current_mode() -> str:
    return _mode


def is_locked() -> bool:
    """True if the user has explicitly set a session mode."""
    return _user_locked


def force_mode(mode: str) -> None:
    global _mode, _user_locked
    if mode not in MODELS:
        raise ValueError(f"Unknown mode: '{mode}'. Choose: {list(MODELS)}")
    _mode = mode
    _user_locked = True


def reset_session() -> None:
    """Call at the start of a new session to clear any previous lock."""
    global _mode, _user_locked
    _mode = "nano"
    _user_locked = False


# ---------------------------------------------------------------------------
# CLI test — runs without live models (classification step skipped)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    AUTO_ROUTE = False   # disable live calls for offline test

    def sep(label):
        print(f"\n  -- {label}")

    print(f"{'Message':<46} {'Img':<5} {'Mode':<6} {'Lock':<5} {'Auto':<5} {'Vision':<7}")
    print("-" * 85)

    sep("Session A: /deep at start — stays deep all session, no auto-switching")
    reset_session()
    for msg, img in [
        ("/deep",                                        False),  # lock=True, deep
        ("Write the Stripe billing module",              False),  # locked deep, no classify
        ("Now write tests",                              False),  # still deep
        ("Quick — what time is it",                      False),  # still deep (locked)
        ("Send image mid deep session",                  True),   # deep+image, direct
    ]:
        d = route(msg, has_image=img)
        print(f"  {msg:<44} {str(img):<5} {d['mode']:<6} {str(_user_locked):<5} "
              f"{str(d['classified']):<5} {str(d['vision_step']):<7}")

    sep("Mid-session switch to fast, then back")
    for msg, img in [
        ("fast mode",                                    False),  # lock=True, nano
        ("Quick reply",                                  False),  # locked nano
        ("thinking mode",                                False),  # lock=True, deep
        ("Hard reasoning",                               False),  # locked deep
    ]:
        d = route(msg, has_image=img)
        print(f"  {msg:<44} {str(img):<5} {d['mode']:<6} {str(_user_locked):<5} "
              f"{str(d['classified']):<5} {str(d['vision_step']):<7}")

    sep("Session B: no explicit mode — auto-classify would run (shown as nano fallback here)")
    reset_session()
    for msg, img in [
        ("Hey what's up",                                False),  # no lock, auto
        ("Image in auto mode",                           True),   # no lock, fast+image
        ("/auto",                                        False),  # resets lock
    ]:
        d = route(msg, has_image=img)
        print(f"  {msg:<44} {str(img):<5} {d['mode']:<6} {str(_user_locked):<5} "
              f"{str(d['classified']):<5} {str(d['vision_step']):<7}")

    print()
    print("  Lock=True  -> user explicitly set this mode, auto-classify suppressed")
    print("  Lock=False -> auto-classify runs per message (or /auto resets it)")
