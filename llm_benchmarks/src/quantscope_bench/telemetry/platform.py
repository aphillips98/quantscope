"""Best-effort host and NVIDIA GPU inventory without mandatory dependencies."""

from __future__ import annotations

import logging
import platform
import shutil
import subprocess
import sys
from typing import Any

LOGGER = logging.getLogger(__name__)

def collect_platform_inventory() -> dict[str, Any]:
    LOGGER.debug("Collecting platform inventory")
    inventory: dict[str, Any] = {
        "hostname": platform.node(),
        "os": platform.platform(),
        "python": sys.version.split()[0],
        "machine": platform.machine(),
        "cpu_count": __import__("os").cpu_count(),
        "gpus": [],
    }
    if not shutil.which("nvidia-smi"):
        LOGGER.debug("nvidia-smi not found; skipping GPU discovery")
        return inventory

    command = [
        "nvidia-smi",
        "--query-gpu=name,uuid,memory.total,driver_version",
        "--format=csv,noheader,nounits",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        LOGGER.debug("nvidia-smi failed with code %d: %s", completed.returncode, completed.stderr.strip())
        inventory["gpu_discovery_error"] = completed.stderr.strip()
        return inventory

    inventory["gpus"] = [
        dict(zip(("name", "uuid", "memory_mb", "driver"), row.split(", ")))
        for row in completed.stdout.splitlines()
        if row.strip()
    ]
    LOGGER.debug("Discovered %d GPU(s) via nvidia-smi", len(inventory["gpus"]))
    return inventory