"""Deterministic scoring for multiple-choice benchmark samples."""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence

_CHOICE_PATTERN = re.compile(r"\b([A-D])\b", re.IGNORECASE)
LOGGER = logging.getLogger(__name__)


def normalize_choice(response: str) -> str | None:
    """Extract a standalone A-D response without accepting arbitrary prose."""
    match = _CHOICE_PATTERN.search(response.strip())
    choice = match.group(1).upper() if match else None
    LOGGER.debug("Normalized response %r to choice %s", response, choice)
    return choice


def exact_match(response: str, expected_choice: str) -> bool:
    matched = normalize_choice(response) == expected_choice.strip().upper()
    LOGGER.debug("Exact match against expected %s: %s", expected_choice, matched)
    return matched


def best_option(scores: Sequence[float]) -> int:
    if not scores:
        raise ValueError("Option scores must not be empty")
    winner = max(range(len(scores)), key=scores.__getitem__)
    LOGGER.debug("Best option among %d scores is index %d (%.4f)", len(scores), winner, scores[winner])
    return winner