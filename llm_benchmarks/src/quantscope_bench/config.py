"""Configuration loading and pre-flight validation for benchmark campaigns."""

from __future__ import annotations

from dataclasses import dataclass
import logging
from pathlib import Path
from typing import Any

import yaml

SUPPORTED_BACKENDS = frozenset({"llamacpp", "transformers", "vllm"})
SUPPORTED_BENCHMARKS = frozenset({"mmlu", "hellaswag"})
SUPPORTED_SCORING = frozenset({"exact_match", "log_likelihood"})
SHOT_LIMITS = {"mmlu": 5, "hellaswag": 15}
LOGGER = logging.getLogger(__name__)


class ConfigurationError(ValueError):
    """Raised when a configuration cannot describe a valid run."""


@dataclass(frozen=True)
class ValidatedCampaign:
    model_name: str
    backend: str
    profile_name: str
    benchmark_names: tuple[str, ...]
    scoring_methods: tuple[str, ...]


def load_yaml(path: Path) -> dict[str, Any]:
    """Load a YAML mapping and give an actionable error for malformed input."""
    LOGGER.debug("Loading YAML configuration from %s", path)
    try:
        contents = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ConfigurationError(f"Cannot read {path}: {error.strerror}") from error
    except yaml.YAMLError as error:
        raise ConfigurationError(f"Invalid YAML in {path}: {error}") from error

    if not isinstance(contents, dict):
        raise ConfigurationError(f"{path} must contain a top-level mapping")
    LOGGER.debug("Loaded YAML configuration from %s", path)
    return contents


def validate_campaign(
    models: dict[str, Any], campaign: dict[str, Any], hardware: dict[str, Any]
) -> ValidatedCampaign:
    """Validate cross-file references and benchmark invariants before execution."""
    LOGGER.debug("Validating campaign configuration")
    _require_version(models, "models")
    _require_version(campaign, "campaign")
    _require_version(hardware, "hardware")

    model_name = _required_string(campaign, "model", "campaign")
    profile_name = _required_string(campaign, "hardware_profile", "campaign")
    model_entries = _required_mapping(models, "models", "models")
    profile_entries = _required_mapping(hardware, "profiles", "hardware")

    model = _named_mapping(model_entries, model_name, "model")
    _named_mapping(profile_entries, profile_name, "hardware profile")
    backend = _required_string(model, "backend", f"model {model_name}")
    if backend not in SUPPORTED_BACKENDS:
        raise ConfigurationError(
            f"model {model_name} has unsupported backend {backend!r}; "
            f"expected one of {sorted(SUPPORTED_BACKENDS)}"
        )

    sources = [key for key in ("local_path", "hf_id") if model.get(key)]
    if len(sources) != 1:
        raise ConfigurationError(
            f"model {model_name} must specify exactly one of local_path or hf_id"
        )

    scoring_methods = _string_list(campaign, "scoring", "campaign")
    invalid_scoring = set(scoring_methods) - SUPPORTED_SCORING
    if invalid_scoring:
        raise ConfigurationError(f"Unsupported scoring methods: {sorted(invalid_scoring)}")

    benchmark_entries = _required_mapping(campaign, "benchmarks", "campaign")
    if not benchmark_entries:
        raise ConfigurationError("campaign benchmarks must not be empty")
    benchmark_names: list[str] = []
    for benchmark_name, options in benchmark_entries.items():
        if benchmark_name not in SUPPORTED_BENCHMARKS:
            raise ConfigurationError(f"Unsupported benchmark: {benchmark_name}")
        if not isinstance(options, dict):
            raise ConfigurationError(f"benchmark {benchmark_name} options must be a mapping")
        shots = options.get("shots", 0)
        if not isinstance(shots, int) or isinstance(shots, bool) or shots < 0:
            raise ConfigurationError(f"benchmark {benchmark_name} shots must be a non-negative integer")
        if shots > SHOT_LIMITS[benchmark_name]:
            raise ConfigurationError(
                f"benchmark {benchmark_name} allows at most "
                f"{SHOT_LIMITS[benchmark_name]} shots, got {shots}"
            )
        benchmark_names.append(benchmark_name)

    repetitions = campaign.get("repetitions", 1)
    if not isinstance(repetitions, int) or isinstance(repetitions, bool) or repetitions < 1:
        raise ConfigurationError("campaign repetitions must be a positive integer")

    validated = ValidatedCampaign(
        model_name=model_name,
        backend=backend,
        profile_name=profile_name,
        benchmark_names=tuple(benchmark_names),
        scoring_methods=tuple(scoring_methods),
    )
    LOGGER.debug(
        "Campaign validation complete: model=%s backend=%s benchmarks=%s",
        validated.model_name,
        validated.backend,
        ",".join(validated.benchmark_names),
    )
    return validated


def get_model(models: dict[str, Any], model_name: str) -> dict[str, Any]:
    """Return a validated model declaration for runtime adapter creation."""
    return _named_mapping(_required_mapping(models, "models", "models"), model_name, "model")


def _require_version(document: dict[str, Any], name: str) -> None:
    if document.get("version") != 1:
        raise ConfigurationError(f"{name} version must be 1")


def _required_mapping(document: dict[str, Any], key: str, context: str) -> dict[str, Any]:
    value = document.get(key)
    if not isinstance(value, dict):
        raise ConfigurationError(f"{context} {key} must be a mapping")
    return value


def _named_mapping(entries: dict[str, Any], name: str, entry_type: str) -> dict[str, Any]:
    value = entries.get(name)
    if not isinstance(value, dict):
        raise ConfigurationError(f"Unknown {entry_type}: {name}")
    return value


def _required_string(document: dict[str, Any], key: str, context: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise ConfigurationError(f"{context} {key} must be a non-empty string")
    return value


def _string_list(document: dict[str, Any], key: str, context: str) -> list[str]:
    value = document.get(key)
    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise ConfigurationError(f"{context} {key} must be a non-empty list of strings")
    return value