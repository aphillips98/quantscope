#!/usr/bin/env Rscript
this_file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
root <- normalizePath(file.path(dirname(this_file), ".."))
source(file.path(root, "R", "functions", "kernel_energy.R"))

test_dir <- tempfile("kernel-energy-tests-")
dir.create(test_dir)
run_tests <- function() {
  on.exit(unlink(test_dir, recursive = TRUE))
  origin <- "1792552146139672207"
  fixture <- function(name, rows) {
    path <- file.path(test_dir, name)
    utils::write.csv(rows, path, row.names = FALSE, na = "")
    path
  }
  near <- function(x, y) stopifnot(isTRUE(all.equal(unname(x), y, tolerance = 1e-10)))
  expect_error <- function(expr, pattern) {
    error <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)))
  }
  expect_warning <- function(expr, pattern) {
    seen <- FALSE
    value <- withCallingHandlers(expr, warning = function(w) {
      if (!grepl(pattern, conditionMessage(w))) stop(w)
      seen <<- TRUE
      invokeRestart("muffleWarning")
    })
    stopifnot(seen)
    value
  }
  metric <- function(result, name)
    as.numeric(result$summary$value[match(name, result$summary$metric)])
  telemetry <- fixture("telemetry.csv", data.frame(
    timestamp_ns = ke_epoch_ns(c(0, 1e9, 2e9, 3e9), origin),
    power_mw = c(1000, 2000, 1000, 1000)
  ))
  kernels <- fixture("kernels.csv", data.frame(
    event_id = c("1", "2"), start_ns = ke_epoch_ns(c(0, 1e9), origin),
    end_ns = ke_epoch_ns(c(2e9, 3e9), origin), kernel_name = c("a", "b")
  ))
  result <- analyze_kernel_energy(telemetry, kernels, window_ms = 1000)
  near(metric(result, "device_energy_mj"), 4000)
  near(result$kernels$estimated_dynamic_energy_mj, c(2250, 1750))
  near(result$windows$kernel_active_pct, c(100, 100, 100))
  near(metric(result, "conservation_error_mj"), 0)
  stopifnot(identical(names(result$kernels), ke_kernel_fields),
            nrow(result$windows) == 3L, ncol(result$windows) == 10L,
            result$windows$start_ns[1] == origin,
            is.na(metric(result, "utilization_dynamic_energy_pearson_r")))

  pm <- fixture("pm.csv", data.frame(event_id = c("1", "2"),
                                    pm_coverage_pct = c(100, 100),
                                    weight = c(1, 3)))
  weighted <- analyze_kernel_energy(telemetry, kernels, pm, "weight", window_ms = 1000)
  near(weighted$kernels$estimated_dynamic_energy_mj, c(1875, 2125))
  near(metric(weighted, "pm_weighted_energy_mj"), 4000)
  near(metric(weighted, "pm_eligible_kernels"), 2)
  partial_pm <- fixture("partial-pm.csv", data.frame(
    event_id = c("1", "2"), pm_coverage_pct = c(100, 90), weight = c(1, 3)))
  fallback <- analyze_kernel_energy(telemetry, kernels, partial_pm, "weight",
                                    window_ms = 1000)
  near(fallback$kernels$estimated_dynamic_energy_mj, c(2250, 1750))
  near(metric(fallback, "pm_weighted_energy_mj"), 1500)
  near(metric(fallback, "equal_share_fallback_energy_mj"), 2500)
  duplicate_pm <- fixture("duplicate-pm.csv", data.frame(
    event_id = c("1", "1"), pm_coverage_pct = c(100, 100), weight = c(1, 3)))
  expect_error(analyze_kernel_energy(telemetry, kernels, duplicate_pm, "weight"), "unique")

  idle <- analyze_kernel_energy(telemetry, kernels, idle_power_mw = 500,
                                window_ms = 1000)
  near(metric(idle, "dynamic_energy_mj"), 2500)
  near(sum(idle$kernels$estimated_dynamic_energy_mj), 2500)
  empty <- fixture("empty.csv", data.frame(start_ns = character(), end_ns = character()))
  for (path in list(NULL, empty)) {
    no_kernels <- expect_warning(analyze_kernel_energy(telemetry, path, window_ms = 700),
                                 "No valid kernel")
    near(metric(no_kernels, "unassigned_dynamic_energy_mj"), 4000)
    near(metric(no_kernels, "assigned_dynamic_energy_mj"), 0)
    stopifnot(nrow(no_kernels$kernels) == 0L, nrow(no_kernels$windows) == 5L)
    near(tail(no_kernels$windows$duration_ms, 1), 200)
  }
  offsets <- c(-2, -1, 0, 1, 2, 999999999, 1000000000, 12345678901)
  stopifnot(identical(ke_relative_ns(ke_epoch_ns(offsets, origin), origin), offsets))
  tiny <- fixture("tiny.csv", data.frame(timestamp_ns = ke_epoch_ns(c(0, 1, 2), origin),
                                         power_mw = c(1000, 1000, 1000)))
  tiny_result <- expect_warning(analyze_kernel_energy(tiny, window_ms = 0.000001),
                                "No valid kernel")
  near(metric(tiny_result, "device_energy_mj"), 2e-6)
  stopifnot(identical(tiny_result$windows$end_ns, ke_epoch_ns(c(1, 2), origin)))

  duplicate <- fixture("duplicates.csv", data.frame(
    timestamp_ns = c(ke_epoch_ns(c(1e9, 0, 0), origin), "invalid"),
    power_mw = c(1000, 500, 1000, Inf)))
  loaded <- expect_warning(ke_load_telemetry(duplicate), "invalid telemetry")
  near(loaded$samples$time, c(0, 1e9))
  near(loaded$samples$power, c(1000, 1000))
  invalid <- fixture("invalid-kernel.csv", data.frame(
    start_ns = c(origin, "bad"), end_ns = c(origin, origin)))
  expect_warning(ke_load_kernels(invalid, origin), "invalid kernel")
  missing <- fixture("missing.csv", data.frame(x = "1"))
  expect_error(ke_load_telemetry(missing), "missing columns")
  expect_error(analyze_kernel_energy(telemetry, window_ms = 0), "window_ms")
  expect_error(analyze_kernel_energy(telemetry, idle_power_mw = Inf), "finite")
  expect_error(analyze_kernel_energy(telemetry, pm_min_coverage_pct = 101), "between")
  expect_error(analyze_kernel_energy(telemetry, pm_kernel_metrics = pm), "require")
  outside <- fixture("outside.csv", data.frame(
    start_ns = ke_epoch_ns(4e9, origin), end_ns = ke_epoch_ns(5e9, origin)))
  expect_error(suppressWarnings(analyze_kernel_energy(telemetry, outside)), "do not overlap")
  clipped <- fixture("clipped.csv", data.frame(
    start_ns = origin, end_ns = ke_epoch_ns(4e9, origin)))
  clipped_result <- expect_warning(analyze_kernel_energy(telemetry, clipped),
                                   "complete final window")
  near(metric(clipped_result, "device_energy_mj"), 4000)

  gaps <- fixture("gaps.csv", data.frame(
    start_ns = ke_epoch_ns(c(0, 2e9), origin), end_ns = ke_epoch_ns(c(1e9, 3e9), origin)))
  gaps_result <- analyze_kernel_energy(telemetry, gaps, window_ms = 1000)
  near(metric(gaps_result, "unassigned_dynamic_energy_mj"), 1500)
  near(gaps_result$windows$kernel_active_pct, c(100, 0, 100))
  near(metric(gaps_result, "utilization_dynamic_energy_pearson_r"), -0.5)
  near(ke_union_duration(data.frame(.start = c(0, 1, 2), .end = c(10, 3, 4)), 0, 10), 10)

  crossing_kernels <- fixture("crossing.csv", data.frame(
    start_ns = c(origin, origin), end_ns = ke_epoch_ns(c(5e8, 3e9), origin)))
  crossing <- expect_warning(
    analyze_kernel_energy(telemetry, crossing_kernels, idle_power_mw = 1500, window_ms = 500),
    "conservation error"
  )
  stopifnot(metric(crossing, "conservation_error_mj") != 0)
  out <- file.path(test_dir, "outputs")
  write_kernel_energy(result, out, plot = TRUE)
  stopifnot(all(file.exists(file.path(out, c(
    "kernel_energy.csv", "energy_windows.csv", "energy_summary.csv",
    "energy_timeline.png", "utilization_energy_correlation.png"
  )))))
  roundtrip <- ke_read_csv(file.path(out, "energy_windows.csv"), "start_ns")
  stopifnot(identical(roundtrip$start_ns, result$windows$start_ns))
  cat("All kernel-energy regression tests passed.\n")
}
run_tests()
