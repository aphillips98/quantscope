"""Run commands under NVIDIA Process Metrics profiling."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Sequence


PROFILED_ENV = "QSCOPE_NVIDIA_PROFILING_ACTIVE"


class NvidiaProfilingError(RuntimeError):
    """Raised when a profiling run cannot be started or collected."""


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
    """Execute a command with direct preload or the privileged daemon launcher."""

    def __init__(self, config: NvidiaProfilingConfig, output_dir: Path):
        self.config = config
        self.output_dir = output_dir

    def run(self, command: Sequence[str]) -> int:
        if not command:
            raise NvidiaProfilingError("profiling command must not be empty")
        if self.config.library_path is None or not self.config.library_path.is_file():
            raise NvidiaProfilingError(
                f"NVIDIA Process Metrics library not found: {self.config.library_path}"
            )

        env = os.environ.copy()
        env[PROFILED_ENV] = "1"
        if self.config.mode == "direct":
            return self._run_direct(command, env)
        return self._run_daemon(command, env)

    def _run_direct(self, command: Sequence[str], env: dict[str, str]) -> int:
        capture_dir = self.output_dir / "nvidia-profiling"
        capture_dir.mkdir(parents=True, exist_ok=True)
        library_path = str(self.config.library_path)
        existing_preload = env.get("LD_PRELOAD")
        env["LD_PRELOAD"] = (
            f"{library_path}:{existing_preload}" if existing_preload else library_path
        )
        env["NVIDIA_METRICS_OUTPUT_DIR"] = str(capture_dir.resolve())
        env["NVIDIA_METRICS_DEVICE"] = str(self.config.device)
        env["NVIDIA_METRICS_WINDOW_MS"] = str(self.config.window_ms)
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
        result = subprocess.run(
            launcher_command,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            return result.returncode

        results_match = re.search(r"^Results: (.+)$", result.stdout, re.MULTILINE)
        session_match = re.search(r"^Session: (.+)$", result.stdout, re.MULTILINE)
        if results_match is None or session_match is None:
            raise NvidiaProfilingError(
                "launcher completed without reporting its session results directory"
            )

        source_dir = Path(results_match.group(1))
        destination = self.output_dir / "nvidia-profiling" / session_match.group(1)
        if not source_dir.is_dir():
            raise NvidiaProfilingError(
                f"daemon results directory does not exist: {source_dir}"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source_dir, destination, dirs_exist_ok=True)
        return 0