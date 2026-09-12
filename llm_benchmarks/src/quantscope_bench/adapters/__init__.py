"""Backend-neutral model adapter interfaces and implementations."""

from quantscope_bench.adapters.base import AdapterCapabilities, ModelAdapter
from quantscope_bench.adapters.factory import create_adapter

__all__ = ["AdapterCapabilities", "ModelAdapter", "create_adapter"]