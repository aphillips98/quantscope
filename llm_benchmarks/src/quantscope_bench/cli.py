"""Command-line entry point for benchmark configuration checks."""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
import sys
from time import perf_counter
from typing import Any, Sequence

from quantscope_bench.config import ConfigurationError, ValidatedCampaign, get_model, load_yaml, validate_campaign
from quantscope_bench.logging_config import LOG_LEVELS, configure_logging
from quantscope_bench.telemetry.efimon import EFIMON_ENV, EfimonConfig, EfimonMonitor
from quantscope_bench.telemetry.performance import (
    PROFILED_ENV,
    NvidiaProcessMetricsProfiler,
    NvidiaProfilingConfig,
    NvidiaProfilingError,
)

LOGGER = logging.getLogger(__name__)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qscope-bench")
    subcommands = parser.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate", help="validate a benchmark campaign")
    validate.add_argument("--models", type=Path, required=True)
    validate.add_argument("--campaign", type=Path, required=True)
    validate.add_argument("--hardware", type=Path, required=True)
    validate.add_argument("--log-level", choices=LOG_LEVELS, default="CRITICAL")
    run = subcommands.add_parser("run", help="run an exact-match DeepEval campaign")
    run.add_argument("--models", type=Path, required=True)
    run.add_argument("--campaign", type=Path, required=True)
    run.add_argument("--hardware", type=Path, required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    run.add_argument("--log-level", choices=LOG_LEVELS, default="CRITICAL")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    configure_logging(arguments.log_level)
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

    efimon_config = EfimonConfig.from_mapping(campaign_document.get("efimon"))
    LOGGER.debug(
        "EfiMon enabled=%s; active environment flag=%s",
        efimon_config.enabled,
        os.environ.get(EFIMON_ENV),
    )
    if efimon_config.enabled and os.environ.get(EFIMON_ENV) != "1":
        with EfimonMonitor(efimon_config, arguments.output_dir):
            return _run_campaign(arguments, argv, models, campaign_document, campaign, message)
    return _run_campaign(arguments, argv, models, campaign_document, campaign, message)


def _run_campaign(
    arguments: argparse.Namespace,
    argv: Sequence[str] | None,
    models: dict[str, Any],
    campaign_document: dict[str, Any],
    campaign: ValidatedCampaign,
    message: str,
) -> int:
    profiling_config = NvidiaProfilingConfig.from_mapping(
        campaign_document.get("profiling")
    )
    LOGGER.debug(
        "NVIDIA profiling enabled=%s; active environment flag=%s",
        profiling_config.enabled,
        os.environ.get(PROFILED_ENV),
    )
    if profiling_config.enabled and os.environ.get(PROFILED_ENV) != "1":
        profiler = NvidiaProcessMetricsProfiler(profiling_config, arguments.output_dir)
        command_arguments = list(argv) if argv is not None else sys.argv[1:]
        LOGGER.debug("Re-executing CLI under NVIDIA profiler: %s", command_arguments)
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
        from quantscope_bench.reporting import (
            performance_summary, write_performance_artifacts, write_run_artifacts,
            write_instrumentation_artifacts, write_data_quality_artifacts,
        )
        from quantscope_bench.telemetry import collect_platform_inventory
        from quantscope_bench.telemetry.benchmark_energy import integrate_benchmark_energy
        from quantscope_bench.validation import validate_run
        from quantscope_bench.provenance import collect_provenance
        from quantscope_bench.telemetry.performance import GPUPerformanceMonitor

        results = []
        scores_by_model = {}
        performance_requests = []
        performance_summaries = []
        gpu_samples = []
        generation_traces = []
        benchmark_windows = []
        telemetry_options = campaign_document.get("telemetry") or {}
        telemetry_enabled = telemetry_options.get("enabled", True)
        LOGGER.debug("GPU performance monitor enabled=%s", telemetry_enabled)
        llamacpp_verbose = bool(
            (campaign_document.get("llamacpp") or {}).get("verbose", False)
        )
        LOGGER.debug("llama.cpp verbose logging enabled=%s", llamacpp_verbose)
        repetitions = campaign_document.get("repetitions", 1)
        # Each repetition gets a fresh adapter and monitor. This prevents request
        # IDs and GPU power samples from leaking across independent runs.
        for repetition in range(1, repetitions + 1):
            run_id = f"run-{repetition}"
            for model_name in campaign.model_names:
                LOGGER.info("Starting %s for model %s", run_id, model_name)
                adapter = create_adapter(
                    get_model(models, model_name), llamacpp_verbose=llamacpp_verbose
                )
                monitor = None
                runtime_seconds = 0.0
                try:
                    if telemetry_enabled and isinstance(adapter, LlamaCppAdapter):
                        monitor = GPUPerformanceMonitor(
                            telemetry_options.get("sample_interval_seconds", 1.0)
                        )
                        monitor.start()
                    started = perf_counter()
                    model_results, model_metadata = run_deepeval_campaign(
                        adapter, campaign_document, run_id, model_name
                    )
                    runtime_seconds = perf_counter() - started
                    results.extend(model_results)
                    scores_by_model.setdefault(model_name, {})[run_id] = model_metadata["benchmark_scores"]
                    generation_traces.extend(
                        {**trace, "run_id": run_id, "model_name": model_name}
                        for trace in model_metadata["generation_traces"]
                    )
                    benchmark_windows.extend(
                        {**window, "run_id": run_id, "model_name": model_name}
                        for window in model_metadata["benchmark_windows"]
                    )
                    LOGGER.info("Finished %s/%s in %.3fs (%d results)",
                                model_name, run_id, runtime_seconds, len(model_results))
                finally:
                    if monitor is not None:
                        monitor.stop()
                    adapter.close()
                if monitor is not None:
                    identity = {"run_id": run_id, "model_name": model_name}
                    performance_requests.extend(
                        {**request, **identity} for request in adapter.performance_requests
                    )
                    performance_summaries.append({
                        **identity,
                        **performance_summary(adapter.performance_requests, runtime_seconds),
                        **monitor.summary(),
                    })
                    gpu_samples.extend(
                        {**sample, **identity} for sample in monitor.samples
                    )
        # Never mix power samples from different repetitions when integrating.
        benchmark_gpu_energy = []
        for run_index in range(1, repetitions + 1):
            run_id = f"run-{run_index}"
            for model_name in campaign.model_names:
                model_windows = [w for w in benchmark_windows
                                 if w["model_name"] == model_name and w["run_id"] == run_id]
                model_samples = [s for s in gpu_samples
                                 if s["model_name"] == model_name and s["run_id"] == run_id]
                benchmark_gpu_energy.extend(
                    integrate_benchmark_energy(model_samples, model_windows)
                )
        from quantscope_bench.statistics import write_repetition_statistics
        write_repetition_statistics(
            arguments.output_dir / "statistics", results,
            performance_summaries, benchmark_gpu_energy,
        )
        from quantscope_bench.temporal_quality import write_temporal_quality
        write_temporal_quality(
            arguments.output_dir / "instrumentation", performance_requests, benchmark_windows
        )
        validation = validate_run(results, generation_traces, performance_requests,
                                  benchmark_windows, benchmark_gpu_energy)
        # Preserve the legacy metadata shape for a single repetition.
        if repetitions == 1:
            single_scores = {name: runs["run-1"] for name, runs in scores_by_model.items()}
            benchmark_scores = (
                single_scores[campaign.model_names[0]]
                if len(campaign.model_names) == 1 else single_scores
            )
        else:
            benchmark_scores = scores_by_model
        benchmark_metadata = {"benchmark_scores": benchmark_scores}
        LOGGER.info("Writing benchmark artifacts to %s", arguments.output_dir)
        write_run_artifacts(
            arguments.output_dir / "predictions",
            {
                "campaign": campaign_document,
                "models": list(campaign.model_names),
                "platform": collect_platform_inventory(),
                "provenance": collect_provenance(models, list(campaign.model_names)),
                **benchmark_metadata,
            },
            results,
            bool(campaign_document.get("capture_predictions", False)),
        )
        write_instrumentation_artifacts(
            arguments.output_dir / "instrumentation", generation_traces, benchmark_windows
        )
        write_data_quality_artifacts(
            arguments.output_dir / "instrumentation", validation, benchmark_gpu_energy
        )
        if performance_summaries:
            write_performance_artifacts(
                arguments.output_dir / "performance",
                performance_requests,
                performance_summaries,
                gpu_samples,
            )
    except (RuntimeError, ConfigurationError) as error:
        LOGGER.error("Benchmark run failed: %s", error)
        print(f"Run error: {error}")
        return 2
    print(f"{message}; wrote artifacts to {arguments.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())