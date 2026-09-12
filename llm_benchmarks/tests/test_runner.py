from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter
from quantscope_bench.reporting import write_run_artifacts
from quantscope_bench.runner import MultipleChoiceSample, evaluate_samples


class FakeAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=True)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        return "The answer is B"

    def score_options(self, prompt: str, options: tuple[str, ...]) -> list[float]:
        return [-4.0, -0.1, -3.0, -2.0]


class RunnerTests(unittest.TestCase):
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
            FakeAdapter(), samples, ("exact_match", "log_likelihood"), "run-1"
        )

        self.assertTrue(all(result.correct for result in results))
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            write_run_artifacts(output_dir, {"run_id": "run-1"}, results, True)

            self.assertEqual(json.loads((output_dir / "metadata.json").read_text())["run_id"], "run-1")
            with (output_dir / "summary.csv").open(newline="") as summary:
                self.assertEqual(len(list(csv.DictReader(summary))), 2)
            self.assertTrue((output_dir / "predictions.jsonl").exists())