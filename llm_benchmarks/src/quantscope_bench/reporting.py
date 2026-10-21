"""Stable JSON and CSV artifacts for standalone benchmark campaigns."""

from __future__ import annotations

import csv
import json
import logging
import math
import statistics
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

LOGGER = logging.getLogger(__name__)


def performance_summary(
    requests: list[dict[str, Any]], runtime_seconds: float
) -> dict[str, Any]:
    """Summarize successful calls, using only measured positive token timings."""
    latencies = sorted(request["latency_seconds"] for request in requests)
    summary: dict[str, Any] = {
        "requests": len(requests),
        "benchmark_runtime_seconds": runtime_seconds,
        "total_request_latency_seconds": sum(latencies),
        "mean_latency_seconds": statistics.mean(latencies) if latencies else None,
        "median_latency_seconds": statistics.median(latencies) if latencies else None,
        "p95_latency_seconds": latencies[math.ceil(len(latencies) * 0.95) - 1] if latencies else None,
    }
    for prefix, token_key, time_key in (
        ("prompt", "prompt_tokens", "prompt_seconds"),
        ("generation", "generated_tokens", "generation_seconds"),
    ):
        counts = [request[token_key] for request in requests if request[token_key] is not None]
        measured = [
            request for request in requests
            if request[token_key] is not None and request[time_key] is not None and request[time_key] > 0
        ]
        summary[f"total_{token_key}"] = sum(counts) if counts else None
        summary[f"{prefix}_timed_requests"] = len(measured)
        summary[f"{prefix}_tokens_per_second"] = (
            sum(request[token_key] for request in measured) / sum(request[time_key] for request in measured)
            if measured else None
        )
    return summary


def write_performance_artifacts(
    output_dir: Path,
    requests: list[dict[str, Any]],
    summaries: list[dict[str, Any]],
    gpu_samples: list[dict[str, Any]],
) -> None:
    """Write separate performance files without altering accuracy artifacts."""
    output_dir.mkdir(parents=True, exist_ok=True)
    _write_csv(output_dir / "performance_requests.csv", requests, [
        "run_id", "model_name", "request_id", "backend", "latency_seconds",
        "prompt_tokens", "generated_tokens", "prompt_seconds", "generation_seconds",
    ] if not requests else None)
    _write_csv(output_dir / "performance_summary.csv", summaries)
    _write_csv(output_dir / "gpu_samples.csv", gpu_samples, [
        "run_id", "model_name", "timestamp_seconds", "gpu_uuid", "power_watts", "memory_used_mb",
    ] if not gpu_samples else None)


@dataclass(frozen=True)
class SampleResult:
    run_id: str
    benchmark: str
    task: str
    sample_id: str
    scoring_method: str
    expected_choice: str
    predicted_choice: str | None
    correct: bool
    latency_seconds: float
    raw_response: str | None = None
    option_scores: tuple[float, ...] | None = None
    model_name: str = ""


def write_run_artifacts(
    output_dir: Path,
    metadata: dict[str, Any],
    results: Iterable[SampleResult],
    capture_predictions: bool,
) -> None:
    """Write atomically replaceable aggregates plus optional per-sample JSONL."""
    output_dir.mkdir(parents=True, exist_ok=True)
    result_list = list(results)
    LOGGER.debug("Writing artifacts for %d result rows", len(result_list))
    _write_json(output_dir / "metadata.json", metadata)
    _write_csv(output_dir / "samples.csv", result_list)
    _write_csv(output_dir / "summary.csv", _summaries(result_list))
    if capture_predictions:
        _write_jsonl(output_dir / "predictions.jsonl", result_list)
    LOGGER.info("Wrote benchmark artifacts to %s", output_dir)


def _summaries(results: list[SampleResult]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str, str], list[SampleResult]] = {}
    for result in results:
        grouped.setdefault(
            (result.model_name, result.benchmark, result.task, result.scoring_method), []
        ).append(result)
    return [
        {
            "model_name": model_name,
            "benchmark": benchmark,
            "task": task,
            "scoring_method": scoring_method,
            "samples": len(group),
            "correct": sum(item.correct for item in group),
            "accuracy": sum(item.correct for item in group) / len(group),
            "mean_latency_seconds": sum(item.latency_seconds for item in group) / len(group),
        }
        for (model_name, benchmark, task, scoring_method), group in sorted(grouped.items())
    ]


def _write_json(path: Path, contents: dict[str, Any]) -> None:
    path.write_text(json.dumps(contents, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_jsonl(path: Path, results: list[SampleResult]) -> None:
    with path.open("w", encoding="utf-8") as output:
        for result in results:
            output.write(json.dumps(asdict(result), sort_keys=True) + "\n")


def _write_csv(
    path: Path, rows: Iterable[SampleResult | dict[str, Any]], fieldnames: list[str] | None = None
) -> None:
    row_list = [asdict(row) if isinstance(row, SampleResult) else row for row in rows]
    if not row_list and fieldnames is None:
        return
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames if fieldnames is not None else list(row_list[0]))
        writer.writeheader()
        writer.writerows(row_list)