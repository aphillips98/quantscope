"""Best-effort host and NVIDIA GPU inventory without mandatory dependencies."""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
from typing import Any


def collect_platform_inventory() -> dict[str, Any]:
    inventory: dict[str, Any] = {
        "hostname": platform.node(),
        "os": platform.platform(),
        "python": sys.version.split()[0],
        "machine": platform.machine(),
        "cpu_count": __import__("os").cpu_count(),
        "gpus": [],
    }
    if not shutil.which("nvidia-smi"):
        return inventory

    command = [
        "nvidia-smi",
        "--query-gpu=name,uuid,memory.total,driver_version",
        "--format=csv,noheader,nounits",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        inventory["gpu_discovery_error"] = completed.stderr.strip()
        return inventory

    inventory["gpus"] = [
        dict(zip(("name", "uuid", "memory_mb", "driver"), row.split(", ")))
        for row in completed.stdout.splitlines()
        if row.strip()
    ]
    return inventory