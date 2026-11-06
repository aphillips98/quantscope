"""Integrate device-level NVML power over benchmark windows (not process energy)."""
from __future__ import annotations
from collections import defaultdict
from typing import Any

def integrate_benchmark_energy(samples: list[dict[str, Any]], windows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    devices = defaultdict(list)
    for sample in samples:
        t, power = sample.get("timestamp_seconds"), sample.get("power_watts")
        if isinstance(t, (int, float)) and isinstance(power, (int, float)) and power >= 0:
            devices[str(sample.get("gpu_uuid", "unknown"))].append((float(t), float(power)))
    for series in devices.values():
        series.sort()
    output = []
    for window in windows:
        start, end = window.get("start_monotonic_seconds"), window.get("end_monotonic_seconds")
        for uuid, series in devices.items():
            result = {"run_id": window.get("run_id"), "model_name": window.get("model_name"),
                      "benchmark": window.get("benchmark"), "gpu_uuid": uuid,
                      "energy_joules": None, "mean_power_watts": None,
                      "coverage_complete": False, "sample_count": 0,
                      "energy_scope": "NVML GPU device, not process"}
            if not isinstance(start, (int, float)) or not isinstance(end, (int, float)) or end <= start:
                output.append(result); continue
            result["sample_count"] = sum(start <= t <= end for t, _ in series)
            if len(series) < 2 or series[0][0] > start or series[-1][0] < end:
                output.append(result); continue
            # Clip piecewise-linear power to the exact benchmark boundaries.
            points = []
            for (t0, p0), (t1, p1) in zip(series, series[1:]):
                if t1 <= t0 or t1 < start or t0 > end: continue
                left, right = max(start, t0), min(end, t1)
                if right <= left: continue
                pl = p0 + (p1-p0)*(left-t0)/(t1-t0)
                pr = p0 + (p1-p0)*(right-t0)/(t1-t0)
                points.append((left, right, (pl+pr)*0.5*(right-left)))
            if points and points[0][0] <= start and points[-1][1] >= end:
                energy = sum(piece[2] for piece in points)
                result.update(energy_joules=energy, mean_power_watts=energy/(end-start), coverage_complete=True)
            output.append(result)
    return output
