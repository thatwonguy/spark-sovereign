#!/usr/bin/env python3
"""
Session curator — extracts durable lessons from agent session and stores in pgvector.
Run at end of each session with the session summary.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from agent.log import get_logger
from agent.memory import store_lesson, curate_session

log = get_logger(__name__)


def main():
    """
    Usage:
        python3 scripts/curate_session.py --summary "session summary text" --domain "my-domain"
        cat session_log.jsonl | python3 scripts/curate_session.py --domain "my-domain"
    """
    import argparse
    
    parser = argparse.ArgumentParser(description="Curate lessons from agent session")
    parser.add_argument("--summary", "-s", help="Session summary text")
    parser.add_argument("--domain", "-d", required=True, help="Domain category for lessons")
    parser.add_argument("--file", "-f", help="File with session log/summary")
    
    args = parser.parse_args()
    
    if not args.summary and not args.file:
        parser.print_help()
        sys.exit(1)
    
    if args.file:
        with open(args.file) as f:
            summary = f.read()
    else:
        summary = args.summary
    
    log.info(f"Curating session | domain={args.domain} summary_len={len(summary)}")
    
    stored = curate_session(summary, args.domain)
    
    if stored:
        log.info(f"Stored {len(stored)} lessons:")
        for lesson in stored:
            log.info("  [%s] %s (importance=%.1f) %s",
                    lesson["outcome"], lesson["content"][:50],
                    lesson["importance"], lesson["domain"])
    else:
        log.info("No durable lessons found")
    
    print(f"Curated {len(stored)} lessons")


if __name__ == "__main__":
    main()
