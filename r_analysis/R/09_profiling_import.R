## 09_profiling_import.R -------------------------------------------------------
## Import the tidy Nsight + perf profiling tables produced by
## etl/build_dataset.py (profiling pipeline). Additive to the energy pipeline: it reads its
## own CSVs and returns a named list consumed by 10_profiling_analysis.R.
## ---------------------------------------------------------------------------

import_profiling <- function() {
  ## perf_wide may come from the standard ETL output (perf_runs_wide.csv),
  ## from the Intel ZIP-derived sidecar (perf_runs_wide_intel_from_zip.csv),
  ## or from both. When both are present, bind rows on the union of columns.
  bind_rows_union <- function(a, b) {
    if (is.null(a)) return(b)
    if (is.null(b)) return(a)
    all_cols <- union(names(a), names(b))
    add_missing <- function(df, cols) {
      miss <- setdiff(cols, names(df))
      for (m in miss) df[[m]] <- NA
      df[, cols, drop = FALSE]
    }
    out <- rbind(add_missing(a, all_cols), add_missing(b, all_cols))
    if ("run_id" %in% names(out))
      out <- out[!duplicated(out$run_id), , drop = FALSE]
    out
  }

  perf_wide_main  <- read_profiling_csv("perf_runs_wide.csv")
  perf_wide_intel <- read_profiling_csv("perf_runs_wide_intel_from_zip.csv")
  perf_wide       <- bind_rows_union(perf_wide_main, perf_wide_intel)

  if (is.null(perf_wide_main) && !is.null(perf_wide_intel))
    message("[09] using Intel perf sidecar: perf_runs_wide_intel_from_zip.csv")
  if (!is.null(perf_wide_main) && !is.null(perf_wide_intel))
    message("[09] combining perf_runs_wide.csv + perf_runs_wide_intel_from_zip.csv")

  perf_long   <- read_profiling_csv("perf_counters_long.csv")
  nsight_wide <- read_profiling_csv("nsight_runs_wide.csv")
  kernels     <- read_profiling_csv("nsight_kernels_long.csv")
  cuda_api    <- read_profiling_csv("nsight_cuda_api_long.csv")
  gpu_mem     <- read_profiling_csv("nsight_gpu_mem_long.csv")
  osrt        <- read_profiling_csv("nsight_osrt_long.csv")

  ## Config-level energy means from the energy dataset, for optional joins with
  ## the profiling metrics (matched on node/model/quant, since the profiling runs
  ## are separate jobs from the energy runs).
  energy_cfg <- NULL
  wide <- file.path(CFG$paths$input_dir, "runs_wide.csv")
  if (file.exists(wide)) {
    e <- utils::read.csv(wide, stringsAsFactors = FALSE, check.names = TRUE)
    keep <- intersect(c("energy_psu_j", "energy_socket_j", "exec_time_s",
                        "tokens_per_joule", "energy_per_token_j",
                        "generation_tps"), names(e))
    if (all(c("node", "model", "quant") %in% names(e)) && length(keep)) {
      grp <- interaction(e$node, e$model, e$quant, drop = TRUE)
      energy_cfg <- do.call(rbind, lapply(split(e, grp), function(d) {
        row <- d[1, c("node", "model", "quant"), drop = FALSE]
        for (k in keep) row[[k]] <- mean(suppressWarnings(as.numeric(d[[k]])),
                                         na.rm = TRUE)
        row
      }))
      rownames(energy_cfg) <- NULL
    }
  }

  n_perf   <- if (is.null(perf_wide)) 0L else nrow(perf_wide)
  n_nsight <- if (is.null(nsight_wide)) 0L else nrow(nsight_wide)
  message(sprintf("[09] profiling import: %d perf runs, %d Nsight runs", n_perf, n_nsight))

  list(perf_wide = perf_wide, perf_long = perf_long, nsight_wide = nsight_wide,
       kernels = kernels, cuda_api = cuda_api, gpu_mem = gpu_mem, osrt = osrt,
       energy_cfg = energy_cfg)
}
