"""Lazy adapter construction so optional backends remain independent."""

from __future__ import annotations

import logging
from typing import Any

from quantscope_bench.adapters.base import ModelAdapter
from quantscope_bench.config import ConfigurationError

LOGGER = logging.getLogger(__name__)

def create_adapter(model: dict[str, Any], *, llamacpp_verbose: bool = False) -> ModelAdapter:
    backend = model["backend"]
    LOGGER.debug("Selecting adapter for backend %s", backend)
    if backend == "llamacpp":
        from quantscope_bench.adapters.llamacpp import LlamaCppAdapter

        LOGGER.debug("Creating LlamaCppAdapter (verbose=%s)", llamacpp_verbose)
        return LlamaCppAdapter(model, verbose=llamacpp_verbose)
    if backend == "transformers":
        from quantscope_bench.adapters.transformers import TransformersAdapter

        LOGGER.debug("Creating TransformersAdapter")
        return TransformersAdapter(model)
    if backend == "vllm":
        from quantscope_bench.adapters.vllm import VllmAdapter

        LOGGER.debug("Creating VllmAdapter")
        return VllmAdapter(model)
    raise ConfigurationError(f"Unsupported backend: {backend}")