# Orfeo corrected configurations

Changes:
- Explicit `mode: chat` and `gpu_layers: -1` for all listed instruction-tuned models, aligning GPU inference protocol. This is an intentional change from earlier default `completion`; it can change accuracy and invalidates direct comparisons to old completion runs.
- Removed `max_sample`/`max_samples` because the currently described DeepEval bridge ignores them. Tasks therefore run in full.
- Corrected H100 profiling library path from V100 to H100; verify the library exists on H100 nodes.
- Unified Slurm file references and added `slurm.h100.yml`. References assume the deployed folder is named `orfeo_configs` and commands run from its parent.
- Retained `dry_run: true` as a safe default; set false only when ready to execute.
- Did not change `hardware_profiles.yml`, benchmark task selections, repetition counts, scoring, paths to model files, or energy settings.

## Notes
- Phi GGUF files are named `ArliAI-RPMax`, which may be a fine-tune different from standard Phi-3.5 Instruct; verify chat-template compatibility and model identity before cross-model claims.
- `gpu_layers: -1` requests GPU offload; confirm actual offload in llama.cpp logs and sufficient VRAM.
- `mode: chat` depends on each GGUF exposing a supported chat template.
- A100 remains the previously tested configuration.
- Validate scheduler paths, partitions, installed profiler and modules on Orfeo before launching.

## Check
Run `python validate_configs.py` from inside the extracted folder. Requires PyYAML.
