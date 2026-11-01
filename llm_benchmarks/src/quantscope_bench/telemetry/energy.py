"""Energy source selection with explicit quality and availability reporting."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class EnergyReading:
    source: str
    joules: float | None
    available: bool
    detail: str | None = None


class EnergySource(Protocol):
    name: str

    def available(self) -> bool:
        """Return whether this source can currently provide an energy total."""

    def read_joules(self) -> float:
        """Read cumulative energy in joules."""


class RaplEnergySource:
    name = "rapl"

    def __init__(self, root: Path = Path("/sys/class/powercap")) -> None:
        self._paths = tuple(root.glob("intel-rapl*/energy_uj")) + tuple(
            root.glob("intel-rapl:*/*/energy_uj")
        )
        LOGGER.debug("Discovered %d RAPL energy counter(s) under %s", len(self._paths), root)

    def available(self) -> bool:
        return bool(self._paths) and all(path.is_file() for path in self._paths)

    def read_joules(self) -> float:
        joules = sum(int(path.read_text(encoding="utf-8").strip()) for path in self._paths) / 1_000_000
        LOGGER.debug("RAPL cumulative reading: %.3f J", joules)
        return joules


class UnavailableEnergySource:
    name = "unavailable"

    def available(self) -> bool:
        return False

    def read_joules(self) -> float:
        raise RuntimeError("No energy source is available")


def select_energy_source(sources: tuple[EnergySource, ...]) -> EnergySource:
    """Select the first available source in priority order."""
    selected = next((source for source in sources if source.available()), UnavailableEnergySource())
    LOGGER.debug("Selected energy source %s from %d candidate(s)", selected.name, len(sources))
    return selected


def delta_reading(source: EnergySource, start_joules: float | None, end_joules: float | None) -> EnergyReading:
    """Create a structured interval result, including unavailable measurements."""
    LOGGER.debug(
        "Computing energy delta for source %s: start=%s end=%s", source.name, start_joules, end_joules
    )
    if not source.available() or start_joules is None or end_joules is None:
        return EnergyReading(source=source.name, joules=None, available=False)
    if end_joules < start_joules:
        return EnergyReading(
            source=source.name,
            joules=None,
            available=False,
            detail="cumulative counter decreased; counter rollover handling is not configured",
        )
    return EnergyReading(source=source.name, joules=end_joules - start_joules, available=True)