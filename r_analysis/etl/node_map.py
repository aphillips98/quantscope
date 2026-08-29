"""Static mapping of measurement nodes to experimental factor levels.

The raw efimon data does not store the CPU/GPU architecture or execution mode
as columns; those factors are derived from the node the data was collected on.
This module is the single source of truth for that mapping and is imported by
``energy_etl.py``.

Execution mode currently has two levels (CPU-only, GPU-only). The CPU-GPU
hybrid mode will be added later once the collection scripts encode ``-ngl``.
"""

import re

# node_key -> factor levels
#   cpu_arch : AMD | Intel
#   gpu_arch : None | V100 | A100 | H100
#   exec_mode: CPU-only | GPU-only   (CPU-GPU added later)
NODE_MAP = {
    "EPYC008":     {"cpu_arch": "AMD",   "gpu_arch": "None", "exec_mode": "CPU-only"},
    "GENOA013":    {"cpu_arch": "AMD",   "gpu_arch": "None", "exec_mode": "CPU-only"},
    "THIN007":     {"cpu_arch": "Intel", "gpu_arch": "None", "exec_mode": "CPU-only"},
    "GPU_CPU":     {"cpu_arch": "Intel", "gpu_arch": "None", "exec_mode": "CPU-only"},
    "GPU_V100":    {"cpu_arch": "Intel", "gpu_arch": "V100", "exec_mode": "GPU-only"},
    "DGX002_A100": {"cpu_arch": "AMD",   "gpu_arch": "A100", "exec_mode": "GPU-only"},
    "DGX003_H100": {"cpu_arch": "AMD",   "gpu_arch": "H100", "exec_mode": "GPU-only"},
}

# Canonical model family (from the gguf basename) -> (display name, size in billions
# of parameters). Size is the total parameter count; for the MoE Mixtral model the
# total (not active) parameter count is used.
MODEL_MAP = {
    "gemma-2-9b-it":                          ("Gemma-2-9B",      9.0),
    "Meta-Llama-3.1-8B-Instruct":             ("Llama-3.1-8B",    8.0),
    "Mistral-7B-Instruct-v0.3":               ("Mistral-7B",      7.0),
    "mixtral-8x7b-instruct-v0.1":             ("Mixtral-8x7B",    46.7),
    "Phi-3.5-mini-3.8B-ArliAI-RPMax-v1.1":    ("Phi-3.5-mini-3.8B", 3.8),
}

# Quantization label -> approximate effective bits-per-weight (numeric surrogate
# used for ordered/continuous modelling in the regression stage).
QUANT_BITS = {
    "Q2_K":   2.6,
    "Q4_K_M": 4.5,
    "Q5_K_M": 5.5,
    "Q6_K":   6.6,
    "Q8_0":   8.5,
}

# The four quantization levels required by the study. Q2_K is present in the data
# but treated as an optional extra level (toggle in energy_etl.py / R config).
PRIMARY_QUANTS = ["Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0"]


# Set of canonical display names for the five study model families.
KNOWN_MODEL_FAMILIES = {name for name, _ in MODEL_MAP.values()}


def resolve_node(node_key):
    """Return the factor dict for a node key, or a safe 'unknown' default."""
    return NODE_MAP.get(
        node_key,
        {"cpu_arch": "Unknown", "gpu_arch": "Unknown", "exec_mode": "Unknown"},
    )


# Run/zip names look like ``llamacpp_<HW>_<date>_<time>_<jobid>[.zip]`` where the
# hardware token <HW> is itself a node key that may contain underscores (e.g.
# ``DGX002_A100``). Matching against the known keys first avoids ambiguity.
_RUN_NAME_RE = re.compile(
    r"^llamacpp_(?P<hw>.+)_\d{8}_\d{6}_\d+(?:_iter\d+)?$"
)


def node_key_from_run_name(name):
    """Extract the node key from a run directory or zip file name.

    Returns the matching NODE_MAP key, or the raw parsed <HW> token if it is not
    a known node, or ``None`` if the name does not follow the expected pattern.
    """
    base = name[:-4] if name.endswith(".zip") else name
    for key in NODE_MAP:
        if base.startswith("llamacpp_" + key + "_") or base == "llamacpp_" + key:
            return key
    m = _RUN_NAME_RE.match(base)
    if m:
        return m.group("hw")
    return None


def resolve_model(model_spec):
    """Map a raw model spec (gguf basename without quant) to (family, size_b).

    Falls back to the raw spec and NaN size if it is not recognised.
    """
    if model_spec in MODEL_MAP:
        return MODEL_MAP[model_spec]
    # tolerant matching for minor naming drift
    for key, val in MODEL_MAP.items():
        if key.lower() in model_spec.lower() or model_spec.lower() in key.lower():
            return val
    return (model_spec, float("nan"))
