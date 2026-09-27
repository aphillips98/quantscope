"""Optional DeepEval bridge for MMLU and HellaSwag exact-match runs."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from quantscope_bench.adapters.base import ModelAdapter
from quantscope_bench.reporting import SampleResult
from quantscope_bench.scoring import normalize_choice

LOGGER = logging.getLogger(__name__)

def run_deepeval_campaign(
    adapter: ModelAdapter, campaign: dict[str, Any], run_id: str
) -> tuple[list[SampleResult], dict[str, Any]]:
    """Run configured DeepEval suites and normalize their public result frames."""
    try:
        from deepeval.benchmarks import HellaSwag, MMLU
        from deepeval.benchmarks.tasks import HellaSwagTask, MMLUTask
        from deepeval.models.base_model import DeepEvalBaseLLM
    except ImportError as error:
        raise RuntimeError(
            f"DeepEval import failed ({error}); run `pip install -e '.[deepeval]'`"
        ) from error

    bridge = _make_deepeval_model(DeepEvalBaseLLM, adapter)
    all_results: list[SampleResult] = []
    metadata: dict[str, Any] = {"benchmark_scores": {}}
    for name, options in campaign["benchmarks"].items():
        LOGGER.info("Starting %s benchmark", name)
        task_type = MMLUTask if name == "mmlu" else HellaSwagTask
        benchmark_type = MMLU if name == "mmlu" else HellaSwag
        tasks = [_resolve_task(task_type, task) for task in options.get("tasks", [])]
        benchmark = benchmark_type(tasks=tasks or None, n_shots=options.get("shots", 0))
        benchmark.evaluate(model=bridge, batch_size=options.get("batch_size", 1))
        metadata["benchmark_scores"][name] = float(benchmark.overall_score)
        benchmark_results = _normalize_predictions(benchmark.predictions, name, run_id)
        all_results.extend(benchmark_results)
        LOGGER.info(
            "Completed %s benchmark: score=%.4f samples=%d",
            name,
            metadata["benchmark_scores"][name],
            len(benchmark_results),
        )
    return all_results, metadata


def _make_deepeval_model(base_class: type, adapter: ModelAdapter) -> Any:
    class AdapterDeepEvalModel(base_class):
        def load_model(self) -> ModelAdapter:
            return adapter

        def generate(self, prompt: str) -> str:
            return adapter.generate(prompt)

        def batch_generate(self, prompts: list[str]) -> list[str]:
            return [normalize_choice(adapter.generate(prompt)) for prompt in prompts]

        async def a_generate(self, prompt: str) -> str:
            return await asyncio.to_thread(self.generate, prompt)

        def get_model_name(self) -> str:
            return type(adapter).__name__

    return AdapterDeepEvalModel()


def _resolve_task(task_type: type, task_name: str) -> Any:
    enum_name = task_name.upper().replace("-", "_").replace(" ", "_")
    try:
        return getattr(task_type, enum_name)
    except AttributeError as error:
        raise RuntimeError(f"Unknown DeepEval task {task_name!r} for {task_type.__name__}") from error


def _normalize_predictions(predictions: Any, benchmark: str, run_id: str) -> list[SampleResult]:
    records = predictions.to_dict("records")
    normalized: list[SampleResult] = []
    for index, record in enumerate(records):
        task = str(record.get("Task", record.get("task", "unknown")))
        raw_prediction = str(record.get("Prediction", record.get("prediction", "")))
        expected = str(record.get("Expected Output", record.get("expected_output", ""))).upper()
        correct = bool(record.get("Correct", record.get("correct", False)))
        normalized.append(
            SampleResult(
                run_id=run_id,
                benchmark=benchmark,
                task=task,
                sample_id=str(index),
                scoring_method="exact_match",
                expected_choice=expected,
                predicted_choice=normalize_choice(raw_prediction),
                correct=correct,
                latency_seconds=0.0,
                raw_response=raw_prediction,
            )
        )
    return normalized