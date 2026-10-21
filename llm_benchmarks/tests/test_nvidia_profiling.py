from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from quantscope_bench import cli
from quantscope_bench.telemetry.nvidia_profiling import (
    NvidiaProcessMetricsProfiler,
    NvidiaProfilingConfig,
    NvidiaProfilingError,
    PROFILED_ENV,
)


class NvidiaProfilingConfigTests(unittest.TestCase):
    def test_profiling_is_disabled_by_default(self) -> None:
        config = NvidiaProfilingConfig.from_mapping(None)

        self.assertFalse(config.enabled)
        self.assertEqual(config.mode, "direct")

    def test_daemon_requires_a_duration(self) -> None:
        with self.assertRaisesRegex(ValueError, "duration_seconds"):
            NvidiaProfilingConfig.from_mapping(
                {"enabled": True, "mode": "daemon", "library_path": "/tmp/libmetrics.so"}
            )

    def test_enabled_config_requires_library_path(self) -> None:
        with self.assertRaisesRegex(ValueError, "library_path"):
            NvidiaProfilingConfig.from_mapping({"enabled": True})


class NvidiaProcessMetricsProfilerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.library = self.root / "libnvidia-process-metrics.so"
        self.library.touch()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    @patch("quantscope_bench.telemetry.nvidia_profiling.subprocess.run")
    def test_direct_mode_sets_preload_and_capture_environment(self, run_mock) -> None:
        run_mock.return_value = subprocess.CompletedProcess([], 0)
        profiler = NvidiaProcessMetricsProfiler(
            NvidiaProfilingConfig(
                enabled=True,
                library_path=self.library,
                device=2,
                window_ms=500,
            ),
            self.root / "artifacts",
        )

        status = profiler.run(["cuda-hello", "--iterations", "3"])

        self.assertEqual(status, 0)
        command = run_mock.call_args.args[0]
        env = run_mock.call_args.kwargs["env"]
        self.assertEqual(command, ["cuda-hello", "--iterations", "3"])
        self.assertEqual(env["LD_PRELOAD"], str(self.library))
        self.assertEqual(env["NVIDIA_METRICS_DEVICE"], "2")
        self.assertEqual(env["NVIDIA_METRICS_WINDOW_MS"], "500")
        self.assertTrue(Path(env["NVIDIA_METRICS_OUTPUT_DIR"]).is_dir())
        self.assertEqual(env[PROFILED_ENV], "1")

    @patch("quantscope_bench.telemetry.nvidia_profiling.subprocess.run")
    @patch("quantscope_bench.telemetry.nvidia_profiling.shutil.which")
    def test_daemon_mode_copies_session_results(self, which_mock, run_mock) -> None:
        session_dir = self.root / "daemon-session"
        session_dir.mkdir()
        (session_dir / "kernel_activity.csv").write_text("kernel\n", encoding="utf-8")
        which_mock.return_value = "/usr/bin/nvidia-process-metrics-launcher"
        run_mock.return_value = subprocess.CompletedProcess(
            [],
            0,
            stdout=f"Session: session-123\nResults: {session_dir}\n",
            stderr="",
        )
        profiler = NvidiaProcessMetricsProfiler(
            NvidiaProfilingConfig(
                enabled=True,
                mode="daemon",
                library_path=self.library,
                duration_seconds=30,
            ),
            self.root / "artifacts",
        )

        status = profiler.run(["qscope-bench", "run"])

        self.assertEqual(status, 0)
        copied_csv = (
            self.root / "artifacts/nvidia-profiling/session-123/kernel_activity.csv"
        )
        self.assertEqual(copied_csv.read_text(encoding="utf-8"), "kernel\n")
        command = run_mock.call_args.args[0]
        self.assertIn("--duration", command)
        self.assertIn("30", command)
        self.assertEqual(command[-3:], ["--", "qscope-bench", "run"])

    def test_missing_library_fails_before_launch(self) -> None:
        profiler = NvidiaProcessMetricsProfiler(
            NvidiaProfilingConfig(
                enabled=True,
                library_path=self.root / "missing.so",
            ),
            self.root / "artifacts",
        )

        with self.assertRaisesRegex(NvidiaProfilingError, "library not found"):
            profiler.run(["cuda-hello"])


class NvidiaProfilingCliTests(unittest.TestCase):
    @patch.dict(os.environ, {"QSCOPE_NVIDIA_PROFILING_ACTIVE": ""})
    @patch("quantscope_bench.cli.NvidiaProcessMetricsProfiler")
    @patch("quantscope_bench.cli.load_yaml")
    @patch("quantscope_bench.cli.build_parser")
    def test_enabled_campaign_relaunches_cli_under_profiler(
        self, parser_mock, load_yaml_mock, profiler_mock
    ) -> None:
        output_dir = Path("artifacts/run")
        parser_mock.return_value.parse_args.return_value = SimpleNamespace(
            command="run",
            models=Path("models.yml"),
            campaign=Path("campaign.yml"),
            hardware=Path("hardware.yml"),
            output_dir=output_dir,
            log_level="CRITICAL",
        )
        load_yaml_mock.side_effect = [
            {
                "version": 1,
                "models": {"model": {"backend": "llamacpp", "local_path": "/model.gguf"}},
            },
            {
                "version": 1,
                "model": "model",
                "hardware_profile": "gpu",
                "scoring": ["exact_match"],
                "benchmarks": {"mmlu": {"shots": 0}},
                "profiling": {
                    "enabled": True,
                    "mode": "direct",
                    "library_path": "/opt/nvidia/libnvidia-process-metrics.so",
                },
            },
            {"version": 1, "profiles": {"gpu": {"scheduler": {}}}},
        ]
        profiler_mock.return_value.run.return_value = 0

        status = cli.main(
            [
                "run",
                "--models",
                "models.yml",
                "--campaign",
                "campaign.yml",
                "--hardware",
                "hardware.yml",
                "--output-dir",
                str(output_dir),
            ]
        )

        self.assertEqual(status, 0)
        child_command = profiler_mock.return_value.run.call_args.args[0]
        self.assertEqual(child_command[1:3], ["-m", "quantscope_bench.cli"])
        self.assertIn("--campaign", child_command)
        self.assertIn("campaign.yml", child_command)
