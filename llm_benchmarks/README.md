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
- `pip` and a virtual environment
- Backend dependencies for the target setup:
  - `transformers`
  - `llamacpp`
  - `vllm`
  - `telemetry` (optional for platform and energy collection)

## Installation

From the project root:

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

## SLURM example

This project includes a helper script to submit a validated campaign directly to SLURM using the scheduler settings already defined in the hardware profile.

```bash
./slurm/submit.sh \
  --models configs/models.yml \
  --campaign configs/campaigns/my-run.yml \
  --hardware configs/hardware.yml \
  --output-dir ./artifacts/slurm-run \
  --dry-run
```

The `--dry-run` flag prints the generated `sbatch` command without submitting the job. For example:

```bash
sbatch --partition=gpu --gpus=1 --cpus-per-task=16 --mem=64G --time=12:00:00 --job-name=qscope-gpu --wrap "/path/to/.venv/bin/python -m quantscope_bench.cli run --models configs/models.yml --campaign configs/campaigns/my-run.yml --hardware configs/hardware.yml --output-dir ./artifacts/slurm-run"
```

To submit for real, omit the `--dry-run` flag:

```bash
./slurm/submit.sh \
  --models configs/models.yml \
  --campaign configs/campaigns/my-run.yml \
  --hardware configs/hardware.yml \
  --output-dir ./artifacts/slurm-run
```

This script automatically reads the named hardware profile (`hardware_profile` in the campaign), extracts the scheduler values, and wraps the benchmark runner in an `sbatch` job. It also runs the validation step before submission.

## Configuration contract

- A model must specify exactly one backend: `llamacpp`, `transformers`, or `vllm`.
- Each model must use exactly one source: `local_path` or `hf_id`.
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
