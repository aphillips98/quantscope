#!/usr/bin/env python3
"""Minimal sanity check: run DeepEval's MMLU / HellaSwag benchmarks against GGUF models.

Bypasses the llm_benchmarks harness: starts `llama-server` for each local GGUF
model, wraps it in a DeepEvalBaseLLM, and runs the official DeepEval benchmarks
(https://deepeval.com/docs/benchmarks-mmlu, .../benchmarks-hellaswag).
Every raw model response is kept so you can see what the model actually said.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

LETTERS = "ABCD"
HERE = Path(__file__).resolve().parent
DEFAULT_MODELS_YML = HERE.parent / "llm_benchmarks" / "orfeo_configs" / "models.yml"


# --------------------------------------------------------------------------- model
class LlamaServer:
    """Start llama-server for one GGUF file and query its /completion endpoint."""

    def __init__(self, gguf_path: str, ctx_size: int, gpu_layers: int) -> None:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.base_url = f"http://127.0.0.1:{port}"
        self.log_path = Path(f"/tmp/model_check_llama_server_{port}.log")
        command = [
            "llama-server", "--model", gguf_path,
            "--host", "127.0.0.1", "--port", str(port),
            "--ctx-size", str(ctx_size), "--n-gpu-layers", str(gpu_layers),
            "--flash-attn", "off",
        ]
        self.process = subprocess.Popen(
            command, stdout=self.log_path.open("wb"), stderr=subprocess.STDOUT
        )
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"llama-server exited with code {self.process.returncode}; see {self.log_path}"
                )
            try:
                with urlopen(f"{self.base_url}/health", timeout=2) as response:
                    if response.status == 200:
                        return
            except (HTTPError, URLError, TimeoutError, OSError):
                time.sleep(1)
        self.stop()
        raise RuntimeError(f"llama-server did not become healthy; see {self.log_path}")

    def complete(self, prompt: str, max_tokens: int) -> str:
        payload = json.dumps(
            {"prompt": prompt, "n_predict": max_tokens, "temperature": 0.0, "seed": 42}
        ).encode()
        request = Request(
            f"{self.base_url}/completion", data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urlopen(request, timeout=300) as response:
            return str(json.loads(response.read())["content"])

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def parse_choice(text: str) -> str | None:
    match = re.search(r"\b([ABCD])\b", text.strip().upper())
    return match.group(1) if match else None


def make_deepeval_model(server: LlamaServer, name: str, max_tokens: int):
    """Wrap the local llama-server in a DeepEvalBaseLLM, logging every raw response."""
    from deepeval.models.base_model import DeepEvalBaseLLM

    class LocalServerLLM(DeepEvalBaseLLM):
        def __init__(self) -> None:
            self.calls: list[dict] = []
            super().__init__()

        def load_model(self):
            return server

        def generate(self, prompt: str) -> str:
            raw = server.complete(prompt, max_tokens)
            choice = parse_choice(raw)
            self.calls.append({"raw": raw, "choice": choice})
            return choice or raw.strip()

        def batch_generate(self, prompts: list[str]) -> list[str]:
            return [self.generate(prompt) for prompt in prompts]

        async def a_generate(self, prompt: str) -> str:
            return await asyncio.to_thread(self.generate, prompt)

        def get_model_name(self) -> str:
            return name

    return LocalServerLLM()


# --------------------------------------------------------------------------- main
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", nargs="+", default=[
        "llama3.1-8b-q4_k_m", "phi-3.5-mini-3.8b-q4_k_m",
        "gemma-2-9b-it-q4_k_m", "mistral-7b-instruct-v0.3-q4_k_m",
    ], help="Paths to local .gguf files, or model names from models.yml")
    parser.add_argument("--models-yml", type=Path, default=DEFAULT_MODELS_YML)
    parser.add_argument("--mmlu-task", default="high_school_computer_science",
                        help="MMLUTask name; 'none' to skip MMLU")
    parser.add_argument("--hellaswag-task", default="applying_sunscreen",
                        help="HellaSwagTask name; 'none' to skip HellaSwag")
    parser.add_argument("--shots", type=int, default=5,
                        help="n_shots (MMLU allows at most 5; HellaSwag at most 15)")
    parser.add_argument("--max-tokens", type=int, default=8)
    parser.add_argument("--ctx-size", type=int, default=4096)
    parser.add_argument("--gpu-layers", type=int,
                        default=-1 if os.environ.get("CUDA_VISIBLE_DEVICES") else 0)
    parser.add_argument("--out", type=Path, default=HERE / "check_results.csv")
    args = parser.parse_args()

    from deepeval.benchmarks import MMLU, HellaSwag
    from deepeval.benchmarks.tasks import HellaSwagTask, MMLUTask

    def build_benchmarks():
        benchmarks = []
        if args.mmlu_task.lower() != "none":
            task = getattr(MMLUTask, args.mmlu_task.upper())
            benchmarks.append(("mmlu", MMLU(tasks=[task], n_shots=min(args.shots, 5))))
        if args.hellaswag_task.lower() != "none":
            task = getattr(HellaSwagTask, args.hellaswag_task.upper())
            benchmarks.append(("hellaswag", HellaSwag(tasks=[task], n_shots=args.shots)))
        return benchmarks

    rows, summary = [], []
    for entry in args.models:
        if entry.endswith(".gguf"):
            name, gguf, ctx = Path(entry).stem, entry, args.ctx_size
        else:
            import yaml  # only needed when resolving names via models.yml

            config = yaml.safe_load(args.models_yml.read_text())["models"].get(entry)
            if config is None:
                print(f"!! {entry}: not found in {args.models_yml}, skipping")
                continue
            name, gguf = entry, config["local_path"]
            ctx = config.get("inference", {}).get("context_size", args.ctx_size)
        if not Path(gguf).exists():
            print(f"!! {name}: GGUF not found at {gguf}, skipping")
            continue

        print(f"== {name} ==")
        server = LlamaServer(gguf, ctx, args.gpu_layers)
        try:
            for bench_name, benchmark in build_benchmarks():
                model = make_deepeval_model(server, name, args.max_tokens)
                benchmark.evaluate(model=model)
                score = float(benchmark.overall_score)
                records = benchmark.predictions.to_dict("records")
                for index, record in enumerate(records):
                    raw = model.calls[index]["raw"] if index < len(model.calls) else ""
                    expected = str(record.get("Expected Output", "")).strip().upper()
                    predicted = str(record.get("Prediction", "")).strip().upper()
                    correct = bool(record.get("Correct", predicted == expected))
                    mark = "OK " if correct else "BAD"
                    print(f"  [{mark}] {bench_name:<9} expected={expected} "
                          f"got={predicted} raw={raw!r}")
                    rows.append({
                        "model": name, "benchmark": bench_name,
                        "task": str(record.get("Task", "")),
                        "expected": expected, "predicted": predicted,
                        "correct": correct, "raw": raw,
                    })
                summary.append((name, bench_name, len(records), score))
                print(f"  -> {bench_name}: overall_score={score:.4f} ({len(records)} samples)")
        finally:
            server.stop()
        print()

    print(f"{'model':<34} {'benchmark':<10} {'n':>4} {'score':>7}")
    for name, bench, n, score in summary:
        flag = "" if score > 0.30 else "   <-- at/below random, investigate"
        print(f"{name:<34} {bench:<10} {n:>4} {score:>7.2%}{flag}")

    if rows:
        with args.out.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nDetails written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
