"""Command-line entry point for benchmark configuration checks."""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
import sys
from time import perf_counter
from typing import Sequence

from quantscope_bench.config import ConfigurationError, get_model, load_yaml, validate_campaign
from quantscope_bench.telemetry.nvidia_profiling import (
    PROFILED_ENV,
    NvidiaProcessMetricsProfiler,
    NvidiaProfilingConfig,
    NvidiaProfilingError,
)

LOGGER = logging.getLogger(__name__)
_LOG_LEVELS = ("CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qscope-bench")
    subcommands = parser.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate", help="validate a benchmark campaign")
    validate.add_argument("--models", type=Path, required=True)
    validate.add_argument("--campaign", type=Path, required=True)
    validate.add_argument("--hardware", type=Path, required=True)
    validate.add_argument("--log-level", choices=_LOG_LEVELS, default="CRITICAL")
    run = subcommands.add_parser("run", help="run an exact-match DeepEval campaign")
    run.add_argument("--models", type=Path, required=True)
    run.add_argument("--campaign", type=Path, required=True)
    run.add_argument("--hardware", type=Path, required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--log-level", choices=_LOG_LEVELS, default="CRITICAL")
    return parser


def _configure_logging(level_name: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level_name),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    _configure_logging(arguments.log_level)
    LOGGER.debug("Starting %s command", arguments.command)
    try:
        LOGGER.info("Loading benchmark configuration")
        models = load_yaml(arguments.models)
        campaign_document = load_yaml(arguments.campaign)
        hardware = load_yaml(arguments.hardware)
        campaign = validate_campaign(models, campaign_document, hardware)
        LOGGER.info("Validated campaign for model %s", campaign.model_name)
    except ConfigurationError as error:
        print(f"Configuration error: {error}")
        return 2

    model_label = (
        f"model={campaign.model_names[0]}"
        if len(campaign.model_names) == 1
        else f"models={','.join(campaign.model_names)}"
    )
    message = (
        f"Valid campaign: {model_label} backend={campaign.backend} "
        f"profile={campaign.profile_name} "
        f"benchmarks={','.join(campaign.benchmark_names)} "
        f"scoring={','.join(campaign.scoring_methods)}"
    )
    if arguments.command == "validate":
        print(message)
        return 0

    profiling_config = NvidiaProfilingConfig.from_mapping(
        campaign_document.get("profiling")
    )
    if profiling_config.enabled and os.environ.get(PROFILED_ENV) != "1":
        profiler = NvidiaProcessMetricsProfiler(profiling_config, arguments.output_dir)
        command_arguments = list(argv) if argv is not None else sys.argv[1:]
        try:
            return profiler.run(
                [sys.executable, "-m", "quantscope_bench.cli", *command_arguments]
            )
        except NvidiaProfilingError as error:
            print(f"Profiling error: {error}")
            return 2

    if "log_likelihood" in campaign.scoring_methods:
        print("Configuration error: run currently supports exact_match only; use a scoring-specific runner for log_likelihood")
        return 2
    try:
        from quantscope_bench.adapters import create_adapter
        from quantscope_bench.adapters.llamacpp import LlamaCppAdapter
        from quantscope_bench.benchmarks.deepeval import run_deepeval_campaign
        from quantscope_bench.reporting import performance_summary, write_performance_artifacts, write_run_artifacts
        from quantscope_bench.telemetry import collect_platform_inventory
        from quantscope_bench.telemetry.performance import GPUPerformanceMonitor

        results = []
        scores_by_model = {}
        performance_requests = []
        performance_summaries = []
        gpu_samples = []
        for model_name in campaign.model_names:
            LOGGER.info("Creating adapter for model %s", model_name)
            adapter = create_adapter(get_model(models, model_name))
            monitor = None
            try:
                if isinstance(adapter, LlamaCppAdapter):
                    monitor = GPUPerformanceMonitor(
                        campaign_document.get("telemetry", {}).get("sample_interval_seconds", 1.0)
                    )
                    monitor.start()
                LOGGER.info("Running benchmark campaign for model %s", model_name)
                started = perf_counter()
                model_results, model_metadata = run_deepeval_campaign(
                    adapter, campaign_document, "run-1", model_name
                )
                runtime_seconds = perf_counter() - started
                results.extend(model_results)
                scores_by_model[model_name] = model_metadata["benchmark_scores"]
            finally:
                if monitor is not None:
                    monitor.stop()
                adapter.close()
                LOGGER.debug("Closed model adapter %s", model_name)
            if monitor is not None:
                identity = {"run_id": "run-1", "model_name": model_name}
                performance_requests.extend(
                    {**identity, **request} for request in adapter.performance_requests
                )
                performance_summaries.append({
                    **identity,
                    **performance_summary(adapter.performance_requests, runtime_seconds),
                    **monitor.summary(),
                })
                gpu_samples.extend({**identity, **sample} for sample in monitor.samples)
        benchmark_scores = (
            scores_by_model[campaign.model_names[0]]
            if len(campaign.model_names) == 1
            else scores_by_model
        )
        benchmark_metadata = {"benchmark_scores": benchmark_scores}
        LOGGER.info("Writing benchmark artifacts to %s", arguments.output_dir)
        write_run_artifacts(
            arguments.output_dir,
            {
                "campaign": campaign_document,
                "models": list(campaign.model_names),
                "platform": collect_platform_inventory(),
                **benchmark_metadata,
            },
            results,
            bool(campaign_document.get("capture_predictions", False)),
        )
        if performance_summaries:
            write_performance_artifacts(
                arguments.output_dir, performance_requests, performance_summaries, gpu_samples
            )
    except (RuntimeError, ConfigurationError) as error:
        LOGGER.error("Benchmark run failed: %s", error)
        print(f"Run error: {error}")
        return 2
    print(f"{message}; wrote artifacts to {arguments.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())