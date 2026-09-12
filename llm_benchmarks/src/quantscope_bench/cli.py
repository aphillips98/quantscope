"""Command-line entry point for benchmark configuration checks."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Sequence

from quantscope_bench.config import ConfigurationError, get_model, load_yaml, validate_campaign


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="qscope-bench")
    subcommands = parser.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate", help="validate a benchmark campaign")
    validate.add_argument("--models", type=Path, required=True)
    validate.add_argument("--campaign", type=Path, required=True)
    validate.add_argument("--hardware", type=Path, required=True)
    run = subcommands.add_parser("run", help="run an exact-match DeepEval campaign")
    run.add_argument("--models", type=Path, required=True)
    run.add_argument("--campaign", type=Path, required=True)
    run.add_argument("--hardware", type=Path, required=True)
    run.add_argument("--output-dir", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        models = load_yaml(arguments.models)
        campaign_document = load_yaml(arguments.campaign)
        hardware = load_yaml(arguments.hardware)
        campaign = validate_campaign(models, campaign_document, hardware)
    except ConfigurationError as error:
        print(f"Configuration error: {error}")
        return 2

    message = (
        "Valid campaign: "
        f"model={campaign.model_name} backend={campaign.backend} "
        f"profile={campaign.profile_name} "
        f"benchmarks={','.join(campaign.benchmark_names)} "
        f"scoring={','.join(campaign.scoring_methods)}"
    )
    if arguments.command == "validate":
        print(message)
        return 0

    if "log_likelihood" in campaign.scoring_methods:
        print("Configuration error: run currently supports exact_match only; use a scoring-specific runner for log_likelihood")
        return 2
    try:
        from quantscope_bench.adapters import create_adapter
        from quantscope_bench.benchmarks.deepeval import run_deepeval_campaign
        from quantscope_bench.reporting import write_run_artifacts
        from quantscope_bench.telemetry import collect_platform_inventory

        adapter = create_adapter(get_model(models, campaign.model_name))
        try:
            results, benchmark_metadata = run_deepeval_campaign(adapter, campaign_document, "run-1")
        finally:
            adapter.close()
        write_run_artifacts(
            arguments.output_dir,
            {"campaign": campaign_document, "platform": collect_platform_inventory(), **benchmark_metadata},
            results,
            bool(campaign_document.get("capture_predictions", False)),
        )
    except (RuntimeError, ConfigurationError) as error:
        print(f"Run error: {error}")
        return 2
    print(f"{message}; wrote artifacts to {arguments.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())