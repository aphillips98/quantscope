from __future__ import annotations

from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

from quantscope_bench import cli
from quantscope_bench.config import ConfigurationError, validate_campaign
from quantscope_bench.telemetry.efimon import (
    EFIMON_ENV, EfimonConfig, EfimonMonitor, descendants, process_tree, summarize_capture,
)
from quantscope_bench.telemetry.performance import PROFILED_ENV


class EfimonConfigTests(unittest.TestCase):
    def test_disabled_by_default(self) -> None:
        self.assertFalse(EfimonConfig.from_mapping(None).enabled)

    def test_rejects_invalid_values(self) -> None:
        for value in (
            [], {"enabled": "yes"}, {"launcher": ""},
            {"port": 65536}, {"port": True}, {"sample_interval_seconds": 0.5},
            {"discovery_interval_seconds": 0}, {"startup_timeout_seconds": float("nan")},
            {"shutdown_timeout_seconds": False},
        ):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "efimon"):
                EfimonConfig.from_mapping(value)

    def test_campaign_validation_checks_efimon(self) -> None:
        models = {"version": 1, "models": {"test": {"backend": "llamacpp", "local_path": "m.gguf"}}}
        hardware = {"version": 1, "profiles": {"cpu": {}}}
        campaign = {
            "version": 1, "model": "test", "hardware_profile": "cpu",
            "scoring": ["exact_match"], "benchmarks": {"mmlu": {}},
            "efimon": {"enabled": True},
        }
        self.assertEqual(validate_campaign(models, campaign, hardware).model_name, "test")
        campaign["efimon"]["port"] = -1
        with self.assertRaisesRegex(ConfigurationError, "efimon.port"):
            validate_campaign(models, campaign, hardware)


class EfimonSummaryTests(unittest.TestCase):
    def test_preserves_native_fields_without_summing_system_power(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv.123"
            path.write_text(
                "ID,Timestamp,ProcessCpuUsage,SocketPower0\n"
                "0,1000,10,50\n1,2000,30,70\n", encoding="utf-8",
            )
            result = summarize_capture(path)
        self.assertEqual(result["samples"], 2)
        self.assertEqual(result["metrics"]["ProcessCpuUsage"]["mean"], 20)
        self.assertEqual(result["metrics"]["SocketPower0"]["min"], 50)
        self.assertNotIn("joules", result)
        self.assertNotIn("ID", result["metrics"])

    def test_rejects_empty_malformed_and_nonfinite_captures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            for contents in (
                "", "ID,Timestamp\n", "ID,X\n0,nan\n",
                "ID,X\n0,1,2\n", "ID,X,Y\n0,1\n", "ID,X\n0,bad\n",
            ):
                with self.subTest(contents=contents), self.assertRaises(ValueError):
                    path.write_text(contents, encoding="utf-8")
                    summarize_capture(path)

    def test_reads_proc_stat_with_spaces_and_parentheses_in_command(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "123").mkdir()
            (root / "123/stat").write_text(
                "123 (a command ) name) S 100 " + "0 " * 17 + "456 0\n",
                encoding="utf-8",
            )
            self.assertEqual(process_tree(root), {123: (100, "456")})
        self.assertEqual(descendants(1, {2: (1, "a"), 3: (2, "b"), 4: (9, "c")}), {1, 2, 3})


class EfimonMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.launcher = self.root / "efimon-launcher"
        self.launcher.write_text(
            f"#!{sys.executable}\n"
            "import pathlib, signal, sys, time\n"
            "args = sys.argv\n"
            "pid = args[args.index('--pid') + 1]\n"
            "prefix = args[args.index('--output') + 1]\n"
            "signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n"
            "pathlib.Path(prefix + '.' + pid).write_text('ID,ProcessCpuUsage\\n0,25\\n')\n"
            "print('Process Monitor started', flush=True)\n"
            "while True: time.sleep(0.01)\n", encoding="utf-8",
        )
        self.launcher.chmod(0o755)
        self.config = EfimonConfig(
            enabled=True, launcher=str(self.launcher), discovery_interval_seconds=0.02,
            startup_timeout_seconds=1, shutdown_timeout_seconds=1,
        )

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_captures_parent_and_new_child_and_integrates_metadata(self) -> None:
        (self.root / "predictions").mkdir()
        (self.root / "predictions" / "metadata.json").write_text(
            '{"benchmark_scores": {}}', encoding="utf-8"
        )
        previous = os.environ.get(EFIMON_ENV)
        with EfimonMonitor(self.config, self.root) as monitor:
            self.assertEqual(os.environ[EFIMON_ENV], "1")
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if any(capture.pid == child.pid and capture.ready for capture in monitor._captures):
                        break
                    time.sleep(0.02)
                else:
                    self.fail("New child was not discovered and attached")
            finally:
                child.terminate()
                child.wait()
        self.assertEqual(os.environ.get(EFIMON_ENV), previous)
        summary = json.loads((monitor.capture_dir / "summary.json").read_text())
        self.assertEqual(summary["status"], "completed")
        self.assertEqual({capture["pid"] for capture in summary["captures"]}, {os.getpid(), child.pid})
        self.assertTrue(all(capture.process.poll() is not None for capture in monitor._captures))
        self.assertEqual(
            json.loads((self.root / "predictions" / "metadata.json").read_text())["efimon"],
            summary,
        )

    def test_missing_launcher_warns_and_does_not_block_workload(self) -> None:
        warnings = io.StringIO()
        config = EfimonConfig(enabled=True, launcher=str(self.root / "missing"))
        with redirect_stderr(warnings), EfimonMonitor(config, self.root) as monitor:
            workload_status = 7
        summary = json.loads((monitor.capture_dir / "summary.json").read_text())
        self.assertEqual(workload_status, 7)
        self.assertEqual(summary["status"], "failed")
        self.assertIn("launcher not found", warnings.getvalue())

    def test_startup_and_shutdown_timeouts_are_bounded_and_recorded(self) -> None:
        self.launcher.write_text(
            f"#!{sys.executable}\n"
            "import signal, time\n"
            "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
            "while True: time.sleep(0.01)\n", encoding="utf-8",
        )
        config = EfimonConfig(
            enabled=True, launcher=str(self.launcher), discovery_interval_seconds=0.02,
            startup_timeout_seconds=0.2, shutdown_timeout_seconds=0.1,
        )
        warnings = io.StringIO()
        with redirect_stderr(warnings), EfimonMonitor(config, self.root) as monitor:
            pass
        summary = json.loads((monitor.capture_dir / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("startup timed out", warnings.getvalue())
        self.assertIn("shutdown timeout", warnings.getvalue())
        self.assertTrue(all(capture.process.returncode == -signal.SIGKILL for capture in monitor._captures))

    def test_cleanup_also_runs_when_benchmark_raises(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "benchmark error"):
            with EfimonMonitor(self.config, self.root) as monitor:
                raise RuntimeError("benchmark error")
        self.assertTrue(all(capture.process.poll() is not None for capture in monitor._captures))
        self.assertTrue((monitor.capture_dir / "summary.json").is_file())

    def test_no_samples_is_a_failed_capture(self) -> None:
        warnings = io.StringIO()
        with redirect_stderr(warnings), EfimonMonitor(self.config, self.root) as monitor:
            for path in monitor.capture_dir.glob("*.csv.*"):
                path.write_text("ID,ProcessCpuUsage\n", encoding="utf-8")
        summary = json.loads((monitor.capture_dir / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("No samples", warnings.getvalue())

    def test_stops_capture_when_a_child_exits(self) -> None:
        with EfimonMonitor(self.config, self.root) as monitor:
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    captures = [capture for capture in monitor._captures
                                if capture.pid == child.pid and capture.ready]
                    if captures:
                        break
                    time.sleep(0.02)
                else:
                    self.fail("Child capture did not start")
            finally:
                child.terminate()
                child.wait()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not captures[0].stopped:
                time.sleep(0.02)
            self.assertTrue(captures[0].stopped)

    def test_invalid_metadata_does_not_hide_capture_failure_or_replace_metadata(self) -> None:
        (self.root / "predictions").mkdir()
        metadata = self.root / "predictions" / "metadata.json"
        metadata.write_text("invalid JSON", encoding="utf-8")
        with redirect_stderr(io.StringIO()), EfimonMonitor(self.config, self.root) as monitor:
            pass
        summary = json.loads((monitor.capture_dir / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("could not integrate", summary["errors"][0])
        self.assertEqual(metadata.read_text(), "invalid JSON")

    @patch.dict(os.environ, {EFIMON_ENV: "", PROFILED_ENV: ""})
    def test_real_monitor_wraps_nvidia_reentry_and_writes_combined_results(self) -> None:
        documents = [
            {"version": 1, "models": {"m": {"backend": "transformers", "hf_id": "org/model"}}},
            {"version": 1, "model": "m", "hardware_profile": "cpu",
             "scoring": ["exact_match"], "benchmarks": {"mmlu": {}},
             "efimon": {"enabled": True, "launcher": str(self.launcher)},
             "profiling": {"enabled": True, "library_path": "/opt/libmetrics.so"}},
            {"version": 1, "profiles": {"cpu": {}}},
        ]
        argv = [
            "run", "--models", "models.yml", "--campaign", "campaign.yml",
            "--hardware", "hardware.yml", "--output-dir", str(self.root),
        ]

        def profiled_run(command: list[str]) -> int:
            self.assertEqual(os.environ[EFIMON_ENV], "1")
            with patch.dict(os.environ, {PROFILED_ENV: "1"}):
                return cli.main(command[3:])

        with (
            patch.object(cli, "load_yaml", side_effect=documents * 2),
            patch.object(cli.NvidiaProcessMetricsProfiler, "run", side_effect=profiled_run) as profiler,
            patch("quantscope_bench.adapters.create_adapter", return_value=MagicMock()) as adapter,
            patch("quantscope_bench.benchmarks.deepeval.run_deepeval_campaign",
                  return_value=([], {"benchmark_scores": {"mmlu": 1.0}})) as benchmark,
            patch("quantscope_bench.telemetry.collect_platform_inventory", return_value={}),
        ):
            self.assertEqual(cli.main(argv), 0)
        profiler.assert_called_once()
        adapter.assert_called_once()
        benchmark.assert_called_once()
        metadata = json.loads((self.root / "predictions" / "metadata.json").read_text())
        self.assertEqual(metadata["benchmark_scores"], {"mmlu": 1.0})
        self.assertEqual(metadata["efimon"]["status"], "completed")
        self.assertEqual(len(list((self.root / "efimon").glob("capture-*"))), 1)


class EfimonCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.documents = [
            {"version": 1, "models": {"m": {"backend": "llamacpp", "local_path": "m.gguf"}}},
            {"version": 1, "model": "m", "hardware_profile": "cpu",
             "scoring": ["exact_match"], "benchmarks": {"mmlu": {}},
             "efimon": {"enabled": True}},
            {"version": 1, "profiles": {"cpu": {}}},
        ]
        self.argv = [
            "run", "--models", "models.yml", "--campaign", "campaign.yml",
            "--hardware", "hardware.yml", "--output-dir", "artifacts",
        ]

    @patch.dict(os.environ, {EFIMON_ENV: ""})
    def test_efimon_and_nvidia_can_be_enabled_independently_or_together(self) -> None:
        for efimon, nvidia in ((True, False), (False, True), (True, True), (False, False)):
            with self.subTest(efimon=efimon, nvidia=nvidia):
                self.documents[1]["efimon"]["enabled"] = efimon
                self.documents[1]["profiling"] = {
                    "enabled": nvidia, "library_path": "/opt/libmetrics.so",
                }
                with (
                    patch.object(cli, "load_yaml", side_effect=self.documents),
                    patch.object(cli, "EfimonMonitor") as monitor,
                    patch.object(cli, "_run_campaign", return_value=7) as run,
                ):
                    self.assertEqual(cli.main(self.argv), 7)
                    self.assertEqual(monitor.called, efimon)
                    run.assert_called_once()

    @patch.dict(os.environ, {EFIMON_ENV: "1"})
    def test_profiled_child_does_not_start_a_second_efimon_monitor(self) -> None:
        with (
            patch.object(cli, "load_yaml", side_effect=self.documents),
            patch.object(cli, "EfimonMonitor") as monitor,
            patch.object(cli, "_run_campaign", return_value=0),
        ):
            self.assertEqual(cli.main(self.argv), 0)
            monitor.assert_not_called()

    def test_validate_does_not_contact_daemon(self) -> None:
        with (
            patch.object(cli, "load_yaml", side_effect=self.documents),
            patch.object(cli, "EfimonMonitor") as monitor,
        ):
            self.assertEqual(cli.main(["validate", *self.argv[1:-2]]), 0)
            monitor.assert_not_called()
