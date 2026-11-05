"""Optional DeepEval bridge for MMLU and HellaSwag exact-match runs."""

from __future__ import annotations

import asyncio
import logging
import time
from threading import Lock
from typing import Any

from quantscope_bench.adapters.base import ModelAdapter
from quantscope_bench.reporting import SampleResult
from quantscope_bench.scoring import normalize_choice

LOGGER = logging.getLogger(__name__)

def run_deepeval_campaign(
    adapter: ModelAdapter, campaign: dict[str, Any], run_id: str, model_name: str = ""
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

    generation_traces: list[dict[str, Any]] = []
    trace_lock = Lock()
    active_benchmark = {"name": ""}
    bridge = _make_deepeval_model(DeepEvalBaseLLM, adapter, generation_traces, trace_lock, active_benchmark)
    all_results: list[SampleResult] = []
    metadata: dict[str, Any] = {"benchmark_scores": {}, "benchmark_windows": [], "generation_traces": generation_traces}
    for name, options in campaign["benchmarks"].items():
        LOGGER.info("Starting %s benchmark", name)
        task_type = MMLUTask if name == "mmlu" else HellaSwagTask
        benchmark_type = MMLU if name == "mmlu" else HellaSwag
        tasks = [_resolve_task(task_type, task) for task in options.get("tasks", [])]
        LOGGER.debug(
            "Configured %s with %d explicit task(s), shots=%s, batch_size=%s",
            name,
            len(tasks),
            options.get("shots", 0),
            options.get("batch_size", 1),
        )
        benchmark = benchmark_type(tasks=tasks or None, n_shots=options.get("shots", 0))
        active_benchmark["name"] = name
        started_ns = time.time_ns()
        started = time.perf_counter()
        try:
            benchmark.evaluate(model=bridge, batch_size=options.get("batch_size", 1))
        finally:
            metadata["benchmark_windows"].append({
                "benchmark": name, "model_name": model_name,
                "start_timestamp_ns": started_ns, "end_timestamp_ns": time.time_ns(),
                "duration_seconds": time.perf_counter() - started,
            })
        metadata["benchmark_scores"][name] = float(benchmark.overall_score)
        benchmark_results = _normalize_predictions(
            benchmark.predictions, name, run_id, model_name
        )

        all_results.extend(benchmark_results)
        LOGGER.info(
            "Completed %s benchmark: score=%.4f samples=%d",
            name,
            metadata["benchmark_scores"][name],
            len(benchmark_results),
        )
    return all_results, metadata


def _make_deepeval_model(
    base_class: type, adapter: ModelAdapter, traces: list[dict[str, Any]],
    lock: Lock, active_benchmark: dict[str, str],
) -> Any:
    class AdapterDeepEvalModel(base_class):
        def load_model(self) -> ModelAdapter:
            return adapter

        def generate(self, prompt: str) -> str:
            start_ns = time.time_ns()
            started = time.perf_counter()
            raw = adapter.generate(prompt)
            end_ns = time.time_ns()
            submitted = normalize_choice(raw) or raw.strip()  # Original scoring behavior.
            with lock:
                traces.append({
                    "trace_id": len(traces), "benchmark": active_benchmark["name"],
                    "prompt": prompt, "raw_response": raw,
                    "submitted_response": submitted,
                    "start_timestamp_ns": start_ns, "end_timestamp_ns": end_ns,
                    "latency_seconds": time.perf_counter() - started,
                })
            return submitted

        def batch_generate(self, prompts: list[str]) -> list[str]:
            return [self.generate(prompt) for prompt in prompts]

        async def a_generate(self, prompt: str) -> str:
            return await asyncio.to_thread(self.generate, prompt)

        def get_model_name(self) -> str:
            return type(adapter).__name__

    return AdapterDeepEvalModel()


def _resolve_task(task_type: type, task_name: str) -> Any:
    enum_name = task_name.upper().replace("-", "_").replace(" ", "_")
    LOGGER.debug("Resolving DeepEval task %r to %s.%s", task_name, task_type.__name__, enum_name)
    try:
        return getattr(task_type, enum_name)
    except AttributeError as error:
        raise RuntimeError(f"Unknown DeepEval task {task_name!r} for {task_type.__name__}") from error


def _normalize_predictions(
    predictions: Any, benchmark: str, run_id: str, model_name: str = ""
) -> list[SampleResult]:
    records = predictions.to_dict("records")
    LOGGER.debug("Normalizing %d DeepEval prediction record(s) for %s", len(records), benchmark)
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
                model_name=model_name,
            )
        )
    return normalized