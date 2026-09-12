from __future__ import annotations

import unittest

from quantscope_bench.benchmarks.deepeval import _normalize_predictions, _resolve_task


class FakeFrame:
    def to_dict(self, orient: str) -> list[dict[str, object]]:
        self.last_orient = orient
        return [{"Task": "astronomy", "Prediction": "B", "Expected Output": "B", "Correct": 1}]


class FakeTasks:
    ASTRONOMY = "astronomy"


class DeepEvalBridgeTests(unittest.TestCase):
    def test_resolves_yaml_task_name_to_enum(self) -> None:
        self.assertEqual(_resolve_task(FakeTasks, "astronomy"), "astronomy")

    def test_normalizes_prediction_records(self) -> None:
        result = _normalize_predictions(FakeFrame(), "mmlu", "run-1")[0]

        self.assertEqual(result.predicted_choice, "B")
        self.assertTrue(result.correct)