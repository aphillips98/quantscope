from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter
from quantscope_bench.adapters.llamacpp import LlamaCppAdapter
from quantscope_bench.cli import main
from quantscope_bench.reporting import performance_summary, write_performance_artifacts, write_run_artifacts
from quantscope_bench.runner import MultipleChoiceSample, evaluate_samples


class FakeAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=True)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        return "The answer is B"

    def score_options(self, prompt: str, options: tuple[str, ...]) -> list[float]:
        return [-4.0, -0.1, -3.0, -2.0]


class RunnerTests(unittest.TestCase):
    def test_summarizes_performance_using_weighted_token_timings(self) -> None:
        requests = [
            {"latency_seconds": 1.0, "prompt_tokens": 100, "generated_tokens": 2,
             "prompt_seconds": 0.5, "generation_seconds": 0.0},
            {"latency_seconds": 3.0, "prompt_tokens": 300, "generated_tokens": 3,
             "prompt_seconds": 1.5, "generation_seconds": 0.5},
        ]
        summary = performance_summary(requests, 10.0)
        self.assertEqual(summary["mean_latency_seconds"], 2.0)
        self.assertEqual(summary["median_latency_seconds"], 2.0)
        self.assertEqual(summary["p95_latency_seconds"], 3.0)
        self.assertEqual(summary["benchmark_runtime_seconds"], 10.0)
        self.assertEqual(summary["prompt_tokens_per_second"], 200.0)
        self.assertEqual(summary["generation_tokens_per_second"], 6.0)
        self.assertEqual(summary["generation_timed_requests"], 1)
        self.assertIsNone(performance_summary([], 0.0)["mean_latency_seconds"])

    def test_writes_performance_files_separately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            write_performance_artifacts(
                output_dir, [{"model_name": "model", "latency_seconds": 0.25}],
                [{"model_name": "model", "mean_latency_seconds": 0.25}], []
            )
            with (output_dir / "performance_requests.csv").open(newline="") as source:
                self.assertEqual(list(csv.DictReader(source))[0]["latency_seconds"], "0.25")
            self.assertTrue((output_dir / "performance_summary.csv").exists())
            self.assertFalse((output_dir / "summary.csv").exists())
            with (output_dir / "gpu_samples.csv").open(newline="") as source:
                self.assertEqual(list(csv.DictReader(source)), [])

    def test_cli_adds_performance_only_for_llamacpp_and_keeps_accuracy_artifacts(self) -> None:
        models = {"version": 1, "models": {
            "model": {"backend": "llamacpp", "local_path": "model.gguf"}
        }}
        campaign = {"version": 1, "model": "model", "hardware_profile": "cpu",
                    "scoring": ["exact_match"], "benchmarks": {"mmlu": {"shots": 0}}}
        hardware = {"version": 1, "profiles": {"cpu": {"scheduler": {}}}}
        for capture in (True, False):
            with self.subTest(capture=capture), tempfile.TemporaryDirectory() as directory:
                adapter = LlamaCppAdapter.__new__(LlamaCppAdapter) if capture else FakeAdapter()
                adapter.close = MagicMock()
                if capture:
                    adapter.performance_requests = [{
                        "request_id": 0, "backend": "llama-server", "latency_seconds": 0.25,
                        "prompt_tokens": 100, "generated_tokens": 1,
                        "prompt_seconds": 0.125, "generation_seconds": 0.0,
                    }]
                result = evaluate_samples(FakeAdapter(), [MultipleChoiceSample(
                    "mmlu", "astronomy", "0", "Question", ("A", "B"), "B"
                )], ("exact_match",), "run-1", "model")
                with patch("quantscope_bench.cli.load_yaml", side_effect=[models, campaign, hardware]), patch(
                    "quantscope_bench.adapters.create_adapter", return_value=adapter
                ), patch(
                    "quantscope_bench.benchmarks.deepeval.run_deepeval_campaign",
                    return_value=(result, {"benchmark_scores": {"mmlu": 1.0}})
                ), patch("quantscope_bench.telemetry.collect_platform_inventory", return_value={}), patch(
                    "quantscope_bench.telemetry.performance.GPUPerformanceMonitor"
                ) as monitor_type, patch("builtins.print"):
                    monitor_type.return_value.summary.return_value = {"gpu_telemetry_detail": "unavailable"}
                    monitor_type.return_value.samples = []
                    status = main(["run", "--models", "models.yml", "--campaign", "campaign.yml",
                                   "--hardware", "hardware.yml", "--output-dir", directory])
                self.assertEqual(status, 0)
                adapter.close.assert_called_once_with()
                output_dir = Path(directory)
                with (output_dir / "summary.csv").open(newline="") as source:
                    self.assertEqual(list(csv.DictReader(source))[0]["accuracy"], "1.0")
                self.assertEqual((output_dir / "performance_summary.csv").exists(), capture)
                if capture:
                    monitor_type.return_value.start.assert_called_once_with()
                    monitor_type.return_value.stop.assert_called_once_with()
                    with (output_dir / "performance_requests.csv").open(newline="") as source:
                        self.assertEqual(list(csv.DictReader(source))[0]["model_name"], "model")
                else:
                    monitor_type.assert_not_called()

    def test_evaluates_and_writes_auditable_artifacts(self) -> None:
        samples = [
            MultipleChoiceSample(
                benchmark="mmlu",
                task="astronomy",
                sample_id="example-1",
                prompt="Question\nAnswer:",
                options=("A", "B", "C", "D"),
                expected_choice="B",
            )
        ]
        results = evaluate_samples(
            FakeAdapter(), samples, ("exact_match", "log_likelihood"), "run-1", "model-a"
        )
        results.extend(
            evaluate_samples(
                FakeAdapter(), samples, ("exact_match", "log_likelihood"), "run-1", "model-b"
            )
        )

        self.assertTrue(all(result.correct for result in results))
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            write_run_artifacts(output_dir, {"run_id": "run-1"}, results, True)

            self.assertEqual(json.loads((output_dir / "metadata.json").read_text())["run_id"], "run-1")
            with (output_dir / "summary.csv").open(newline="") as summary:
                summary_rows = list(csv.DictReader(summary))
                self.assertEqual(len(summary_rows), 4)
                self.assertEqual({row["model_name"] for row in summary_rows}, {"model-a", "model-b"})
            self.assertTrue((output_dir / "predictions.jsonl").exists())