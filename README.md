# quantscope

Benchmarking and energy-analysis pipeline for LLM inference workloads.

## Subprojects

- [`hpc_area_setup/`](hpc_area_setup/README.md) — Generic tool to build and install [llama.cpp](https://github.com/ggml-org/llama.cpp) (and tmux) in a personal area of an HPC cluster, without admin privileges. Produces one installation per hardware profile plus Lua modulefiles compatible with Lmod/Environment Modules.
- [`llm_benchmarks/`](llm_benchmarks/README.md) — Standalone benchmark runner for MMLU and HellaSwag on CPU and NVIDIA GPUs, with modular adapters (`llamacpp`, `transformers`, `vllm`), DeepEval integration, energy telemetry, and SLURM scheduling.
- [`script_profiler/`](script_profiler/) — Machine-specific benchmarking scripts (CPU-only and GPU-only) for measuring llama.cpp inference performance on different hardware targets (DGX002, DGX003, EPY008, GPU).
- [`r_analysis/`](r_analysis/README.md) — R statistical pipeline that turns raw `llamacpp_*` benchmark archives (energy telemetry + Nsight/perf profiling) into publication-ready figures, tables and an analysis report. Includes a Python ETL (`etl/`) that converts the raw archives into tidy CSV datasets, consumed by the numbered R pipeline stages.
