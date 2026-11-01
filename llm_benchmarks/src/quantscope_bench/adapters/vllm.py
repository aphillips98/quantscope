"""vLLM adapter for high-throughput GPU generation."""

from __future__ import annotations

import logging
from typing import Any

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter

LOGGER = logging.getLogger(__name__)


class VllmAdapter(ModelAdapter):
    capabilities = AdapterCapabilities(log_likelihood=False)

    def __init__(self, model: dict[str, Any]) -> None:
        try:
            from vllm import LLM, SamplingParams
        except ImportError as error:
            raise RuntimeError("vLLM backend requires `pip install -e '.[vllm]'`") from error

        source = model.get("local_path") or model["hf_id"]
        inference = model.get("inference", {})
        max_tokens = inference.get("max_tokens", 8)
        LOGGER.debug(
            "Loading vLLM model from %s (dtype=%s, max_tokens=%s)",
            source,
            inference.get("dtype", "auto"),
            max_tokens,
        )
        self._sampling_params = SamplingParams(
            temperature=0.0,
            max_tokens=max_tokens,
        )
        self._model = LLM(model=source, dtype=inference.get("dtype", "auto"))
        LOGGER.debug("vLLM model loaded from %s", source)

    def generate(self, prompt: str, max_tokens: int = 1) -> str:
        from vllm import SamplingParams

        params = (
            self._sampling_params
            if max_tokens == 1
            else SamplingParams(temperature=0.0, max_tokens=max_tokens)
        )
        LOGGER.debug("Generating completion: prompt_chars=%d max_tokens=%d", len(prompt), max_tokens)
        result = self._model.generate([prompt], params, use_tqdm=False)[0]
        text = result.outputs[0].text
        LOGGER.debug("vLLM generated response: %r", text)
        return text