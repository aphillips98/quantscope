"""Non-destructive artifact quality checks; never modify benchmark scores."""
from __future__ import annotations
from collections import Counter
from typing import Any

def validate_run(results: list[Any], traces: list[dict[str, Any]],
                 requests: list[dict[str, Any]], windows: list[dict[str, Any]],
                 energy: list[dict[str, Any]]) -> dict[str, Any]:
    warnings = []
    errors = []
    result_counts = Counter((r.model_name, r.benchmark) for r in results)
    trace_counts = Counter((t.get("model_name"), t.get("benchmark")) for t in traces)
    for key, count in result_counts.items():
        if trace_counts[key] != count:
            warnings.append(f"{key}: {count} predictions but {trace_counts[key]} generation traces; sample linkage is unverified")
    for record in requests:
        if record.get("latency_seconds") is not None and record["latency_seconds"] < 0:
            errors.append(f"Negative request latency: {record.get('request_id')}")
        start, end = record.get("start_timestamp_ns"), record.get("end_timestamp_ns")
        if start is not None and end is not None and end < start:
            errors.append(f"Reversed request timestamps: {record.get('request_id')}")
    for item in energy:
        if not item["coverage_complete"]:
            warnings.append(f"Incomplete GPU power coverage: {item['model_name']}/{item['benchmark']}/{item['gpu_uuid']}")
    if results and not requests:
        warnings.append("No performance requests available; per-sample latency is not measured")
    if results and any(r.latency_seconds == 0 for r in results):
        warnings.append("samples.csv latency_seconds=0.0 is a legacy placeholder, NOT a measured zero; use performance_requests.csv")
    return {"status": "error" if errors else "warning" if warnings else "ok",
            "errors": errors, "warnings": warnings,
            "counts": {"predictions": len(results), "generation_traces": len(traces),
                       "performance_requests": len(requests), "benchmark_windows": len(windows),
                       "gpu_energy_records": len(energy)},
            "sample_request_linkage": "unverified; no positional join performed"}
