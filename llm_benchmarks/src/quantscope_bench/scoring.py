"""Deterministic scoring for multiple-choice benchmark samples."""

from __future__ import annotations

import re
from collections.abc import Sequence

_CHOICE_PATTERN = re.compile(r"\b([A-D])\b", re.IGNORECASE)


def normalize_choice(response: str) -> str | None:
    """Extract a standalone A-D response without accepting arbitrary prose."""
    match = _CHOICE_PATTERN.search(response.strip())
    return match.group(1).upper() if match else None


def exact_match(response: str, expected_choice: str) -> bool:
    return normalize_choice(response) == expected_choice.strip().upper()


def best_option(scores: Sequence[float]) -> int:
    if not scores:
        raise ValueError("Option scores must not be empty")
    return max(range(len(scores)), key=scores.__getitem__)