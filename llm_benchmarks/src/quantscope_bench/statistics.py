"""Additive repetition-level statistics; never modify raw measurements."""
from __future__ import annotations
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any
from quantscope_bench.reporting import SampleResult, _summaries


def _number(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _aggregate(rows: list[dict[str, Any]], keys: tuple[str, ...], metrics: tuple[str, ...]) -> list[dict[str, Any]]:
    groups = defaultdict(list)
    for row in rows:
        groups[tuple(row.get(k, "") for k in keys)].append(row)
    output = []
    for identity, group in sorted(groups.items()):
        run_ids = [str(row.get("run_id", "")) for row in group]
        if len(run_ids) != len(set(run_ids)):
            raise ValueError(f"Duplicate repetition in statistical group: {identity}")
        for metric in metrics:
            values = [_number(row.get(metric)) for row in group]
            values = [v for v in values if v is not None]
            n = len(values)
            mean = statistics.mean(values) if n else None
            sd = statistics.stdev(values) if n > 1 else None
            cv = (100 * sd / abs(mean)) if sd is not None and mean != 0 else None
            output.append({**dict(zip(keys, identity)), "metric": metric,
                           "n_repetitions": len(group), "n_valid": n,
                           "mean": mean, "stddev_sample": sd, "cv_percent": cv,
                           "min": min(values) if n else None,
                           "max": max(values) if n else None})
    return output


def _csv(path: Path, rows: list[dict[str, Any]], keys: tuple[str, ...]) -> None:
    fields = [*keys, "metric", "n_repetitions", "n_valid", "mean", "stddev_sample", "cv_percent", "min", "max"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_repetition_statistics(output_dir: Path, results: list[SampleResult],
                                performance: list[dict[str, Any]],
                                energy: list[dict[str, Any]]) -> None:
    """Create three independent CSVs. SD is sample SD (ddof=1); CV is percent.

    Missing/nonfinite measurements are excluded per metric, never replaced by zero.
    Accuracy is aggregated across repetitions of the *same task* (not questions).
    The GPU energy estimate is device-wide, not attributable to the process.
    """
    accuracy_keys = ("model_name", "benchmark", "task", "scoring_method")
    performance_keys = ("model_name",)
    energy_keys = ("model_name", "benchmark", "gpu_uuid")
    accuracy = _aggregate(_summaries(results), accuracy_keys, ("accuracy",))
    perf = _aggregate(performance, performance_keys,
        ("benchmark_runtime_seconds", "mean_latency_seconds", "p95_latency_seconds",
         "prompt_tokens_per_second", "generation_tokens_per_second",
         "gpu_energy_joules_estimated", "mean_gpu_power_watts_total"))
    # Exclude incomplete coverage: an incomplete energy estimate must not
    # silently contribute to the average.
    usable_energy = [row for row in energy if row.get("coverage_complete") is True
                     or str(row.get("coverage_complete", "")).lower() == "true"]
    energy_rows = _aggregate(usable_energy, energy_keys,
                             ("energy_joules", "mean_power_watts"))
    _csv(output_dir / "accuracy_statistics.csv", accuracy, accuracy_keys)
    _csv(output_dir / "performance_statistics.csv", perf, performance_keys)
    _csv(output_dir / "benchmark_energy_statistics.csv", energy_rows, energy_keys)
