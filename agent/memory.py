"""
agent/memory.py — spark-sovereign continuous learning memory layer

Provides:
  store_lesson()      — save a durable lesson from an agent session
  store_web_result()  — cache a SearXNG result for future recall
  confirm_web_result()— mark a web result as verified (answer was correct)
  recall()            — retrieve relevant lessons + web results for a task
  curate_session()    — end-of-session: extract + store lessons via Nano

All embeddings use the local nomic-embed-text-v1.5 model (384-dim).
Model path sourced from config/models.yml — swap embedding model there.
"""

import json
import os
import re
import sys
from pathlib import Path
from typing import Optional

import psycopg2
import requests
import yaml
from sentence_transformers import SentenceTransformer

from agent.log import get_logger

log = get_logger(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).parent.parent

def _load_config() -> dict:
    with open(_REPO_ROOT / "config" / "models.yml") as f:
        return yaml.safe_load(f)

_cfg = _load_config()
_embed_path  = _cfg["embeddings"]["local_path"]
_embed_dims  = _cfg["embeddings"]["dimensions"]
_nano_port   = _cfg["subagent"]["port"]
_nano_name   = _cfg["subagent"]["served_name"]
_pg_password = os.environ.get("POSTGRES_PASSWORD", "localonly")
_pg_db       = os.environ.get("POSTGRES_DB", "agent_memory")
_pg_dsn      = f"postgresql://postgres:{_pg_password}@localhost/{_pg_db}"

# ---------------------------------------------------------------------------
# Lazy singletons
# ---------------------------------------------------------------------------
_embed_model: Optional[SentenceTransformer] = None
_conn: Optional[psycopg2.extensions.connection] = None


def _get_embed_model() -> SentenceTransformer:
    global _embed_model
    if _embed_model is None:
        log.info("loading embed model: %s", _embed_path)
        _embed_model = SentenceTransformer(_embed_path, trust_remote_code=True)
        log.info("embed model ready (dim=%d)", _embed_dims)
    return _embed_model


def _get_conn() -> psycopg2.extensions.connection:
    global _conn
    if _conn is None or _conn.closed:
        log.debug("opening pgvector connection: %s", _pg_dsn.split("@")[-1])
        _conn = psycopg2.connect(_pg_dsn)
    return _conn


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

def embed(text: str) -> list:
    """Encode text to a 384-dim normalized vector (cosine-ready)."""
    model = _get_embed_model()
    return model.encode(text, normalize_embeddings=True).tolist()


# ---------------------------------------------------------------------------
# Write operations
# ---------------------------------------------------------------------------

def store_lesson(
    content: str,
    outcome: str,                          # 'success' | 'failure' | 'preference' | 'decision'
    domain: str,
    importance: float = 0.8,
    source: str = "agent",                 # 'agent' | 'web_search'
) -> int:
    """Store a durable lesson. Returns the new lesson ID."""
    conn = _get_conn()
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO lessons (content, outcome, domain, importance, embedding, source)
        VALUES (%s, %s, %s, %s, %s::vector, %s)
        RETURNING id
        """,
        (content, outcome, domain, importance, embed(content), source),
    )
    lesson_id = cur.fetchone()[0]
    conn.commit()
    log.info("lesson stored id=%d outcome=%s domain=%s importance=%.1f source=%s",
             lesson_id, outcome, domain, importance, source)
    return lesson_id


def store_web_result(
    query: str,
    result: str,
    url: str = "",
    verified: bool = False,
    confidence: float = 0.7,
) -> int:
    """Cache a SearXNG web result. Returns the new cache entry ID."""
    conn = _get_conn()
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO rag_cache (query, result, source_url, verified, confidence, embedding)
        VALUES (%s, %s, %s, %s, %s, %s::vector)
        RETURNING id
        """,
        (query, result, url, verified, confidence, embed(query + " " + result)),
    )
    entry_id = cur.fetchone()[0]
    conn.commit()
    log.info("web result stored id=%d verified=%s confidence=%.1f url=%s",
             entry_id, verified, confidence, url or "(none)")
    return entry_id


def confirm_web_result(result_id: int) -> None:
    """Mark a cached web result as verified (agent confirmed it was correct).
    Bumps confidence to 1.0 and increments use_count. Ranks highest in recall."""
    conn = _get_conn()
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE rag_cache
        SET verified = TRUE,
            confidence = 1.0,
            used_count = used_count + 1
        WHERE id = %s
        """,
        (result_id,),
    )
    conn.commit()
    log.info("web result confirmed id=%d -> verified=True confidence=1.0", result_id)


# ---------------------------------------------------------------------------
# Read operations
# ---------------------------------------------------------------------------

def recall(
    query: str,
    top_k: int = 5,
    domain: Optional[str] = None,
    verified_only: bool = False,
) -> tuple[list, list]:
    """Retrieve relevant lessons and web results for a task.

    Returns:
        (lessons, web_results)
        lessons     — list of (content, outcome, importance, source, score)
        web_results — list of (query, result, source_url, confidence, score)
    """
    vec = embed(query)
    conn = _get_conn()
    cur = conn.cursor()

    # Pull lessons — filter by domain if provided
    domain_filter = f"%{domain}%" if domain else None
    cur.execute(
        """
        SELECT content, outcome, importance, source,
               1 - (embedding <=> %s::vector) AS score
        FROM lessons
        WHERE (%s IS NULL OR domain ILIKE %s)
        ORDER BY embedding <=> %s::vector
        LIMIT %s
        """,
        (vec, domain_filter, domain_filter, vec, top_k),
    )
    lessons = cur.fetchall()

    # Pull web results — verified ones ranked higher
    cur.execute(
        """
        SELECT query, result, source_url, confidence,
               1 - (embedding <=> %s::vector) AS score
        FROM rag_cache
        WHERE (%s = FALSE OR verified = TRUE)
        ORDER BY (verified::int * 0.3) + (1 - (embedding <=> %s::vector)) DESC
        LIMIT %s
        """,
        (vec, verified_only, vec, top_k),
    )
    web_results = cur.fetchall()

    log.debug("recall: %d lessons, %d web results | query=%.50s domain=%s",
              len(lessons), len(web_results), query, domain)
    if lessons:
        for content, outcome, importance, source, score in lessons:
            log.debug("  lesson score=%.3f outcome=%s | %.60s", score, outcome, content)
    if web_results:
        for q, result, url, confidence, score in web_results:
            log.debug("  web score=%.3f verified_conf=%.1f | %.60s", score, confidence, result)

    return lessons, web_results


def recall_as_context(query: str, top_k: int = 5, domain: Optional[str] = None) -> str:
    """Convenience: return recall results as a formatted string for prompt injection."""
    lessons, web_results = recall(query, top_k=top_k, domain=domain)

    parts = []

    if lessons:
        parts.append("## Relevant lessons from past sessions")
        for content, outcome, importance, source, score in lessons:
            emoji = {"success": "✅", "failure": "❌", "preference": "⭐", "decision": "📌"}.get(outcome, "•")
            parts.append(f"{emoji} [{outcome}, importance={importance:.1f}] {content}")

    if web_results:
        parts.append("\n## Verified knowledge from web search")
        for q, result, url, confidence, score in web_results:
            parts.append(f"• (confidence={confidence:.1f}) {result}")
            if url:
                parts.append(f"  source: {url}")

    return "\n".join(parts) if parts else ""


# ---------------------------------------------------------------------------
# Session curation
# ---------------------------------------------------------------------------

def curate_session(session_summary: str, domain: str) -> list[dict]:
    """Run at end of each session. Uses Nano to extract durable lessons.

    Args:
        session_summary: Full text summary of the session (tool calls, outcomes, etc.)
        domain: The domain/category for tagging lessons (e.g. 'stripe', 'devops', 'python')

    Returns:
        List of stored lesson dicts.
    """
    prompt = f"""Extract ONLY durable lessons from this session. Return a JSON array.
Each item must have:
  "content":   string — the lesson itself (1-2 sentences, specific and actionable)
  "outcome":   "success" | "failure" | "preference" | "decision"
  "importance": float 0.0-1.0  (failures = 1.0, successes = 0.8, preferences = 0.6)

Rules:
  - Discard routine operations, intermediate steps, tool call noise
  - Keep: things that were surprising, that failed, that should never be repeated,
    confirmed best practices, and important decisions
  - Return [] if there are no durable lessons

Session summary:
{session_summary}

Return JSON only. No markdown fences, no explanation."""

    log.info("curating session | domain=%s summary_len=%d", domain, len(session_summary))
    try:
        resp = requests.post(
            f"http://localhost:{_nano_port}/v1/chat/completions",
            json={
                "model": _nano_name,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 2000,
                "temperature": 0.3,
            },
            timeout=60,
        )
        resp.raise_for_status()
        raw = resp.json()["choices"][0]["message"]["content"].strip()

        # Strip markdown fences if Nano wraps them anyway
        raw = re.sub(r"^```[a-z]*\n?", "", raw)
        raw = re.sub(r"\n?```$", "", raw)

        lesson_list = json.loads(raw)
        log.info("curation extracted %d lessons for domain=%s", len(lesson_list), domain)
        stored = []
        for item in lesson_list:
            lesson_id = store_lesson(
                content=item["content"],
                outcome=item["outcome"],
                domain=domain,
                importance=item.get("importance", 0.8),
                source="agent",
            )
            stored.append({**item, "id": lesson_id, "domain": domain})

        return stored

    except Exception as e:
        log.error("curate_session failed: %s", e, exc_info=True)
        return []


# ---------------------------------------------------------------------------
# CLI for quick inspection
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="spark-sovereign memory CLI")
    sub = parser.add_subparsers(dest="cmd")

    p_recall = sub.add_parser("recall", help="Recall relevant memories")
    p_recall.add_argument("query")
    p_recall.add_argument("--top-k", type=int, default=5)
    p_recall.add_argument("--domain", default=None)

    p_lesson = sub.add_parser("lesson", help="Store a lesson")
    p_lesson.add_argument("content")
    p_lesson.add_argument("--outcome", default="success",
                          choices=["success", "failure", "preference", "decision"])
    p_lesson.add_argument("--domain", default="general")
    p_lesson.add_argument("--importance", type=float, default=0.8)

    p_stats = sub.add_parser("stats", help="Print DB stats")

    args = parser.parse_args()

    if args.cmd == "recall":
        ctx = recall_as_context(args.query, top_k=args.top_k, domain=args.domain)
        print(ctx if ctx else "(no relevant memories found)")

    elif args.cmd == "lesson":
        lid = store_lesson(args.content, args.outcome, args.domain, args.importance)
        print(f"Stored lesson #{lid}")

    elif args.cmd == "stats":
        conn = _get_conn()
        cur = conn.cursor()
        cur.execute("SELECT outcome, COUNT(*) FROM lessons GROUP BY outcome ORDER BY outcome")
        rows = cur.fetchall()
        print("Lessons by outcome:")
        for outcome, count in rows:
            print(f"  {outcome}: {count}")
        cur.execute("SELECT COUNT(*), SUM(verified::int) FROM rag_cache")
        total, verified = cur.fetchone()
        print(f"\nWeb cache: {total} total, {verified or 0} verified")

    else:
        parser.print_help()
