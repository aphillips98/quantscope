"""Optional EfiMon daemon captures for a campaign and its process tree."""

from __future__ import annotations

import csv
from dataclasses import dataclass
import json
import logging
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Any, IO


EFIMON_ENV = "QSCOPE_EFIMON_ACTIVE"
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class EfimonConfig:
    enabled: bool = False
    launcher: str = "efimon-launcher"
    port: int = 5550
    sample_interval_seconds: int = 3
    discovery_interval_seconds: float = 0.5
    startup_timeout_seconds: float = 10.0
    shutdown_timeout_seconds: float = 15.0

    @classmethod
    def from_mapping(cls, value: Any) -> EfimonConfig:
        if value is None:
            return cls()
        if not isinstance(value, dict):
            raise ValueError("efimon must be a mapping")
        enabled = value.get("enabled", False)
        if not isinstance(enabled, bool):
            raise ValueError("efimon.enabled must be a boolean")
        launcher = value.get("launcher", "efimon-launcher")
        if not isinstance(launcher, str) or not launcher.strip():
            raise ValueError("efimon.launcher must be a non-empty string")
        integers: dict[str, int] = {}
        for name, default, maximum in (
            ("port", 5550, 65535),
            ("sample_interval_seconds", 3, None),
        ):
            number = value.get(name, default)
            if (
                not isinstance(number, int) or isinstance(number, bool)
                or number < 1 or (maximum is not None and number > maximum)
            ):
                raise ValueError(f"efimon.{name} must be a positive integer"
                                 + (f" <= {maximum}" if maximum else ""))
            integers[name] = number
        intervals: dict[str, float] = {}
        for name, default in (
            ("discovery_interval_seconds", 0.5),
            ("startup_timeout_seconds", 10.0),
            ("shutdown_timeout_seconds", 15.0),
        ):
            number = value.get(name, default)
            if (
                not isinstance(number, (int, float)) or isinstance(number, bool)
                or not math.isfinite(number) or number <= 0
            ):
                raise ValueError(f"efimon.{name} must be a finite positive number")
            intervals[name] = float(number)
        return cls(
            enabled=enabled, launcher=launcher, port=integers["port"],
            sample_interval_seconds=integers["sample_interval_seconds"],
            discovery_interval_seconds=intervals["discovery_interval_seconds"],
            startup_timeout_seconds=intervals["startup_timeout_seconds"],
            shutdown_timeout_seconds=intervals["shutdown_timeout_seconds"],
        )


@dataclass
class _Capture:
    pid: int
    start_ticks: str
    process: subprocess.Popen[bytes]
    log: IO[bytes]
    path: Path
    started: float
    ready: bool = False
    error: str | None = None
    stopped: bool = False


def process_tree(root: Path = Path("/proc")) -> dict[int, tuple[int, str]]:
    """Read parent PIDs and start ticks, tolerating processes that exit mid-scan."""
    processes = {}
    for directory in root.iterdir():
        if not directory.name.isdecimal():
            continue
        try:
            stat = (directory / "stat").read_text(encoding="utf-8")
        except (FileNotFoundError, ProcessLookupError):
            continue
        fields = stat[stat.rindex(")") + 2:].split()
        processes[int(directory.name)] = (int(fields[1]), fields[19])
    return processes


def descendants(pid: int, processes: dict[int, tuple[int, str]]) -> set[int]:
    result = {pid}
    while True:
        children = {child for child, (parent, _) in processes.items() if parent in result}
        if children <= result:
            return result
        result.update(children)


def summarize_capture(path: Path) -> dict[str, Any]:
    """Summarize native CSV fields without guessing units or energy attribution."""
    LOGGER.debug("Summarizing EfiMon capture %s", path)
    with path.open(encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source, strict=True)
        if not reader.fieldnames or len(set(reader.fieldnames)) != len(reader.fieldnames):
            raise ValueError(f"Invalid EfiMon CSV header: {path.name}")
        statistics: dict[str, dict[str, float | int]] = {}
        samples = 0
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"Incomplete EfiMon CSV row: {path.name}")
            samples += 1
            for field, value in row.items():
                if field == "ID":
                    continue
                try:
                    number = float(value)
                except ValueError as error:
                    raise ValueError(f"Non-numeric EfiMon field {field}: {path.name}") from error
                if not math.isfinite(number):
                    raise ValueError(f"Non-finite EfiMon field {field}: {path.name}")
                stats = statistics.setdefault(field, {
                    "count": 0, "min": number, "max": number, "mean": 0.0,
                })
                stats["count"] += 1
                stats["min"] = min(stats["min"], number)
                stats["max"] = max(stats["max"], number)
                stats["mean"] += (number - stats["mean"]) / stats["count"]
    if not samples:
        raise ValueError(f"No samples collected by EfiMon: {path.name}")
    return {"file": path.name, "samples": samples, "metrics": statistics}


class EfimonMonitor:
    """Attach one launcher per PID; never launch commands through EfiMon."""

    def __init__(self, config: EfimonConfig, output_dir: Path) -> None:
        self.config = config
        self.output_dir = output_dir
        self.capture_dir = output_dir / "efimon" / f"capture-{time.time_ns()}"
        self._captures: list[_Capture] = []
        self._seen: set[tuple[int, str]] = set()
        self._errors: list[str] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._launcher: str | None = None
        self._previous_env: str | None = None

    def _warn(self, message: str) -> None:
        self._errors.append(message)
        # The CLI defaults to CRITICAL logging; capture failures must remain visible.
        print(f"Warning: EfiMon capture failed: {message}", file=sys.stderr)

    def __enter__(self) -> EfimonMonitor:
        LOGGER.debug("Entering EfiMon monitor; capture directory %s", self.capture_dir)
        self._previous_env = os.environ.get(EFIMON_ENV)
        os.environ[EFIMON_ENV] = "1"
        try:
            self.capture_dir.mkdir(parents=True, exist_ok=True)
            self._launcher = shutil.which(self.config.launcher)
            if self._launcher is None:
                raise FileNotFoundError(f"launcher not found: {self.config.launcher}")
            LOGGER.debug("Using EfiMon launcher %s on port %d", self._launcher, self.config.port)
            self._discover()
            deadline = time.monotonic() + self.config.startup_timeout_seconds
            while self._captures and not self._captures[0].ready and not self._captures[0].error:
                self._check()
                if time.monotonic() >= deadline:
                    break
                self._stop.wait(0.05)
            self._thread = threading.Thread(target=self._watch, name="efimon-monitor")
            self._thread.start()
        except (OSError, ValueError) as error:
            self._warn(str(error))
        except (KeyboardInterrupt, SystemExit):
            self.__exit__(*sys.exc_info())
            raise
        return self

    def _discover(self) -> None:
        processes = process_tree()
        excluded = set()
        for capture in self._captures:
            if capture.process.poll() is None:
                excluded.update(descendants(capture.process.pid, processes))
            identity = processes.get(capture.pid)
            if not capture.stopped and (identity is None or identity[1] != capture.start_ticks):
                if not capture.ready and not capture.error:
                    capture.error = "process exited before monitor startup completed"
                    self._warn(f"PID {capture.pid}: {capture.error}")
                self._stop_capture(capture)
        pids = descendants(os.getpid(), processes) - excluded
        for pid in sorted(pids, key=lambda value: (value != os.getpid(), value)):
            if pid not in processes:
                continue
            identity = (pid, processes[pid][1])
            if identity in self._seen:
                continue
            self._seen.add(identity)
            prefix = self.capture_dir.resolve() / f"process-{pid}-{identity[1]}.csv"
            log = prefix.with_suffix(".log").open("wb")
            command = [
                str(self._launcher), "--port", str(self.config.port),
                "--delay", str(self.config.sample_interval_seconds),
                "--children", "0", "--check-threads", "-1", "--select-perf", "0",
                "--output", str(prefix), "--pid", str(pid),
            ]
            try:
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            except OSError:
                log.close()
                raise
            LOGGER.debug("Started EfiMon capture for PID %d (launcher pid %d)", pid, process.pid)
            self._captures.append(_Capture(pid, identity[1], process, log, prefix, time.monotonic()))

    def _check(self) -> None:
        for capture in self._captures:
            if capture.error or capture.stopped:
                continue
            log_path = capture.path.with_suffix(".log")
            text = log_path.read_text(encoding="utf-8", errors="replace")
            capture.ready = capture.ready or "Process Monitor started" in text
            code = capture.process.poll()
            error = None
            if "Process Monitor could not be started" in text:
                error = "daemon rejected the process monitor"
            elif code is not None and (code != 0 or not capture.ready):
                error = f"launcher exited with code {code}"
            elif code is not None and Path(f"/proc/{capture.pid}").exists():
                error = "launcher stopped while the monitored process was still running"
            elif not capture.ready and time.monotonic() - capture.started >= self.config.startup_timeout_seconds:
                error = "startup timed out (check daemon availability)"
            if error:
                capture.error = error
                self._warn(f"PID {capture.pid}: {error}; see {log_path.name}")
                self._stop_capture(capture)

    def _watch(self) -> None:
        try:
            while not self._stop.wait(self.config.discovery_interval_seconds):
                self._check()
                self._discover()
        except (OSError, ValueError) as error:
            self._warn(f"process discovery/monitoring stopped: {error}")

    def _stop_capture(self, capture: _Capture) -> None:
        if capture.stopped:
            return
        LOGGER.debug("Stopping EfiMon capture for PID %d", capture.pid)
        if capture.process.poll() is None:
            try:
                capture.process.send_signal(signal.SIGINT)
            except ProcessLookupError:
                capture.process.wait()
            try:
                capture.process.wait(timeout=self.config.shutdown_timeout_seconds)
            except subprocess.TimeoutExpired:
                capture.process.kill()
                capture.process.wait()
                capture.error = "launcher did not stop before shutdown timeout"
                self._warn(f"PID {capture.pid}: {capture.error}; daemon session may need cleanup")
            if capture.error is None:
                text = capture.path.with_suffix(".log").read_text(encoding="utf-8", errors="replace")
                if capture.process.returncode != 0 or "Process Monitor could not be stopped" in text:
                    capture.error = f"launcher shutdown failed (code {capture.process.returncode})"
                    self._warn(f"PID {capture.pid}: {capture.error}")
        capture.stopped = True

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
        try:
            try:
                self._check()
            except (OSError, ValueError) as error:
                self._warn(f"could not check launcher state: {error}")
            for capture in self._captures:
                try:
                    self._stop_capture(capture)
                except OSError as error:
                    capture.error = str(error)
                    self._warn(f"PID {capture.pid}: cleanup failed: {error}")
                finally:
                    capture.log.close()
            try:
                self._write_summary()
            except OSError as error:
                self._warn(f"could not write capture summary: {error}")
        finally:
            if self._previous_env is None:
                os.environ.pop(EFIMON_ENV, None)
            else:
                os.environ[EFIMON_ENV] = self._previous_env

    def _write_summary(self) -> None:
        LOGGER.debug("Writing EfiMon summary for %d capture(s)", len(self._captures))
        captures = []
        for capture in self._captures:
            result: dict[str, Any] = {
                "pid": capture.pid, "status": "failed" if capture.error else "completed",
                "error": capture.error, "files": [],
                "launcher_log": capture.path.with_suffix(".log").name,
            }
            # EfiMon appends ".<pid>" to the requested filename.
            files = sorted(self.capture_dir.glob(capture.path.name + ".*"))
            if not files:
                self._warn(f"PID {capture.pid}: daemon produced no CSV files")
                result["status"] = "failed"
                result["error"] = result["error"] or "daemon produced no CSV files"
            for path in files:
                try:
                    result["files"].append(summarize_capture(path))
                except (OSError, ValueError, csv.Error) as error:
                    self._warn(str(error))
                    result["status"] = "failed"
                    result["error"] = str(error)
            captures.append(result)
        summary = {
            "status": "failed" if self._errors else "completed",
            "scope": "campaign_process_tree",
            "directory": str(self.capture_dir.relative_to(self.output_dir)),
            "discovery_interval_seconds": self.config.discovery_interval_seconds,
            "metrics_units": "native EfiMon units; no energy conversion or process attribution",
            "errors": self._errors,
            "captures": captures,
        }
        self.capture_dir.mkdir(parents=True, exist_ok=True)
        metadata_path = self.output_dir / "metadata.json"
        if metadata_path.exists():
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
                if not isinstance(metadata, dict):
                    raise ValueError("benchmark metadata must be a JSON object")
                metadata["efimon"] = summary
                metadata_path.write_text(
                    json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
                )
            except (OSError, ValueError) as error:
                self._warn(f"could not integrate EfiMon metadata: {error}")
                summary["status"] = "failed"
        (self.capture_dir / "summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
