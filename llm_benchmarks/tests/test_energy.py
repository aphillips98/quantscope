from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from quantscope_bench.telemetry.energy import (
    RaplEnergySource,
    UnavailableEnergySource,
    delta_reading,
    select_energy_source,
)
from quantscope_bench.telemetry.performance import GPUPerformanceMonitor


class GPUPerformanceTests(unittest.TestCase):
    def test_integrates_power_and_reports_peak_memory(self) -> None:
        monitor = GPUPerformanceMonitor()
        monitor._devices = [("GPU-1", None)]
        monitor.samples = [
            {"gpu_uuid": "GPU-1", "timestamp_seconds": 0.0, "power_watts": 100, "memory_used_mb": 50},
            {"gpu_uuid": "GPU-1", "timestamp_seconds": 2.0, "power_watts": 200, "memory_used_mb": 80},
        ]
        summary = monitor.summary()
        self.assertEqual(summary["gpu_energy_joules_estimated"], 300)
        self.assertEqual(summary["mean_gpu_power_watts_total"], 150)
        self.assertEqual(summary["peak_gpu_memory_mb_per_device"], 80)
        monitor.samples[1]["power_watts"] = None
        self.assertIsNone(monitor.summary()["gpu_energy_joules_estimated"])

    def test_nvml_failure_is_nonfatal(self) -> None:
        nvml = MagicMock()
        nvml.nvmlInit.side_effect = RuntimeError("no driver")
        with patch.dict("sys.modules", {"pynvml": nvml}):
            monitor = GPUPerformanceMonitor()
            monitor.start()
            monitor.stop()
        self.assertIn("no driver", monitor.summary()["gpu_telemetry_detail"])
        self.assertIsNone(monitor.summary()["mean_gpu_power_watts_total"])

    def test_respects_visible_device_uuid_and_samples_memory_without_power(self) -> None:
        nvml = MagicMock()
        nvml.nvmlDeviceGetUUID.return_value = "GPU-1"
        nvml.nvmlDeviceGetPowerUsage.side_effect = RuntimeError("unsupported")
        nvml.nvmlDeviceGetMemoryInfo.return_value.used = 80 * 1024 * 1024
        with patch.dict("sys.modules", {"pynvml": nvml}), patch.dict(
            "os.environ", {"CUDA_VISIBLE_DEVICES": "GPU-1"}
        ):
            monitor = GPUPerformanceMonitor()
            monitor.start()
            monitor.stop()
        nvml.nvmlDeviceGetHandleByUUID.assert_called_once_with("GPU-1")
        self.assertEqual(monitor.summary()["peak_gpu_memory_mb_per_device"], 80)
        self.assertIsNone(monitor.summary()["gpu_energy_joules_estimated"])
        nvml.nvmlShutdown.assert_called_once_with()


class EnergySourceTests(unittest.TestCase):
    def test_reads_rapl_microjoules_as_joules(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            energy_path = root / "intel-rapl:0" / "energy_uj"
            energy_path.parent.mkdir()
            energy_path.write_text("2500000\n", encoding="utf-8")
            source = RaplEnergySource(root)

            self.assertTrue(source.available())
            self.assertEqual(source.read_joules(), 2.5)

    def test_reports_unavailable_or_decreasing_counters(self) -> None:
        source = select_energy_source((UnavailableEnergySource(),))
        self.assertFalse(delta_reading(source, None, None).available)

        rollover = delta_reading(RaplEnergySource(Path("/missing")), 3.0, 2.0)
        self.assertFalse(rollover.available)