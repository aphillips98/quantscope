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
        self.assertEqual(validated.model_names, ("model",))
        self.assertEqual(validated.benchmark_names, ("mmlu", "hellaswag"))

    def test_accepts_direct_nvidia_profiling_configuration(self) -> None:
        self.campaign["profiling"] = {
            "enabled": True,
            "mode": "direct",
            "library_path": "/opt/nvidia-profiling/lib/libnvidia-process-metrics.so",
        }

        validated = validate_campaign(self.models, self.campaign, self.hardware)

        self.assertEqual(validated.backend, "llamacpp")

    def test_rejects_daemon_profiling_without_duration(self) -> None:
        self.campaign["profiling"] = {
            "enabled": True,
            "mode": "daemon",
            "library_path": "/opt/nvidia-profiling/lib/libnvidia-process-metrics.so",
        }

        with self.assertRaisesRegex(ConfigurationError, "duration_seconds"):
            validate_campaign(self.models, self.campaign, self.hardware)

    def test_accepts_multiple_models(self) -> None:
        self.models["models"]["other"] = self.models["models"]["model"]
        self.campaign.pop("model")
        self.campaign["models"] = ["model", "other"]

        validated = validate_campaign(self.models, self.campaign, self.hardware)

        self.assertEqual(validated.model_names, ("model", "other"))

    def test_rejects_both_model_fields(self) -> None:
        self.campaign["models"] = ["model"]

        with self.assertRaisesRegex(ConfigurationError, "either model or models"):
            validate_campaign(self.models, self.campaign, self.hardware)

    def test_rejects_mmlu_shots_above_limit(self) -> None:
        self.campaign["benchmarks"]["mmlu"]["shots"] = 6

        with self.assertRaisesRegex(ConfigurationError, "at most 5 shots"):
            validate_campaign(self.models, self.campaign, self.hardware)

    def test_rejects_ambiguous_model_source(self) -> None:
        self.models["models"]["model"]["hf_id"] = "organization/model"

        with self.assertRaisesRegex(ConfigurationError, "exactly one"):
            validate_campaign(self.models, self.campaign, self.hardware)