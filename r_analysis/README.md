># Efimon DSE Energy-Characterization Pipeline

R statistical pipeline that turns raw `llamacpp_*` benchmark archives (energy
telemetry + Nsight/perf profiling) into publication-ready figures, tables and
an analysis report. The raw archives can either be supplied locally or pulled
directly from a Zenodo record.

## Directory overview

```
r_analysis/
├── config.yml              # single source of truth for paths / options
├── install_dependencies.sh # bootstraps R + system libs + Nsight Systems CLI
├── install_packages.R      # installs the R package dependencies
├── run_analysis.R          # pipeline entry point
├── etl/                    # Python ETL: raw archives -> tidy CSVs (data/)
│   ├── build_dataset.py    # single entry point (energy + profiling)
│   ├── energy_etl.py
│   ├── profiling_etl.py
│   └── node_map.py
├── data/                   # tidy CSVs consumed by the R pipeline (ETL output)
├── R/
│   ├── functions/          # reusable helpers/plots/statistics modules
│   └── methods/            # numbered pipeline stages (00-10), sourced in order
└── results/                # everything run_analysis.R produces
    ├── numerical_data/      # CSV/RDS/JSON statistical results
    ├── figures/             # one subfolder per figure family (PDF + .md sidecar)
    ├── tables/              # LaTeX / markdown tables
    └── analysis_report.md
```

## 1. Install dependencies

On a Debian/Ubuntu host:

```bash
./install_dependencies.sh
```

This installs R, the system libraries needed to build the CRAN packages, the
required R packages (via `install_packages.R`) and, if possible, the NVIDIA
Nsight Systems CLI (`nsys`), which the profiling ETL needs to parse
`nsight/*.sqlite` files. On any other OS, install R yourself and then run:

```bash
Rscript install_packages.R
```

## 2. Get the raw dataset

The R pipeline reads tidy CSVs from `data/` (`runs_wide.csv`,
`samples_long.csv`, plus the `perf_*`/`nsight_*` profiling tables). Those are
generated from the raw `llamacpp_*.zip` benchmark archives with
`etl/build_dataset.py`. You can either point it at a local directory of
archives, or have it download them straight from Zenodo.

### Option A: Pull the dataset from Zenodo

```bash
cd r_analysis
python3 etl/build_dataset.py --download-zenodo <RECORD_ID_OR_URL> --outdir data
```

`<RECORD_ID_OR_URL>` accepts any of:
- a record ID, e.g. `12345678`
- a DOI, e.g. `10.5281/zenodo.12345678`
- a record URL, e.g. `https://zenodo.org/records/12345678`
- a direct file URL

The archives are downloaded to a temporary directory, extracted straight into
`--outdir`, and then processed exactly like a local `--input` directory (see
below) — no separate unpacking step is needed.

### Option B: Use a local directory of archives

```bash
cd r_analysis
python3 etl/build_dataset.py --input /path/to/llamacpp_zips --outdir data
```

`--input` is scanned recursively for `llamacpp_*.zip` archives (or already
unzipped `llamacpp_*` directories); each one carries both energy telemetry
(`efimon/`, `llama_logs/`) and profiling artefacts (`perf_stat/`, `nsight/`).
Whether a run is CPU (perf) or GPU (Nsight) is detected automatically from the
node token in the archive name.

Useful flags for both options:
- `--nsys PATH` — path to the `nsys` binary (default: resolved from `PATH`)
- `--time-source {efimon|llama}` — which duration fills `exec_time_s`
- `--keep-unknown-models` — keep model families outside the study
- `--include-sleep` — pair the `sleep_efimon_*` idle baseline for adjusted energy

Running `build_dataset.py` produces, under `--outdir` (`data/` by default):
- `runs_wide.csv`, `samples_long.csv`, `data_dictionary.md` (energy)
- `perf_counters_long.csv`, `perf_runs_wide.csv` (CPU profiling)
- `nsight_kernels_long.csv`, `nsight_cuda_api_long.csv`, `nsight_gpu_mem_long.csv`,
  `nsight_osrt_long.csv`, `nsight_runs_wide.csv`, `profiling_data_dictionary.md` (GPU profiling)
- `dataset_summary.md` — how many runs were collected per node and data type

## 3. Run the R analysis pipeline

```bash
Rscript run_analysis.R
```

This sources `R/functions/*.R`, loads `config.yml`, then runs the numbered
stages in `R/methods/` end to end: design validation, import, metric
computation/cleaning, statistics, post-hoc tests, figures, tables and the
report (stages 00-08), followed by the Nsight + perf profiling analysis
(stages 09-10, skipped gracefully if no profiling data is present).

Common flags:

```bash
Rscript run_analysis.R [--config FILE] [--input DIR] [--outdir DIR] \
                        [--diagnostics] [--no-q2k] [--time-source {efimon|llama}]
```

- `--config FILE` — alternate config file (default: `config.yml`)
- `--input DIR` — overrides `paths.input_dir` (the `data/` produced in step 2)
- `--outdir DIR` — overrides where `numerical_data/`, `figures/`, `tables/`
  and the report are written (default: `results/`)
- `--diagnostics` — also emit supplementary distribution/Q-Q/residual plots
- `--no-q2k` — exclude the Q2_K quantization level
- `--time-source {efimon|llama}` — duration source for `exec_time_s`

## 4. Outputs

- `results/numerical_data/` — CSV/RDS/JSON for every statistical result
  (ANOVA, effect sizes, bootstrap CIs, factor importance, etc.)
- `results/figures/<family>/` — one subfolder per figure family (e.g.
  `cpu_energy_by_model/`, `gpu_kernel_runtime/`), each with the IEEE-formatted
  PDF and a markdown sidecar (title/subtitle/caption + any label mapping)
- `results/tables/` — LaTeX/markdown tables
- `results/analysis_report.md` — rendered summary linking every figure/table

All paths above are configurable in `config.yml` under `paths:`.
