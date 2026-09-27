"""Backend-neutral evaluator for normalized multiple-choice samples."""

from __future__ import annotations

from dataclasses import dataclass
import logging
from time import perf_counter
from typing import Iterable

from quantscope_bench.adapters.base import ModelAdapter
from quantscope_bench.reporting import SampleResult
from quantscope_bench.scoring import best_option, exact_match, normalize_choice

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class MultipleChoiceSample:
    benchmark: str
    task: str
    sample_id: str
    prompt: str
    options: tuple[str, ...]
    expected_choice: str


def evaluate_samples(
    adapter: ModelAdapter,
    samples: Iterable[MultipleChoiceSample],
    scoring_methods: tuple[str, ...],
    run_id: str,
) -> list[SampleResult]:
    """Evaluate samples once per selected scoring method."""
    results: list[SampleResult] = []
    for sample in samples:
        LOGGER.debug("Evaluating %s/%s sample %s", sample.benchmark, sample.task, sample.sample_id)
        if "exact_match" in scoring_methods:
            started = perf_counter()
            response = adapter.generate(sample.prompt)
            latency = perf_counter() - started
            prediction = normalize_choice(response)
            results.append(
                SampleResult(
                    run_id=run_id,
                    benchmark=sample.benchmark,
                    task=sample.task,
                    sample_id=sample.sample_id,
                    scoring_method="exact_match",
                    expected_choice=sample.expected_choice,
                    predicted_choice=prediction,
                    correct=exact_match(response, sample.expected_choice),
                    latency_seconds=latency,
                    raw_response=response,
                )
            )
            LOGGER.debug("Completed exact_match for sample %s in %.3fs", sample.sample_id, latency)
        if "log_likelihood" in scoring_methods:
            if not adapter.capabilities.log_likelihood:
                raise RuntimeError("Selected adapter does not support log_likelihood scoring")
            started = perf_counter()
            scores = adapter.score_options(sample.prompt, sample.options)
            latency = perf_counter() - started
            option_index = best_option(scores)
            prediction = chr(ord("A") + option_index)
            results.append(
                SampleResult(
                    run_id=run_id,
                    benchmark=sample.benchmark,
                    task=sample.task,
                    sample_id=sample.sample_id,
                    scoring_method="log_likelihood",
                    expected_choice=sample.expected_choice,
                    predicted_choice=prediction,
                    correct=prediction == sample.expected_choice,
                    latency_seconds=latency,
                    option_scores=tuple(scores),
                )
            )
            LOGGER.debug("Completed log_likelihood for sample %s in %.3fs", sample.sample_id, latency)
    LOGGER.info("Evaluated %d result rows", len(results))
    return results