from __future__ import annotations

import unittest

from quantscope_bench.config import ConfigurationError, validate_campaign


class ValidateCampaignTests(unittest.TestCase):
    def setUp(self) -> None:
        self.models = {
            "version": 1,
            "models": {"model": {"backend": "llamacpp", "local_path": "/models/model.gguf"}},
        }
        self.hardware = {"version": 1, "profiles": {"cpu": {"scheduler": {}}}}
        self.campaign = {
            "version": 1,
            "model": "model",
            "hardware_profile": "cpu",
            "repetitions": 1,
            "scoring": ["exact_match"],
            "benchmarks": {"mmlu": {"shots": 5}, "hellaswag": {"shots": 15}},
        }

    def test_accepts_valid_campaign(self) -> None:
        validated = validate_campaign(self.models, self.campaign, self.hardware)

        self.assertEqual(validated.backend, "llamacpp")
        self.assertEqual(validated.benchmark_names, ("mmlu", "hellaswag"))

    def test_rejects_mmlu_shots_above_limit(self) -> None:
        self.campaign["benchmarks"]["mmlu"]["shots"] = 6

        with self.assertRaisesRegex(ConfigurationError, "at most 5 shots"):
            validate_campaign(self.models, self.campaign, self.hardware)

    def test_rejects_ambiguous_model_source(self) -> None:
        self.models["models"]["model"]["hf_id"] = "organization/model"

        with self.assertRaisesRegex(ConfigurationError, "exactly one"):
            validate_campaign(self.models, self.campaign, self.hardware)