## 01_import_data.R ------------------------------------------------------------
## Read the ETL outputs (runs_wide.csv, samples_long.csv), attach the full
## experiment metadata (creating absent fields as NA), coerce the design factors
## to their configured ordered levels and expose RUNS + SAMPLES.
## ---------------------------------------------------------------------------

import_data <- function() {
  dir <- CFG$paths$input_dir
  wide <- file.path(dir, "runs_wide.csv")
  if (!file.exists(wide))
    stop("runs_wide.csv not found in ", dir)
  runs <- utils::read.csv(wide, stringsAsFactors = FALSE, check.names = TRUE)

  ## Optional exclusion of the extra Q2_K level.
  if (isTRUE(CFG$design$exclude_q2k) && "quant" %in% names(runs))
    runs <- runs[runs$quant != "Q2_K", , drop = FALSE]

  ## GPU model defaults to the GPU architecture label when not separately stored.
  if (!"gpu_model" %in% names(runs) && "gpu_arch" %in% names(runs))
    runs$gpu_model <- runs$gpu_arch

  ## Unified hardware factor: the specific compute device that defines a design
  ## cell -- the GPU architecture for GPU runs, the CPU architecture otherwise.
  ## A repetition is one run of a given hardware x model x quant combination.
  runs <- derive_hardware(runs)

  ## Ensure every declared metadata field exists (NA when the collection layer
  ## does not yet emit it -- e.g. prompt, context_size, batch_size, n_threads,
  ## llamacpp_version, cuda_version).
  for (f in CFG$metadata_fields)
    if (!f %in% names(runs)) runs[[f]] <- NA
  if (is.na(runs$llamacpp_version[1]) && !is.null(CFG$reproducibility$llamacpp_version))
    runs$llamacpp_version <- CFG$reproducibility$llamacpp_version
  if (is.na(runs$cuda_version[1]) && !is.null(CFG$reproducibility$cuda_version))
    runs$cuda_version <- CFG$reproducibility$cuda_version

  ## Numeric coercion of the raw response columns we still consume.
  num_cols <- c("exec_time_s", "efimon_time_s", "llama_total_time_s",
                "energy_socket_j", "energy_psu_j",
                "energy_socket_adj_j", "energy_psu_adj_j",
                "avg_socket_power_w", "peak_socket_power_w",
                "avg_psu_power_w", "peak_psu_power_w",
                "idle_socket_power_w", "idle_psu_power_w",
                "avg_cpu_freq_mhz", "avg_system_cpu_pct", "avg_process_cpu_pct",
                "generation_tps", "prompt_tps", "est_tokens", "n_samples",
                "avg_gpu_util_pct", "avg_gpu_power_w", "gpu_mem_util_pct",
                "generated_tokens", "prompt_tokens", "context_size",
                "batch_size", "n_threads")
  for (c in intersect(num_cols, names(runs)))
    runs[[c]] <- suppressWarnings(as.numeric(runs[[c]]))

  runs <- coerce_factors(runs)

  ## Raw per-sample traces (needed for physically correct energy integration).
  samples <- NULL
  sfile <- file.path(dir, "samples_long.csv")
  if (file.exists(sfile)) {
    samples <- utils::read.csv(sfile, stringsAsFactors = FALSE, check.names = TRUE)
    if (isTRUE(CFG$design$exclude_q2k) && "quant" %in% names(samples))
      samples <- samples[samples$quant != "Q2_K", , drop = FALSE]
    if (!nrow(samples)) samples <- NULL
  }

  message(sprintf("[01] imported %d runs (%d factors) | samples: %s",
                  nrow(runs), length(CFG$design$factors),
                  if (is.null(samples)) "none" else nrow(samples)))
  list(runs = runs, samples = samples)
}
