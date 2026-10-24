# QuantScope LLM Benchmarks

Standalone benchmark runner for MMLU and HellaSwag on CPU and NVIDIA GPUs, including A100 and H100-style profiles. The goal is to validate the configuration before any real workload runs and provide a reproducible baseline for HPC environments.

## What it includes

- Validation of benchmark campaigns using versioned YAML.
- Support for backends: `llamacpp`, `transformers`, and `vllm`.
- Separate configuration for models, hardware, and campaigns.
- Benchmark execution via DeepEval and artifact writing.
- SLURM profile support at the hardware layer.

## Requirements

- Python 3.10+
- [`uv`](https://docs.astral.sh/uv/) (recommended) or standard `pip` with `venv`
- Backend dependencies for the target setup:
  - `transformers`
  - `llamacpp`
  - `vllm`
  - `telemetry` (optional for platform and energy collection)
  - `dev` (optional for running tests)

## Installation

### Automated install with `uv` (detecting loaded modules)

If you load your cluster's environment modules (e.g. `cuda` and `llamacpp` prebuilt by `hpc_area_setup`), the benchmark uses the module's `llama-server` executable:

```bash
module use ~/.local/modules
module load cuda H100/llamacpp_cuda/py035   # A100: A100/llamacpp_cuda/py035; CPU: EPYC/llamacpp/py035

cd llm_benchmarks
./install_env.sh
```

The installer detects `llama-server` in `PATH` and does not build `llama-cpp-python`. The adapter starts the server for the local GGUF model, sends completions over its local HTTP API, and stops the process when the run ends. If `llama-server` is unavailable, the adapter retains its `llama-cpp-python` fallback.

Flash Attention defaults to `off` in both llama.cpp paths to avoid CUDA attention-kernel failures on V100/Volta setups. Set `inference.flash_attention: "on"` in a model definition to enable it on a compatible build and GPU, or `"auto"` to use llama-server's automatic selection. The Python fallback enables it only for `"on"`. Quote these values in YAML; booleans are also accepted. A `volta_mma_available(cc)` assertion followed by `RemoteDisconnected` means the server crashed, not that Hugging Face authentication failed.

### Manual `uv` install

From the project root:

```bash
cd llm_benchmarks
uv venv .venv
source .venv/bin/activate
uv pip install -e .
```

If you plan to use a specific backend or development tools, install the matching extra:

```bash
uv pip install -e '.[deepeval,transformers,telemetry]'
uv pip install -e '.[deepeval,llamacpp,telemetry]'
uv pip install -e '.[deepeval,vllm,telemetry]'
uv pip install -e '.[dev,telemetry]'
```

### Using standard `pip`

```bash
cd llm_benchmarks
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e .
```

If you plan to use a specific backend, install the matching extra:

```bash
python -m pip install -e '.[deepeval,transformers,telemetry]'
python -m pip install -e '.[deepeval,llamacpp,telemetry]'
python -m pip install -e '.[deepeval,vllm,telemetry]'
python -m pip install -e '.[dev,telemetry]'
```

## Quick start

The example files intentionally contain no private paths or real scheduler partitions. Copy the examples first and then adapt them to your environment.

### 1) Review the model definitions

```yaml
# configs/models.example.yml
version: 1
models:
  local-gguf:
    backend: llamacpp
    local_path: /replace/with/model.gguf
    inference:
      context_size: 4096
      temperature: 0.0
      max_tokens: 1
      seed: 42

  hf-model:
    backend: transformers
    hf_id: organization/model-name
    inference:
      dtype: bfloat16
      temperature: 0.0

  vllm-model:
    backend: vllm
    hf_id: organization/model-name
    inference:
      dtype: bfloat16
      temperature: 0.0
```

### 2) Review the hardware profiles

```yaml
# configs/hardware_profiles.example.yml
version: 1
profiles:
  cpu:
    scheduler:
      partition: replace-me
      cpus_per_task: 32
      memory: 64G
      time: "08:00:00"
    modules: []

  gpu:
    scheduler:
      partition: replace-me
      gpus: 1
      cpus_per_task: 16
      memory: 64G
      time: "08:00:00"
    modules: [cuda]

  a100:
    scheduler:
      partition: replace-me
      gpus: a100:1
      cpus_per_task: 16
      memory: 64G
      time: "08:00:00"
    modules: [cuda]

  h100:
    scheduler:
      partition: replace-me
      gpus: h100:1
      cpus_per_task: 16
      memory: 96G
      time: "08:00:00"
    modules: [cuda]
```

### 3) Define a campaign

```yaml
# configs/campaigns/smoke.example.yml
version: 1
name: smoke
model: local-gguf
hardware_profile: cpu
repetitions: 1
seed: 42
capture_predictions: true
scoring: [exact_match, log_likelihood]
benchmarks:
  mmlu:
    shots: 0
    tasks: [high_school_computer_science]
    max_samples: 5
  hellaswag:
    shots: 0
    tasks: [applying_sunscreen]
    max_samples: 5
telemetry:
  require_energy: false
  sample_interval_seconds: 1.0
```

## Validate a campaign

This verifies that the YAML is consistent, the backend exists, the requested benchmarks are valid, and the hardware profile matches the expected structure. It does not download models or execute benchmarks.

```bash
qscope-bench validate \
  --models configs/models.example.yml \
  --campaign configs/campaigns/smoke.example.yml \
  --hardware configs/hardware_profiles.example.yml
```

Expected output:

```text
Valid campaign: model=local-gguf backend=llamacpp profile=cpu benchmarks=mmlu,hellaswag scoring=exact_match,log_likelihood
```

Logging is disabled by default. Add `--log-level INFO` for campaign progress or
`--log-level DEBUG` for per-sample timing and adapter details to either command.

## Run a campaign

The actual execution requires a model that is accessible for the selected backend. The CLI supports `run` and writes the output artifacts to the directory you specify.

```bash
qscope-bench run \
  --models configs/models.example.yml \
  --campaign configs/campaigns/smoke.example.yml \
  --hardware configs/hardware_profiles.example.yml \
  --output-dir ./artifacts/run-smoke
```

The output is written under `./artifacts/run-smoke`, and the command prints a final summary with the artifact location.

### NVIDIA Process Metrics profiling

Profiling is disabled when the campaign omits `profiling` or sets
`profiling.enabled: false`. When enabled, `qscope-bench run` relaunches itself
so the metrics library is active before Python initializes the model adapter.
Captured files are stored under `OUTPUT_DIR/nvidia-profiling/`.

Direct mode uses `LD_PRELOAD` without a daemon or root privileges. It captures
device telemetry and kernel activity, but does not produce PM sampling data:

```yaml
profiling:
  enabled: true
  mode: direct
  library_path: ${HOME}/.local/programs/H100/nvidia-profiling/lib/nvidia-process-metrics/libnvidia-process-metrics.so
  device: 0
  window_ms: 200
```

Daemon mode asks `nvidia-process-metrics-launcher` to start a privileged
daemon session. It also copies the daemon session files into the benchmark
output directory. The daemon and its PM sampler must already be installed and
running; if unavailable, the campaign fails rather than silently switching
modes:

```yaml
profiling:
  enabled: true
  mode: daemon
  library_path: ${HOME}/.local/programs/H100/nvidia-profiling/lib/nvidia-process-metrics/libnvidia-process-metrics.so
  launcher: nvidia-process-metrics-launcher
  device: 0
  window_ms: 200
  duration_seconds: 600
```

`library_path` is required when enabled. `device` defaults to `0` and
`window_ms` to `200`. Daemon mode requires a positive `duration_seconds` that
covers the benchmark run. You can set `launcher` to an absolute path if it is
not on `PATH`. A multi-model campaign is captured as one run, including all
selected models.

### llama.cpp performance data

The same `run` command automatically writes additional files for llama.cpp models,
without changing prompts, generation settings, scoring, or existing accuracy artifacts:

- `performance_requests.csv`: successful completion calls, wall-clock latency,
  token counts, and optional server prompt/generation durations.
- `performance_summary.csv`: per-model request count, mean/median/p95 latency
  (nearest-rank p95), benchmark runtime, weighted prompt/generation tokens per second,
  sampled peak GPU memory per device, total average GPU power, and estimated GPU energy.
- `gpu_samples.csv`: device UUIDs, monotonic timestamps, power in watts, and used memory in MiB.
  The file contains only its header when GPU sampling is unavailable.

Install `pip install -e '.[telemetry]'` in the benchmark environment to enable optional
NVML sampling. `telemetry.sample_interval_seconds` controls the sampling interval
(default: 1 second). Missing dependencies, drivers, or unsupported readings do not
stop generation; unavailable measurements are blank, with a reason in the summary.
`telemetry.require_energy` is not enforced by this best-effort performance capture.

Benchmark runtime includes evaluation and dataset overhead, but excludes model loading
and shutdown. Request latency covers only the completion call. The Python fallback
captures latency and usage token counts, but leaves server-specific timings and
throughput blank. Server throughput uses token totals divided by measured durations;
zero-duration or missing timings are excluded, and timed-request counts show coverage.
One-token answers do not provide a representative sustained generation-speed benchmark.
These files aggregate both benchmark suites per model and record completion calls,
not necessarily one call per scored sample. Existing accuracy CSV latency placeholders
are unchanged; use the new performance files for timing.

GPU energy is a trapezoidal estimate from sampled power, not a hardware energy counter.
GPU memory and power include all workloads on each sampled device, not just this process.
Sampling uses `CUDA_VISIBLE_DEVICES` when set, otherwise all NVML devices. Numeric
selectors use physical NVML indices; use GPU UUIDs when CUDA ordering is remapped.
Sampling covers evaluation only and may miss brief memory peaks. Existing result files
cannot recover these measurements; rerun the campaign to collect them.

## SLURM example

This project includes a helper script to submit a validated campaign directly to SLURM using the scheduler settings already defined in the hardware profile.

```bash
cp configs/slurm.example.yml configs/slurm.yml
```

Edit `configs/slurm.yml` to choose the model, campaign, hardware profile file, output directory, and whether to preview the submission:

```yaml
models: configs/models.yml
campaign: configs/campaigns/my-run.yml
hardware: configs/hardware.yml
output_dir: ./artifacts/slurm-run
dry_run: true
```

Submit using the YAML settings:

```bash
./slurm/submit.sh --config configs/slurm.yml
```

With `dry_run: true`, the script prints the generated `sbatch` command without submitting. Set it to `false` to submit, or omit it and use `--dry-run` for a one-off preview. Command-line values such as `--campaign` override their YAML counterparts. The script reads the named hardware profile (`hardware_profile` in the campaign), extracts scheduler values, and validates the campaign before submission.

## Configuration contract

- A model must specify exactly one backend: `llamacpp`, `transformers`, or `vllm`.
- Each model must use exactly one source: `local_path` or `hf_id`.
- A campaign may select one model with `model` or several with `models: [model-a, model-b]`; multi-model runs are sequential and artifacts identify each model by name.
- A campaign may run MMLU, HellaSwag, or both.
- MMLU accepts 0 to 5 shots and HellaSwag accepts 0 to 15.
- `exact_match` is available for all backends.
- `log_likelihood` is only used when the adapter declares it as a capability.
- Hardware profiles are scheduler templates; they do not detect hardware at runtime.
- Platform detection and energy collection happen in later runner stages.

## Example customization

Copy the examples and adjust only what you need:

```bash
cp configs/models.example.yml configs/models.yml
cp configs/hardware_profiles.example.yml configs/hardware.yml
cp configs/campaigns/smoke.example.yml configs/campaigns/my-run.yml
```

Then edit the copied files:

```yaml
# configs/models.yml
version: 1
models:
  my-local-model:
    backend: llamacpp
    local_path: /mnt/models/Qwen3-8B-Instruct-Q4_K_M.gguf
    inference:
      context_size: 8192
      temperature: 0.0
```

```yaml
# configs/hardware.yml
version: 1
profiles:
  gpu:
    scheduler:
      partition: gpu
      gpus: 1
      cpus_per_task: 16
      memory: 64G
      time: "12:00:00"
    modules: [cuda]
```

```yaml
# configs/campaigns/my-run.yml
version: 1
name: qwen3-smoke
model: my-local-model
hardware_profile: gpu
repetitions: 3
seed: 42
scoring: [exact_match]
benchmarks:
  mmlu:
    shots: 0
    tasks: [high_school_physics]
    max_samples: 20
```

```bash
qscope-bench validate \
  --models configs/models.yml \
  --campaign configs/campaigns/my-run.yml \
  --hardware configs/hardware.yml
```

## Project status

The current foundation already includes:

- an installable package,
- versioned YAML configuration,
- campaign validation,
- CLI support for `validate` and `run`,
- scaffolding for adapters, DeepEval, telemetry, and SLURM integration.

The next stage adds full benchmark execution, result capture, and HPC automation.

## Troubleshooting

- If validation fails, check that `backend`, `model`, and `hardware_profile` exist in the YAML files.
- If `run` fails because the backend is unsupported, verify that the correct extra was installed.
- If `local_path` or `hf_id` is invalid, correct the model path or Hugging Face identifier.
- If you want to use SLURM, make sure the `scheduler` section and required modules are defined correctly in the hardware profile.
