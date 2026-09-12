"""vLLM adapter for high-throughput GPU generation."""

from __future__ import annotations

from typing import Any

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter


class VllmAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=False)

    def __init__(self, model: dict[str, Any]) -> None:
        try:
            from vllm import LLM, SamplingParams
        except ImportError as error:
            raise RuntimeError("vLLM backend requires `pip install -e '.[vllm]'`") from error

        source = model.get("local_path") or model["hf_id"]
        inference = model.get("inference", {})
        self._sampling_params = SamplingParams(
            temperature=0.0,
            max_tokens=1,
            stop=["\n"],
        )
        self._sampling_params_max_tokens = SamplingParams(
            temperature=0.0,
            max_tokens=inference.get("max_tokens", 1),
            stop=["\n"],
        )
        self._model = LLM(model=source, dtype=inference.get("dtype", "auto"))

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        params = self._sampling_params if max_tokens == 1 else self._sampling_params_max_tokens
        result = self._model.generate([prompt], params, use_tqdm=False)[0]
        return result.outputs[0].text