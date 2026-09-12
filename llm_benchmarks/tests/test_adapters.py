from __future__ import annotations

import unittest

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter


class FakeAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=True)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        return "A"

    def score_options(self, prompt: str, options: list[str]) -> list[float]:
        return [float(index) for index, _ in enumerate(options)]


class AdapterContractTests(unittest.TestCase):
    def test_adapter_can_generate_and_score_options(self) -> None:
        adapter = FakeAdapter()

        self.assertEqual(adapter.generate("Question"), "A")
        self.assertEqual(adapter.score_options("Question", ["A", "B"]), [0.0, 1.0])
        self.assertTrue(adapter.capabilities.log_likelihood)