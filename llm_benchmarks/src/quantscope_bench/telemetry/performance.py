"""GPU performance capture: NVML sampling plus NVIDIA Process Metrics profiling.

Two complementary collectors live here:

- ``GPUPerformanceMonitor``: best-effort device-level NVML sampling.
- ``NvidiaProcessMetricsProfiler``: full NVIDIA Process Metrics capture
  (``kernel_activity.csv``, ``gpu_telemetry.csv``, ``pm_sampling.csv`` and
  ``pm_sampling.log``) covering every benchmark prediction run (MMLU,
  HellaSwag, and any future benchmark) under ``OUTPUT_DIR/performance/``.
"""

from __future__ import annotations

from dataclasses import dataclass
import logging
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
from typing import Any, Sequence

LOGGER = logging.getLogger(__name__)

PROFILED_ENV = "QSCOPE_NVIDIA_PROFILING_ACTIVE"

#: Files the NVIDIA Process Metrics project can deliver for a capture.
PROFILING_ARTIFACT_NAMES = (
    "kernel_activity.csv",
    "gpu_telemetry.csv",
    "pm_sampling.csv",
    "pm_sampling.log",
)


class NvidiaProfilingError(RuntimeError):
    """Raised when a profiling run cannot be started or collected."""


def _unquote(value: str) -> str:
    """Undo C++ std::quoted formatting used by the launcher for filesystem paths."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return re.sub(r"\\(.)", r"\1", value[1:-1])
    return value


@dataclass(frozen=True)
class NvidiaProfilingConfig:
    enabled: bool = False
    mode: str = "direct"
    library_path: Path | None = None
    device: int = 0
    window_ms: int = 200
    duration_seconds: int | None = None
    launcher: str = "nvidia-process-metrics-launcher"

    @classmethod
    def from_mapping(cls, value: Any) -> NvidiaProfilingConfig:
        if value is None:
            return cls()
        if not isinstance(value, dict):
            raise ValueError("profiling must be a mapping")

        enabled = value.get("enabled", False)
        if not isinstance(enabled, bool):
            raise ValueError("profiling.enabled must be a boolean")
        mode = value.get("mode", "direct")
        if not isinstance(mode, str) or mode not in {"direct", "daemon"}:
            raise ValueError("profiling.mode must be 'direct' or 'daemon'")
        if not enabled:
            return cls(enabled=False, mode=mode)

        library_path = value.get("library_path")
        if not isinstance(library_path, str) or not library_path.strip():
            raise ValueError("profiling.library_path is required when profiling is enabled")

        device = value.get("device", 0)
        if not isinstance(device, int) or isinstance(device, bool) or device < 0:
            raise ValueError("profiling.device must be a non-negative integer")
        window_ms = value.get("window_ms", 200)
        if not isinstance(window_ms, int) or isinstance(window_ms, bool) or window_ms < 1:
            raise ValueError("profiling.window_ms must be a positive integer")

        duration_seconds = value.get("duration_seconds")
        if mode == "daemon" and (
            not isinstance(duration_seconds, int)
            or isinstance(duration_seconds, bool)
            or duration_seconds < 1
        ):
            raise ValueError(
                "profiling.duration_seconds must be a positive integer in daemon mode"
            )
        if duration_seconds is not None and (
            not isinstance(duration_seconds, int)
            or isinstance(duration_seconds, bool)
            or duration_seconds < 1
        ):
            raise ValueError("profiling.duration_seconds must be a positive integer")

        launcher = value.get("launcher", "nvidia-process-metrics-launcher")
        if not isinstance(launcher, str) or not launcher.strip():
            raise ValueError("profiling.launcher must be a non-empty string")

        return cls(
            enabled=True,
            mode=mode,
            library_path=Path(os.path.expandvars(os.path.expanduser(library_path))),
            device=device,
            window_ms=window_ms,
            duration_seconds=duration_seconds,
            launcher=launcher,
        )


class NvidiaProcessMetricsProfiler:
    """Execute a command with direct preload or the privileged daemon launcher.

    Captures land under ``<output_dir>/performance/nvidia-profiling/`` so every
    benchmark prediction executed by the profiled command is covered.
    """

    def __init__(self, config: NvidiaProfilingConfig, output_dir: Path):
        self.config = config
        self.output_dir = output_dir
        self.capture_dir = output_dir / "performance" / "nvidia-profiling"

    def run(self, command: Sequence[str]) -> int:
        if not command:
            raise NvidiaProfilingError("profiling command must not be empty")
        if self.config.library_path is None or not self.config.library_path.is_file():
            raise NvidiaProfilingError(
                f"NVIDIA Process Metrics library not found: {self.config.library_path}"
            )

        env = os.environ.copy()
        env[PROFILED_ENV] = "1"
        # Reruns into the same output directory replace the prediction
        # artifacts, so drop captures from previous runs to keep the
        # profiling artifacts consistent with them.
        shutil.rmtree(self.capture_dir, ignore_errors=True)
        LOGGER.debug(
            "Starting NVIDIA profiling in %s mode (device=%d, window_ms=%d)",
            self.config.mode,
            self.config.device,
            self.config.window_ms,
        )
        if self.config.mode == "direct":
            status = self._run_direct(command, env)
        else:
            status = self._run_daemon(command, env)
        self._prune_parent_captures()
        self._log_artifacts()
        return status

    def artifacts(self) -> list[Path]:
        """List every NVIDIA Process Metrics file collected so far."""
        if not self.capture_dir.is_dir():
            return []
        return sorted(
            path for path in self.capture_dir.rglob("*")
            if path.is_file() and path.name in PROFILING_ARTIFACT_NAMES
        )

    def _prune_parent_captures(self) -> None:
        """Keep only the llama-server captures when both processes wrote files.

        ``LD_PRELOAD`` is inherited by every child process, so the profiled
        Python CLI writes its own ``kernel_activity.csv`` (always empty:
        Python launches no CUDA kernels) and ``gpu_telemetry.csv`` next to
        the real llama-server captures. Drop the CLI pair whenever a
        ``llama-server-*`` capture exists; captures without a llama-server
        sibling are preserved untouched.
        """
        if not self.capture_dir.is_dir():
            return
        session_dirs = [self.capture_dir] + [
            path for path in self.capture_dir.iterdir() if path.is_dir()
        ]
        for directory in session_dirs:
            has_server_capture = any(
                (child / "kernel_activity.csv").is_file()
                for child in directory.glob("llama-server-*")
                if child.is_dir()
            )
            if not has_server_capture:
                continue
            for name in ("kernel_activity.csv", "gpu_telemetry.csv"):
                stale = directory / name
                if stale.is_file():
                    LOGGER.debug("Pruning parent CLI capture %s", stale)
                    stale.unlink()

    def _log_artifacts(self) -> None:
        for path in self.artifacts():
            LOGGER.debug("Collected NVIDIA profiling artifact %s", path)

    def _run_direct(self, command: Sequence[str], env: dict[str, str]) -> int:
        self.capture_dir.mkdir(parents=True, exist_ok=True)
        library_path = str(self.config.library_path)
        existing_preload = env.get("LD_PRELOAD")
        env["LD_PRELOAD"] = (
            f"{library_path}:{existing_preload}" if existing_preload else library_path
        )
        env["NVIDIA_METRICS_OUTPUT_DIR"] = str(self.capture_dir.resolve())
        env["NVIDIA_METRICS_DEVICE"] = str(self.config.device)
        env["NVIDIA_METRICS_WINDOW_MS"] = str(self.config.window_ms)
        LOGGER.debug("Running profiled command with LD_PRELOAD=%s: %s", env["LD_PRELOAD"], command)
        return subprocess.run(list(command), env=env, check=False).returncode

    def _run_daemon(self, command: Sequence[str], env: dict[str, str]) -> int:
        launcher = shutil.which(self.config.launcher)
        if launcher is None:
            raise NvidiaProfilingError(
                f"NVIDIA Process Metrics launcher not found: {self.config.launcher}"
            )

        launcher_command = [
            launcher,
            "--library",
            str(self.config.library_path),
            "--device",
            str(self.config.device),
            "--duration",
            str(self.config.duration_seconds),
            "--window-ms",
            str(self.config.window_ms),
            "--command",
            "--",
            *command,
        ]
        # Keep the profiled CLI's stdout line-buffered so its progress shows
        # up promptly even though the launcher's stdout is now a pipe.
        env = {**env, "PYTHONUNBUFFERED": "1"}
        # Stream the launcher's stdout live while keeping a copy: the session
        # id and results directory are parsed from it after the launcher
        # exits. stderr is not captured, so logs flow straight to the
        # terminal while the profiled command runs.
        process = subprocess.Popen(
            launcher_command,
            env=env,
            stdout=subprocess.PIPE,
            text=True,
        )
        stdout_lines: list[str] = []
        with process:
            if process.stdout is not None:
                for line in process.stdout:
                    sys.stdout.write(line)
                    stdout_lines.append(line)
        stdout = "".join(stdout_lines)
        LOGGER.debug("Daemon launcher %s exited with code %d", launcher, process.returncode)
        if process.returncode != 0:
            return process.returncode

        results_match = re.search(r"^Results: (.+)$", stdout, re.MULTILINE)
        session_match = re.search(r"^Session: (.+)$", stdout, re.MULTILINE)
        if results_match is None or session_match is None:
            raise NvidiaProfilingError(
                "launcher completed without reporting its session results directory"
            )

        source_dir = Path(_unquote(results_match.group(1)))
        destination = self.capture_dir / _unquote(session_match.group(1))
        if not source_dir.is_dir():
            raise NvidiaProfilingError(
                f"daemon results directory does not exist: {source_dir}"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        LOGGER.debug("Copying daemon results from %s to %s", source_dir, destination)
        shutil.copytree(source_dir, destination, dirs_exist_ok=True)
        return 0


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
        LOGGER.debug("Starting GPU performance monitor (interval=%.2fs)", self.interval_seconds)
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
                LOGGER.debug("GPU monitor found no visible GPUs")
                return
            LOGGER.debug("GPU monitor sampling %d device(s)", len(self._devices))
            self.detail = "device-level NVML samples (includes other GPU workloads)"
            self._sample()
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        except Exception as error:
            self.detail = f"unavailable: {error}"
            LOGGER.debug("GPU monitor unavailable: %s", error)

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
        LOGGER.debug("Stopping GPU performance monitor after %d sample(s)", len(self.samples))
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
        LOGGER.debug("Summarizing %d GPU sample(s) across %d device(s)", len(self.samples), len(self._devices))
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