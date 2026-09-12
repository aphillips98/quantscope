"""Lazy adapter construction so optional backends remain independent."""

from __future__ import annotations

from typing import Any

from quantscope_bench.adapters.base import ModelAdapter
from quantscope_bench.config import ConfigurationError


def create_adapter(model: dict[str, Any]) -> ModelAdapter:
    backend = model["backend"]
    if backend == "llamacpp":
        from quantscope_bench.adapters.llamacpp import LlamaCppAdapter

        return LlamaCppAdapter(model)
    if backend == "transformers":
        from quantscope_bench.adapters.transformers import TransformersAdapter

        return TransformersAdapter(model)
    if backend == "vllm":
        from quantscope_bench.adapters.vllm import VllmAdapter

        return VllmAdapter(model)
    raise ConfigurationError(f"Unsupported backend: {backend}")