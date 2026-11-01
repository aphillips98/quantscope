"""GGUF adapter backed by llama-cpp-python."""

from __future__ import annotations

import json
import logging
import os
import shutil
import socket
import subprocess
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter

LOGGER = logging.getLogger(__name__)


class LlamaCppAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=False)

    def __init__(self, model: dict[str, Any]) -> None:
        inference = model.get("inference", {})
        flash_attention = inference.get("flash_attention", "off")
        if isinstance(flash_attention, bool):
            flash_attention = "on" if flash_attention else "off"
        if flash_attention not in ("on", "off", "auto"):
            raise ValueError("inference.flash_attention must be on, off, auto, or a boolean")
        self._flash_attention = flash_attention
        self._max_tokens = inference.get("max_tokens", 8)
        self._seed = inference.get("seed")
        self._server_process: subprocess.Popen[bytes] | None = None
        self.performance_requests: list[dict[str, Any]] = []
        server = shutil.which("llama-server")
        if server:
            LOGGER.debug("Using llama-server binary at %s", server)
            self._temperature = inference.get("temperature", 0.0)
            self._base_url = self._start_server(server, model, inference)
            return

        LOGGER.debug("llama-server not found; falling back to in-process llama-cpp-python")
        try:
            from llama_cpp import Llama
        except ImportError as error:
            raise RuntimeError(
                "llama.cpp backend requires `pip install -e '.[llamacpp]'`"
            ) from error

        LOGGER.debug(
            "Loading GGUF model %s (context_size=%s, gpu_layers=%s, flash_attn=%s)",
            model["local_path"],
            inference.get("context_size", 4096),
            inference.get("gpu_layers", 0),
            self._flash_attention,
        )
        self._model = Llama(
            model_path=model["local_path"],
            n_ctx=inference.get("context_size", 4096),
            n_gpu_layers=inference.get("gpu_layers", 0),
            flash_attn=self._flash_attention == "on",
            verbose=False,
        )
        self._temperature = inference.get("temperature", 0.0)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        started = time.perf_counter()
        generation_tokens = self._max_tokens if max_tokens == 1 else max_tokens
        LOGGER.debug(
            "Generating completion: prompt_chars=%d max_tokens=%d via %s",
            len(prompt),
            generation_tokens,
            "llama-server" if self._server_process is not None else "llama-cpp-python",
        )
        if self._server_process is not None:
            completion: dict[str, Any] = {
                "prompt": prompt,
                "n_predict": generation_tokens,
                "temperature": self._temperature,
            }
            if self._seed is not None:
                completion["seed"] = self._seed
            payload = json.dumps(completion).encode("utf-8")
            request = Request(
                f"{self._base_url}/completion",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(request, timeout=300) as response:
                result = json.loads(response.read())
            text = str(result["content"])
            self._record_performance(started, result, "llama-server")
            return text

        response = self._model.create_completion(
            prompt=prompt,
            max_tokens=generation_tokens,
            temperature=self._temperature,
            **({"seed": self._seed} if self._seed is not None else {}),
        )
        text = str(response["choices"][0]["text"])
        self._record_performance(started, response, "llama-cpp-python")
        return text

    def _record_performance(
        self, started: float, response: dict[str, Any], backend: str
    ) -> None:
        latency = time.perf_counter() - started
        timings = response.get("timings") or {}
        usage = response.get("usage") or {}
        if not isinstance(timings, dict):
            timings = {}
        if not isinstance(usage, dict):
            usage = {}
        values = {
            "prompt_tokens": timings.get("prompt_n", usage.get("prompt_tokens")),
            "generated_tokens": timings.get("predicted_n", usage.get("completion_tokens")),
            "prompt_seconds": timings.get("prompt_ms"),
            "generation_seconds": timings.get("predicted_ms"),
        }
        values = {
            key: float(value) if isinstance(value, (int, float)) and value >= 0 else None
            for key, value in values.items()
        }
        for key in ("prompt_seconds", "generation_seconds"):
            if values[key] is not None:
                values[key] /= 1000
        self.performance_requests.append(
            {"request_id": len(self.performance_requests), "backend": backend,
             "latency_seconds": latency, **values}
        )
        LOGGER.debug(
            "Recorded %s request %d: latency=%.3fs prompt_tokens=%s generated_tokens=%s",
            backend,
            len(self.performance_requests) - 1,
            latency,
            values["prompt_tokens"],
            values["generated_tokens"],
        )

    def close(self) -> None:
        process = getattr(self, "_server_process", None)
        if process is None or process.poll() is not None:
            return
        LOGGER.debug("Terminating llama-server process %d", process.pid)
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            LOGGER.debug("llama-server did not terminate in time; killing process %d", process.pid)
            process.kill()
            process.wait()

    def _start_server(
        self, server: str, model: dict[str, Any], inference: dict[str, Any]
    ) -> str:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base_url = f"http://127.0.0.1:{port}"
        gpu_layers = inference.get(
            "gpu_layers", -1 if os.environ.get("CUDA_VISIBLE_DEVICES") else 0
        )
        command = [
            server,
            "--model",
            model["local_path"],
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--ctx-size",
            str(inference.get("context_size", 4096)),
            "--n-gpu-layers",
            str(gpu_layers),
            "--flash-attn",
            self._flash_attention,
        ]
        self._server_process = subprocess.Popen(command, stdout=subprocess.DEVNULL)
        LOGGER.debug("Started llama-server pid %d at %s", self._server_process.pid, base_url)
        deadline = time.monotonic() + inference.get("startup_timeout", 300)
        while time.monotonic() < deadline:
            if self._server_process.poll() is not None:
                raise RuntimeError(
                    f"llama-server exited during startup with code {self._server_process.returncode}"
                )
            try:
                with urlopen(f"{base_url}/health", timeout=2) as response:
                    if response.status == 200:
                        LOGGER.debug("llama-server is healthy at %s", base_url)
                        return base_url
            except (HTTPError, URLError, TimeoutError):
                LOGGER.debug("llama-server not ready yet; retrying health check at %s", base_url)
                time.sleep(1)
        self.close()
        raise RuntimeError(
            f"llama-server did not become ready within {inference.get('startup_timeout', 300)} seconds"
        )