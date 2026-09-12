"""Stable JSON and CSV artifacts for standalone benchmark campaigns."""

from __future__ import annotations

import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


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


def write_run_artifacts(
    output_dir: Path,
    metadata: dict[str, Any],
    results: Iterable[SampleResult],
    capture_predictions: bool,
) -> None:
    """Write atomically replaceable aggregates plus optional per-sample JSONL."""
    output_dir.mkdir(parents=True, exist_ok=True)
    result_list = list(results)
    _write_json(output_dir / "metadata.json", metadata)
    _write_csv(output_dir / "samples.csv", result_list)
    _write_csv(output_dir / "summary.csv", _summaries(result_list))
    if capture_predictions:
        _write_jsonl(output_dir / "predictions.jsonl", result_list)


def _summaries(results: list[SampleResult]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], list[SampleResult]] = {}
    for result in results:
        grouped.setdefault(
            (result.benchmark, result.task, result.scoring_method), []
        ).append(result)
    return [
        {
            "benchmark": benchmark,
            "task": task,
            "scoring_method": scoring_method,
            "samples": len(group),
            "correct": sum(item.correct for item in group),
            "accuracy": sum(item.correct for item in group) / len(group),
            "mean_latency_seconds": sum(item.latency_seconds for item in group) / len(group),
        }
        for (benchmark, task, scoring_method), group in sorted(grouped.items())
    ]


def _write_json(path: Path, contents: dict[str, Any]) -> None:
    path.write_text(json.dumps(contents, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_jsonl(path: Path, results: list[SampleResult]) -> None:
    with path.open("w", encoding="utf-8") as output:
        for result in results:
            output.write(json.dumps(asdict(result), sort_keys=True) + "\n")


def _write_csv(path: Path, rows: Iterable[SampleResult | dict[str, Any]]) -> None:
    row_list = [asdict(row) if isinstance(row, SampleResult) else row for row in rows]
    if not row_list:
        return
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=list(row_list[0]))
        writer.writeheader()
        writer.writerows(row_list)