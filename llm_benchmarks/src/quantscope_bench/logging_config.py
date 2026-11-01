"""Shared console logging configuration and level-specific colors."""

from __future__ import annotations

import logging
import os
import sys

LOG_LEVELS = ("CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG")
LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"
LEVEL_COLORS = {
    logging.DEBUG: "\033[36m",
    logging.INFO: "\033[32m",
    logging.WARNING: "\033[33m",
    logging.ERROR: "\033[31m",
    logging.CRITICAL: "\033[1;31m",
}
_RESET = "\033[0m"


class ColorFormatter(logging.Formatter):
    """Color formatted output without modifying the shared log record."""

    def __init__(self, use_color: bool = False) -> None:
        super().__init__(LOG_FORMAT)
        self.use_color = use_color

    def format(self, record: logging.LogRecord) -> str:
        message = super().format(record)
        color = LEVEL_COLORS.get(record.levelno) if self.use_color else None
        return f"{color}{message}{_RESET}" if color else message


def configure_logging(level_name: str) -> None:
    """Configure stderr logging, preserving existing handlers when embedded."""
    if level_name not in LOG_LEVELS:
        raise ValueError(f"Unsupported log level: {level_name!r}; expected one of {LOG_LEVELS}")
    handler = logging.StreamHandler(sys.stderr)
    use_color = (
        sys.stderr.isatty()
        and "NO_COLOR" not in os.environ
        and os.environ.get("TERM") != "dumb"
    )
    handler.setFormatter(ColorFormatter(use_color=use_color))
    logging.basicConfig(level=getattr(logging, level_name), handlers=[handler])
