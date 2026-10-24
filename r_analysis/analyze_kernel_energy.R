#!/usr/bin/env Rscript
## Standalone NVML/CUPTI analysis; no CRAN packages or ETL required.

args <- commandArgs(trailingOnly = TRUE)
usage <- paste(
  "Usage: Rscript r_analysis/analyze_kernel_energy.R --telemetry FILE [options]",
  "  --kernels FILE                CUPTI kernel_activity.csv (optional)",
  "  --pm-kernel-metrics FILE      Offline PM metrics joined by event_id",
  "  --pm-weight-metric COLUMN     PM allocation metric",
  "  --pm-min-coverage-pct NUMBER  Minimum coverage (default: 99.9)",
  "  --idle-power-mw NUMBER        Idle baseline (default: 0)",
  "  --window-ms NUMBER            Window width (default: 200)",
  "  --output-dir DIR              Output directory (default: energy-analysis)",
  "  --plot                        Generate two PNG plots",
  "  --help                        Show this message",
  sep = "\n"
)
if ("--help" %in% args) {
  cat(usage, "\n")
  quit(status = 0)
}
options <- list(
  telemetry = NULL, kernels = NULL, pm_kernel_metrics = NULL,
  pm_weight_metric = "sm__inst_executed_realtime.avg.pct_of_peak_sustained_elapsed",
  pm_min_coverage_pct = 99.9, idle_power_mw = 0, window_ms = 200,
  output_dir = "energy-analysis", plot = FALSE
)
numeric_options <- c("pm_min_coverage_pct", "idle_power_mw", "window_ms")
i <- 1L
while (i <= length(args)) {
  flag <- args[i]
  key <- gsub("-", "_", sub("^--", "", flag))
  if (!startsWith(flag, "--") || !key %in% names(options))
    stop("Unknown option: ", flag, "\n", usage)
  if (key == "plot") {
    options$plot <- TRUE
    i <- i + 1L
    next
  }
  if (i == length(args) || startsWith(args[i + 1L], "--"))
    stop("Missing value for ", flag)
  value <- args[i + 1L]
  if (key %in% numeric_options) {
    value <- suppressWarnings(as.numeric(value))
    if (!is.finite(value)) stop(flag, " requires a finite number")
  }
  options[[key]] <- value
  i <- i + 2L
}
if (is.null(options$telemetry)) stop("--telemetry is required\n", usage)
this_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
root <- normalizePath(dirname(this_file))
source(file.path(root, "R", "functions", "kernel_energy.R"))
result <- do.call(analyze_kernel_energy,
                  options[setdiff(names(options), c("output_dir", "plot"))])
write_kernel_energy(result, options$output_dir, options$plot)
cat("=== Kernel energy association ===\n",
    "Kernels: ", nrow(result$kernels), "\n",
    "Windows: ", nrow(result$windows), "\n", sep = "")
print(result$summary, row.names = FALSE, right = FALSE)
cat("Results: ", normalizePath(options$output_dir), "\n", sep = "")
