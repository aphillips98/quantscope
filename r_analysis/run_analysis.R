#!/usr/bin/env Rscript
## run_analysis.R --------------------------------------------------------------
## Master orchestrator for the redesigned Efimon DSE energy-characterization
## pipeline. Sources the function modules and the numbered stage scripts, then
## runs them end to end: the energy analysis (stages 00-08) followed by the
## Nsight + perf profiling analysis (stages 09-10). Configuration lives in
## config.yml; CLI flags override the most common options.
##
## The profiling stages consume the CSVs produced by the ETL; run it
## once beforehand (they are skipped gracefully if its output is absent):
##   python3 etl/build_dataset.py [--input DIR] [--profiling-input DIR]
##
## Usage:
##   Rscript run_analysis.R [--config FILE] [--input DIR] [--outdir DIR]
##                          [--diagnostics] [--no-q2k]
##
##   --config FILE   path to config.yml         (default: config.yml)
##   --input DIR     dir with runs_wide.csv + samples_long.csv (overrides config)
##   --outdir DIR    base dir for numerical_data/figures/tables/report (overrides config)
##   --diagnostics   also emit supplementary distribution / Q-Q / residual plots
##   --no-q2k        exclude the Q2_K quantization level
##   --time-source S duration for exec_time_s: efimon (default) | llama
## ---------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
get_opt <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (!length(i)) return(default)
  if (flag %in% c("--diagnostics", "--no-q2k")) return(TRUE)
  if (i == length(args)) return(default)
  args[i + 1]
}

## Resolve the directory this script lives in.
this_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
root <- if (length(this_file)) normalizePath(dirname(this_file)) else getwd()
r_dir <- file.path(root, "R")
methods_dir <- file.path(r_dir, "methods")

## Source function modules (helpers first -- it defines load_dependencies/config).
for (f in c("helpers", "energy", "statistics", "anova", "tukey", "plots",
            "heatmaps", "profiling"))
  source(file.path(r_dir, "functions", paste0(f, ".R")))

load_dependencies()

## Load configuration and apply CLI overrides.
config_path <- get_opt("--config", file.path(root, "config.yml"))
load_config(config_path, project_root = root)
if (!is.null(get_opt("--input")))  CFG$paths$input_dir <- normalizePath(get_opt("--input"), mustWork = FALSE)
if (!is.null(get_opt("--outdir"))) {
  base <- normalizePath(get_opt("--outdir"), mustWork = FALSE)
  CFG$paths$results_dir <- file.path(base, "numerical_data")
  CFG$paths$figures_dir <- file.path(base, "figures")
  CFG$paths$tables_dir  <- file.path(base, "tables")
  CFG$paths$reports_dir <- base
}
if (isTRUE(get_opt("--diagnostics"))) CFG$diagnostics$enabled <- TRUE
if (isTRUE(get_opt("--no-q2k")))      CFG$design$exclude_q2k  <- TRUE
if (!is.null(get_opt("--time-source"))) CFG$energy$time_source <- tolower(get_opt("--time-source"))
init_dirs()

## Source the numbered pipeline stages (00-08 energy + 09-10 profiling).
stages <- sprintf("%02d_%s.R", 0:10,
  c("validate_design", "import_data", "compute_metrics", "clean_data",
    "statistical_analysis", "posthoc_analysis", "generate_figures",
    "generate_tables", "render_report",
    "profiling_import", "profiling_analysis"))
  for (s in stages) source(file.path(methods_dir, s))

message("==== Efimon DSE analysis pipeline (v",
        CFG$reproducibility$pipeline_version %||% "2.0.0", ") ====")
message("input : ", CFG$paths$input_dir)
message("output: ", CFG$paths$results_dir, " | diagnostics=",
        isTRUE(CFG$diagnostics$enabled), " exclude_q2k=", isTRUE(CFG$design$exclude_q2k))
message("config: time_source=", CFG$energy$time_source %||% "efimon",
        " | energy=", CFG$energy$method %||% "trapezoid",
        " rail=", CFG$energy$system_rail %||% "psu",
        " recompute_from_samples=", isTRUE(CFG$energy$recompute_from_samples),
        " | primary_metric=", CFG$metrics$primary %||% "total_energy_j")

## ---- Pipeline ------------------------------------------------------------
design    <- validate_design()                        # 00
data      <- import_data()                            # 01
metrics   <- compute_metrics(data$runs, data$samples) # 02
metrics   <- clean_data(metrics)                      # 03
stats_res <- run_statistics(metrics)                  # 04
posthoc   <- run_posthoc(stats_res)                   # 05
generate_figures(metrics, stats_res, posthoc)         # 06
generate_tables(stats_res, posthoc, metrics)         # 07
render_report(metrics, design, stats_res, posthoc)    # 08

## ---- Profiling analysis (Nsight + perf), additive -----------------------
## Runs only when the profiling ETL output is present; failures here never
## abort the energy pipeline above.
tryCatch({
  prof <- import_profiling()                          # 09
  analyze_profiling(prof)                              # 10
}, error = function(e)
  message("[profiling] skipped: ", conditionMessage(e)))

## Persist the cleaned metric table for downstream reuse.
write_result(metrics, "metrics_clean")
saveRDS(metrics, file.path(CFG$paths$results_dir, "metrics_clean.rds"))

## Echo the effective configuration used for this run so the settings that
## produced the outputs are visible at the tail of the log.
ts <- CFG$energy$time_source %||% "efimon"
time_col <- if (identical(tolower(ts), "llama")) "llama_total_time_s" else "efimon_time_s"
message("\n==== effective configuration ====")
message("  input_dir            : ", CFG$paths$input_dir)
message("  results_dir          : ", CFG$paths$results_dir)
message("  exclude_q2k          : ", isTRUE(CFG$design$exclude_q2k))
message("  diagnostics          : ", isTRUE(CFG$diagnostics$enabled))
message("  energy.method        : ", CFG$energy$method %||% "trapezoid")
message("  energy.system_rail   : ", CFG$energy$system_rail %||% "psu")
message("  recompute_from_samples: ", isTRUE(CFG$energy$recompute_from_samples))
message("  time_source          : ", ts, "  (exec_time_s <- ", time_col, ")")
message("  primary_metric       : ", CFG$metrics$primary %||% "total_energy_j")
if ("exec_time_s" %in% names(metrics)) {
  grp <- if ("hardware" %in% names(metrics)) metrics$hardware else NULL
  med <- if (!is.null(grp))
    tapply(metrics$exec_time_s, grp, function(x) round(stats::median(x, na.rm = TRUE), 2))
  else round(stats::median(metrics$exec_time_s, na.rm = TRUE), 2)
  message("  median exec_time_s by hardware:")
  if (!is.null(grp)) for (h in names(med)) message("    ", h, ": ", med[[h]], " s")
  else message("    ", med, " s")
}

message("==== done. results in: ", CFG$paths$results_dir, " ====")
