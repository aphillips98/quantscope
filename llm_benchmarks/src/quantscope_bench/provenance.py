"""Best-effort provenance with no changes to inference settings."""
from __future__ import annotations
import importlib.metadata
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

def _command(args: list[str]) -> str | None:
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
        return p.stdout.strip() if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None

def collect_provenance(models: dict[str, Any], names: tuple[str, ...] | list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {"git_commit": _command(["git", "rev-parse", "HEAD"]),
                              "llama_server_version": None, "deepeval_version": None,
                              "models": {}}
    server = shutil.which("llama-server")
    if server:
        result["llama_server_path"] = server
        result["llama_server_version"] = _command([server, "--version"])
    try:
        result["deepeval_version"] = importlib.metadata.version("deepeval")
    except importlib.metadata.PackageNotFoundError:
        pass
    from quantscope_bench.config import get_model
    for name in names:
        model = get_model(models, name)
        path = Path(model.get("local_path", ""))
        info = {"inference_effective_config": {"mode": "completion", "max_tokens": 8,
                "temperature": 0.0, "context_size": 4096, "flash_attention": "off",
                "gpu_layers": -1 if os.environ.get("CUDA_VISIBLE_DEVICES") else 0,
                **(model.get("inference") or {})}, "model_path": str(path)}
        if path.is_file():
            stat = path.stat()
            info.update(model_size_bytes=stat.st_size, model_mtime_ns=stat.st_mtime_ns)
        result["models"][name] = info
    return result
