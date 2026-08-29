## 02_compute_metrics.R --------------------------------------------------------
## Turn the raw ETL columns into the curated metric set for the paper. Energy is
## (re)computed as a time integral of instantaneous power -- never a bare sum --
## and the baseline-adjusted variant is retained alongside the raw one. Only the
## metrics whitelisted in config.yml survive (plus factors + metadata), unless
## diagnostics mode keeps the extras.
## ---------------------------------------------------------------------------

compute_metrics <- function(runs, samples) {
  method <- CFG$energy$method %||% "trapezoid"
  rail   <- CFG$energy$system_rail %||% "psu"

  ## --- Energy: integral(P dt), raw and baseline-adjusted, both rails --------
  e <- NULL
  if (isTRUE(CFG$energy$recompute_from_samples) && !is.null(samples)) {
    e <- energy_from_samples(samples, runs, method)
    message(sprintf("[02] energy integrated from raw samples (%s) for %d/%d runs",
                    method, sum(runs$run_id %in% e$run_id), nrow(runs)))
  }
  getcol <- function(rid, col) if (!is.null(e)) e[[col]][match(rid, e$run_id)] else rep(NA_real_, length(rid))

  e_psu_raw    <- getcol(runs$run_id, "total_energy_psu_j")
  e_socket_raw <- getcol(runs$run_id, "total_energy_socket_j")
  e_psu_adj    <- getcol(runs$run_id, "energy_adj_psu_j")
  e_socket_adj <- getcol(runs$run_id, "energy_adj_socket_j")
  dur          <- getcol(runs$run_id, "exec_time_s")

  ## Fall back to the pre-integrated ETL values where samples were unavailable.
  fb <- function(x, col) ifelse(is.finite(x), x,
                                if (col %in% names(runs)) runs[[col]] else NA_real_)
  e_psu_raw    <- fb(e_psu_raw, "energy_psu_j")
  e_socket_raw <- fb(e_socket_raw, "energy_socket_j")
  e_psu_adj    <- fb(e_psu_adj, "energy_psu_adj_j")
  e_socket_adj <- fb(e_socket_adj, "energy_socket_adj_j")

  ## Duration source: the efimon sampling window (default) or llama.cpp's total
  ## wall time. The dataset carries both efimon_time_s and llama_total_time_s;
  ## config.energy.time_source ("efimon" | "llama") selects which one fills
  ## exec_time_s. llama time is authoritative for short GPU runs where the efimon
  ## window is load-dominated / quantized to the sampling cadence. Both branches
  ## fall back to the efimon window (and finally the ETL exec_time_s) when the
  ## preferred column is missing so older datasets still work.
  time_source <- tolower(CFG$energy$time_source %||% "efimon")
  if (identical(time_source, "llama")) {
    dur <- fb(rep(NA_real_, nrow(runs)), "llama_total_time_s")
    dur <- fb(dur, "efimon_time_s")
    dur <- fb(dur, "exec_time_s")
    message("[02] duration source: llama.cpp total time (fallback: efimon window)")
  } else {
    dur <- fb(dur, "efimon_time_s")
    dur <- fb(dur, "exec_time_s")
  }

  ## --- Tokens: prefer measured generated tokens, else the ETL estimate -------
  tokens <- if ("generated_tokens" %in% names(runs) &&
                any(is.finite(runs$generated_tokens)))
    runs$generated_tokens else runs$est_tokens
  total_energy <- if (identical(rail, "socket")) e_socket_raw else e_psu_raw

  eff <- derive_efficiency(total_energy, tokens, dur)
  tps <- if ("generation_tps" %in% names(runs) &&
             any(is.finite(runs$generation_tps)))
    runs$generation_tps else eff$tokens_per_sec

  getopt <- function(col) if (col %in% names(runs)) runs[[col]] else NA_real_

  metrics <- data.frame(
    total_energy_j        = total_energy,
    energy_adj_j          = if (identical(rail, "socket")) e_socket_adj else e_psu_adj,
    total_energy_socket_j = e_socket_raw,
    energy_adj_socket_j   = e_socket_adj,
    exec_time_s           = dur,
    avg_socket_power_w    = getopt("avg_socket_power_w"),
    avg_psu_power_w       = getopt("avg_psu_power_w"),
    peak_socket_power_w   = getopt("peak_socket_power_w"),
    peak_psu_power_w      = getopt("peak_psu_power_w"),
    tokens_per_sec        = tps,
    energy_per_token_j    = eff$energy_per_token_j,
    tokens_per_joule      = eff$tokens_per_joule,
    avg_cpu_freq_mhz      = getopt("avg_cpu_freq_mhz"),
    avg_cpu_util_pct      = getopt("avg_system_cpu_pct"),
    avg_gpu_util_pct      = getopt("avg_gpu_util_pct"),
    avg_gpu_power_w       = getopt("avg_gpu_power_w"),
    gpu_mem_util_pct      = getopt("gpu_mem_util_pct"),
    stringsAsFactors = FALSE
  )

  ## Assemble: factors + metadata + curated metrics.
  keep_meta <- intersect(unique(c(CFG$design$factors, CFG$design$facet_factors,
                                  CFG$design$replicate_id, CFG$metadata_fields,
                                  "node")), names(runs))
  out <- cbind(runs[, keep_meta, drop = FALSE], metrics)

  ## Diagnostics mode also retains the raw secondary columns for supplements.
  if (isTRUE(CFG$diagnostics$enabled)) {
    diag_cols <- intersect(c("cpu_freq_sd_mhz", "avg_process_cpu_pct",
                             "avg_fan_rpm", "peak_fan_rpm", "n_samples",
                             "idle_socket_power_w", "idle_psu_power_w"),
                           names(runs))
    out <- cbind(out, runs[, diag_cols, drop = FALSE])
  }

  ## Drop metric columns that are entirely NA (e.g. GPU telemetry not collected).
  keep_metric <- CFG$metrics$keep
  present_metrics <- Filter(function(m) m %in% names(out) &&
                              any(is.finite(out[[m]])), keep_metric)
  dropped <- setdiff(keep_metric, present_metrics)
  if (length(dropped))
    message("[02] metrics with no data (kept as NA columns): ",
            paste(dropped, collapse = ", "))

  out <- coerce_factors(out)
  attr(out, "primary") <- CFG$metrics$primary
  attr(out, "available_metrics") <- present_metrics
  message(sprintf("[02] curated %d metrics for %d runs (primary=%s)",
                  length(present_metrics), nrow(out), CFG$metrics$primary))
  out
}
