"""Best-effort device-level GPU sampling during benchmark evaluation."""

from __future__ import annotations

import math
import os
import threading
import time
from typing import Any


class GPUPerformanceMonitor:
    def __init__(self, interval_seconds: float = 1.0) -> None:
        try:
            interval_seconds = float(interval_seconds)
        except (TypeError, ValueError):
            interval_seconds = 1.0
        self.interval_seconds = (
            interval_seconds if math.isfinite(interval_seconds) and interval_seconds > 0 else 1.0
        )
        self.samples: list[dict[str, Any]] = []
        self.detail = "unavailable"
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._nvml: Any = None
        self._devices: list[tuple[str, Any]] = []

    def start(self) -> None:
        try:
            import pynvml

            pynvml.nvmlInit()
            self._nvml = pynvml
            visible = os.environ.get("CUDA_VISIBLE_DEVICES")
            selectors = (
                visible.split(",") if visible is not None
                else [str(index) for index in range(pynvml.nvmlDeviceGetCount())]
            )
            for selector in selectors:
                selector = selector.strip()
                if not selector or selector == "-1":
                    continue
                handle = (
                    pynvml.nvmlDeviceGetHandleByIndex(int(selector)) if selector.isdigit()
                    else pynvml.nvmlDeviceGetHandleByUUID(selector)
                )
                uuid = pynvml.nvmlDeviceGetUUID(handle)
                if isinstance(uuid, bytes):
                    uuid = uuid.decode("ascii")
                self._devices.append((uuid, handle))
            if not self._devices:
                self.detail = "no visible GPUs"
                return
            self.detail = "device-level NVML samples (includes other GPU workloads)"
            self._sample()
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        except Exception as error:
            self.detail = f"unavailable: {error}"

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            self._sample()

    def _sample(self) -> None:
        for uuid, handle in self._devices:
            power = memory = None
            try:
                power = self._nvml.nvmlDeviceGetPowerUsage(handle) / 1000
            except Exception:
                pass
            try:
                memory = self._nvml.nvmlDeviceGetMemoryInfo(handle).used / (1024 * 1024)
            except Exception:
                pass
            self.samples.append({
                "timestamp_seconds": time.monotonic(), "gpu_uuid": uuid,
                "power_watts": power, "memory_used_mb": memory,
            })

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
            self._sample()
        if self._nvml is not None:
            try:
                self._nvml.nvmlShutdown()
            except Exception:
                pass

    def summary(self) -> dict[str, Any]:
        energy = duration = 0.0
        complete_power = bool(self._devices)
        peak_memory = None
        for uuid, _handle in self._devices:
            readings = [sample for sample in self.samples if sample["gpu_uuid"] == uuid]
            device_duration = 0.0
            for previous, current in zip(readings, readings[1:]):
                elapsed = current["timestamp_seconds"] - previous["timestamp_seconds"]
                if previous["power_watts"] is None or current["power_watts"] is None:
                    complete_power = False
                    continue
                energy += (previous["power_watts"] + current["power_watts"]) / 2 * elapsed
                device_duration += elapsed
            if device_duration <= 0:
                complete_power = False
            duration = max(duration, device_duration)
        memory = [sample["memory_used_mb"] for sample in self.samples if sample["memory_used_mb"] is not None]
        if memory:
            peak_memory = max(memory)
        return {
            "gpu_telemetry_detail": self.detail,
            "gpu_sample_count": len(self.samples),
            "peak_gpu_memory_mb_per_device": peak_memory,
            "mean_gpu_power_watts_total": energy / duration if complete_power and duration > 0 else None,
            "gpu_energy_joules_estimated": energy if complete_power else None,
        }