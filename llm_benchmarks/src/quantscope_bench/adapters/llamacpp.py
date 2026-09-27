"""GGUF adapter backed by llama-cpp-python."""

from __future__ import annotations

from typing import Any

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter

class LlamaCppAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=False)

    def __init__(self, model: dict[str, Any]) -> None:
        try:
            from llama_cpp import Llama
        except ImportError as error:
            raise RuntimeError(
                "llama.cpp backend requires `pip install -e '.[llamacpp]'`"
            ) from error

        inference = model.get("inference", {})
        self._model = Llama(
            model_path=model["local_path"],
            n_ctx=inference.get("context_size", 4096),
            n_gpu_layers=inference.get("gpu_layers", 0),
            verbose=False,
        )
        self._temperature = inference.get("temperature", 0.0)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        response = self._model.create_completion(
            prompt=prompt,
            max_tokens=max_tokens,
            temperature=self._temperature,
            stop=["\n"],
        )
        return str(response["choices"][0]["text"])