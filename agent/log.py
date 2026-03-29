"""
agent/log.py — shared logger for spark-sovereign

Usage:
    from agent.log import get_logger
    log = get_logger(__name__)
    log.info("routed to %s", model)
    log.debug("vision_step=%s", True)

Outputs to:
    Console  — INFO and above (coloured by level)
    Log file — DEBUG and above (full detail, ~/.spark-sovereign/spark.log)

Log levels:
    DEBUG   — detailed flow (routing path, recall scores, token counts)
    INFO    — key decisions (mode switch, lesson stored, model called)
    WARNING — fallbacks, retries, partial failures
    ERROR   — hard failures with tracebacks

Set LOG_LEVEL env var to override, e.g.: LOG_LEVEL=DEBUG
"""

import logging
import os
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
_LOG_DIR = Path(os.environ.get("SPARK_LOG_DIR", Path.home() / ".spark-sovereign" / "logs"))
_LOG_FILE = _LOG_DIR / "spark.log"
_CONSOLE_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
_FILE_LEVEL = "DEBUG"
_MAX_BYTES = 5 * 1024 * 1024   # 5MB per file
_BACKUP_COUNT = 3               # keep spark.log, spark.log.1, spark.log.2

# ---------------------------------------------------------------------------
# Formatters
# ---------------------------------------------------------------------------
_FILE_FMT = logging.Formatter(
    fmt="%(asctime)s  %(levelname)-7s  %(name)-20s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

# Console: shorter, with ANSI colour by level
_LEVEL_COLORS = {
    "DEBUG":    "\033[90m",   # grey
    "INFO":     "\033[36m",   # cyan
    "WARNING":  "\033[33m",   # yellow
    "ERROR":    "\033[31m",   # red
    "CRITICAL": "\033[35m",   # magenta
}
_RESET = "\033[0m"

class _ColorFormatter(logging.Formatter):
    def format(self, record):
        color = _LEVEL_COLORS.get(record.levelname, "")
        record.levelname = f"{color}{record.levelname:<7}{_RESET}"
        return super().format(record)

_CONSOLE_FMT = _ColorFormatter(
    fmt="%(asctime)s  %(levelname)s  %(name)-18s  %(message)s",
    datefmt="%H:%M:%S",
)

# ---------------------------------------------------------------------------
# Root handler setup (runs once on first import)
# ---------------------------------------------------------------------------
_configured = False

def _configure():
    global _configured
    if _configured:
        return
    _configured = True

    root = logging.getLogger("spark")
    root.setLevel(logging.DEBUG)          # handlers filter independently
    root.propagate = False

    # Console handler
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(getattr(logging, _CONSOLE_LEVEL, logging.INFO))
    ch.setFormatter(_CONSOLE_FMT)
    root.addHandler(ch)

    # File handler — rotating, full DEBUG
    try:
        _LOG_DIR.mkdir(parents=True, exist_ok=True)
        fh = RotatingFileHandler(
            _LOG_FILE,
            maxBytes=_MAX_BYTES,
            backupCount=_BACKUP_COUNT,
            encoding="utf-8",
        )
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(_FILE_FMT)
        root.addHandler(fh)
    except OSError as e:
        root.warning("Could not open log file %s: %s", _LOG_FILE, e)


def get_logger(name: str) -> logging.Logger:
    """Return a child logger under the 'spark' namespace.

    Args:
        name: typically __name__ of the calling module.
              'agent.router' becomes 'spark.agent.router'
    """
    _configure()
    # Strip leading 'agent.' for cleaner names in output
    short = name.replace("agent.", "").replace("__main__", "cli")
    return logging.getLogger(f"spark.{short}")


# ---------------------------------------------------------------------------
# Convenience: log file path for check_stack.sh
# ---------------------------------------------------------------------------
LOG_FILE = _LOG_FILE
