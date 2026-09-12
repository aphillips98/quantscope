"""Common interface for inference backends used by benchmark runners."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class AdapterCapabilities:
    generation: bool = True
    log_likelihood: bool = False


class ModelAdapter(ABC):
    """A loaded model capable of deterministic option selection."""

    capabilities: AdapterCapabilities

    @abstractmethod
    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        """Generate a short completion for exact-match benchmark scoring."""

    def score_options(self, prompt: str, options: Sequence[str]) -> list[float]:
        """Return one conditional log-likelihood per option when supported."""
        raise NotImplementedError("This backend does not provide option log-likelihoods")

    def close(self) -> None:
        """Release backend resources; subclasses may override."""