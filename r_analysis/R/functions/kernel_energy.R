## NVML/CUPTI energy association, independent of the Efimon ETL pipeline.

ke_read_csv <- function(path, required) {
  rows <- utils::read.csv(path, colClasses = "character", check.names = FALSE,
                         na.strings = "", stringsAsFactors = FALSE)
  missing <- setdiff(required, names(rows))
  if (length(missing))
    stop(path, " is missing columns: ", paste(missing, collapse = ", "))
  rows
}

## Split epoch nanoseconds before conversion: doubles cannot represent a
## contemporary epoch timestamp exactly. Only relative nanoseconds use doubles.
ke_ns_parts <- function(x) {
  valid <- !is.na(x) & grepl("^[0-9]{1,19}$", x)
  seconds <- nanos <- rep(NA_real_, length(x))
  for (i in which(valid)) {
    n <- nchar(x[i])
    seconds[i] <- if (n > 9) as.numeric(substr(x[i], 1, n - 9)) else 0
    nanos[i] <- as.numeric(substr(x[i], max(1, n - 8), n))
  }
  list(seconds = seconds, nanos = nanos)
}

ke_relative_ns <- function(x, origin) {
  p <- ke_ns_parts(x)
  o <- ke_ns_parts(origin)
  value <- (p$seconds - o$seconds) * 1e9 + p$nanos - o$nanos
  if (any(abs(value) > 2^53 - 1, na.rm = TRUE))
    stop("Timestamp span exceeds exact relative-nanosecond precision (about 104 days)")
  value
}

ke_epoch_ns <- function(x, origin) {
  o <- ke_ns_parts(origin)
  seconds <- floor(x / 1e9)
  nanos <- x - seconds * 1e9 + o$nanos
  carry <- floor(nanos / 1e9)
  seconds <- seconds + o$seconds + carry
  nanos <- nanos - carry * 1e9
  ifelse(seconds == 0, sprintf("%.0f", nanos),
         paste0(sprintf("%.0f", seconds), sprintf("%09.0f", nanos)))
}

ke_load_telemetry <- function(path) {
  rows <- ke_read_csv(path, c("timestamp_ns", "power_mw"))
  p <- ke_ns_parts(rows$timestamp_ns)
  power <- suppressWarnings(as.numeric(rows$power_mw))
  valid <- is.finite(p$seconds) & is.finite(power)
  if (any(!valid)) warning("Skipped ", sum(!valid), " invalid telemetry rows")
  rows <- rows[valid, , drop = FALSE]
  power <- power[valid]
  p <- ke_ns_parts(rows$timestamp_ns)
  ord <- order(p$seconds, p$nanos, power)
  rows <- rows[ord, , drop = FALSE]
  power <- power[ord]
  if (!nrow(rows)) stop("At least two distinct telemetry timestamps are required")
  origin <- rows$timestamp_ns[1]
  time <- ke_relative_ns(rows$timestamp_ns, origin)
  keep <- !duplicated(time, fromLast = TRUE)
  if (sum(keep) < 2) stop("At least two distinct telemetry timestamps are required")
  list(samples = data.frame(time = time[keep], power = power[keep]), origin = origin)
}

ke_kernel_fields <- c(
  "event_id", "pid", "device_id", "context_id", "stream_id", "correlation_id",
  "start_ns", "end_ns", "duration_ns", "kernel_name",
  "estimated_dynamic_energy_mj", "pm_coverage_pct", "pm_energy_weight",
  "pm_weighted_energy_mj", "equal_share_fallback_energy_mj"
)

ke_load_kernels <- function(path, origin) {
  rows <- if (is.null(path)) {
    data.frame(start_ns = character(), end_ns = character())
  } else ke_read_csv(path, c("start_ns", "end_ns"))
  rows$.start <- ke_relative_ns(rows$start_ns, origin)
  rows$.end <- ke_relative_ns(rows$end_ns, origin)
  valid <- is.finite(rows$.start) & is.finite(rows$.end) & rows$.end > rows$.start
  if (any(!valid)) warning("Skipped ", sum(!valid), " invalid kernel rows")
  rows <- rows[valid, , drop = FALSE]
  rows <- rows[order(rows$.start), , drop = FALSE]
  for (field in setdiff(ke_kernel_fields, names(rows)))
    rows[[field]] <- rep(NA_character_, nrow(rows))
  for (field in c("estimated_dynamic_energy_mj", "pm_weighted_energy_mj",
                  "equal_share_fallback_energy_mj"))
    rows[[field]] <- numeric(nrow(rows))
  rows$pm_coverage_pct <- rows$pm_energy_weight <- rep(NA_real_, nrow(rows))
  rows
}

ke_apply_pm <- function(kernels, path, metric, min_coverage) {
  rows <- ke_read_csv(path, c("event_id", "pm_coverage_pct", metric))
  if (!nrow(rows)) stop("PM kernel metrics CSV is empty")
  if (anyNA(rows$event_id) || anyDuplicated(rows$event_id))
    stop("PM metrics event_id must be nonempty and unique")
  coverage <- suppressWarnings(as.numeric(rows$pm_coverage_pct))
  weights <- suppressWarnings(as.numeric(rows[[metric]]))
  valid <- is.finite(coverage) & is.finite(weights)
  if (any(!valid)) warning("Skipped ", sum(!valid), " invalid PM metric rows")
  match_id <- match(kernels$event_id, rows$event_id)
  matched <- !is.na(match_id) & valid[match_id]
  matched[is.na(matched)] <- FALSE
  kernels$pm_coverage_pct[matched] <- coverage[match_id[matched]]
  eligible <- matched & kernels$pm_coverage_pct >= min_coverage &
    weights[match_id] > 0
  eligible[is.na(eligible)] <- FALSE
  kernels$pm_energy_weight[eligible] <- weights[match_id[eligible]]
  list(kernels = kernels, matched = sum(matched), eligible = sum(eligible))
}

ke_interval_energy <- function(start, end, left_t, right_t, left_p, right_p, idle) {
  p_start <- left_p + (start - left_t) / (right_t - left_t) * (right_p - left_p)
  p_end <- left_p + (end - left_t) / (right_t - left_t) * (right_p - left_p)
  duration <- (end - start) / 1e9
  cbind(device = (p_start + p_end) / 2 * duration,
        dynamic = (pmax(0, p_start - idle) + pmax(0, p_end - idle)) / 2 * duration)
}

ke_integrate <- function(samples, start, end, idle) {
  n <- nrow(samples)
  left <- pmax(start, samples$time[-n])
  right <- pmin(end, samples$time[-1])
  ok <- left < right
  colSums(ke_interval_energy(
    left[ok], right[ok], samples$time[-n][ok], samples$time[-1][ok],
    samples$power[-n][ok], samples$power[-1][ok], idle
  ))
}

ke_union_duration <- function(kernels, start, end) {
  left <- pmax(start, kernels$.start)
  right <- pmin(end, kernels$.end)
  ok <- left < right
  left <- left[ok]
  right <- right[ok]
  if (!length(left)) return(0)
  previous_end <- c(left[1], head(cummax(right), -1))
  sum(pmax(0, right - pmax(left, previous_end)))
}

ke_attribute <- function(samples, kernels, start, end, idle) {
  totals <- c(assigned = 0, unassigned = 0, pm_weighted = 0, fallback = 0)
  for (i in seq_len(nrow(samples) - 1L)) {
    left <- max(start, samples$time[i])
    right <- min(end, samples$time[i + 1L])
    if (left >= right) next
    candidates <- which(kernels$.start < right & kernels$.end > left)
    boundaries <- sort(unique(c(left, right, pmax(left, kernels$.start[candidates]),
                                pmin(right, kernels$.end[candidates]))))
    for (j in seq_len(length(boundaries) - 1L)) {
      a <- boundaries[j]
      b <- boundaries[j + 1L]
      energy <- ke_interval_energy(a, b, samples$time[i], samples$time[i + 1L],
                                   samples$power[i], samples$power[i + 1L], idle)[1, "dynamic"]
      active <- candidates[kernels$.start[candidates] <= a &
                             kernels$.end[candidates] >= b]
      if (!length(active)) {
        totals["unassigned"] <- totals["unassigned"] + energy
        next
      }
      weights <- kernels$pm_energy_weight[active]
      use_pm <- all(is.finite(weights)) && sum(weights) > 0
      if (use_pm) {
        ## Scaling first also avoids overflow for unusually large PM weights.
        weights <- weights / max(weights)
        share <- energy * weights / sum(weights)
      } else share <- rep(energy / length(active), length(active))
      field <- if (use_pm) "pm_weighted_energy_mj" else "equal_share_fallback_energy_mj"
      kernels[[field]][active] <- kernels[[field]][active] + share
      kernels$estimated_dynamic_energy_mj[active] <-
        kernels$estimated_dynamic_energy_mj[active] + share
      key <- if (use_pm) "pm_weighted" else "fallback"
      totals[key] <- totals[key] + energy
      totals["assigned"] <- totals["assigned"] + energy
    }
  }
  list(kernels = kernels, totals = totals)
}

ke_windows <- function(samples, kernels, start, end, idle, window_ns, origin) {
  count <- ceiling((end - start) / window_ns)
  rows <- lapply(seq_len(count), function(i) {
    a <- start + (i - 1) * window_ns
    b <- min(a + window_ns, end)
    active <- ke_union_duration(kernels, a, b)
    energy <- ke_integrate(samples, a, b, idle)
    duration_s <- (b - a) / 1e9
    data.frame(
      window = i - 1L, start_ns = ke_epoch_ns(a, origin), end_ns = ke_epoch_ns(b, origin),
      duration_ms = (b - a) / 1e6, kernel_active_ms = active / 1e6,
      kernel_active_pct = 100 * active / (b - a),
      device_energy_mj = unname(energy["device"]),
      dynamic_energy_mj = unname(energy["dynamic"]),
      avg_device_power_mw = unname(energy["device"]) / duration_s,
      avg_dynamic_power_mw = unname(energy["dynamic"]) / duration_s
    )
  })
  do.call(rbind, rows)
}

ke_pearson <- function(x, y) {
  ok <- is.finite(x) & is.finite(y)
  if (sum(ok) < 2 || stats::sd(x[ok]) == 0 || stats::sd(y[ok]) == 0)
    return(NA_real_)
  stats::cor(x[ok], y[ok])
}

analyze_kernel_energy <- function(
    telemetry, kernels = NULL, pm_kernel_metrics = NULL,
    pm_weight_metric = "sm__inst_executed_realtime.avg.pct_of_peak_sustained_elapsed",
    pm_min_coverage_pct = 99.9, idle_power_mw = 0, window_ms = 200) {
  for (name in c("pm_min_coverage_pct", "idle_power_mw", "window_ms")) {
    value <- get(name)
    if (length(value) != 1L || !is.finite(value)) stop(name, " must be a finite number")
  }
  if (idle_power_mw < 0) stop("idle_power_mw cannot be negative")
  if (pm_min_coverage_pct < 0 || pm_min_coverage_pct > 100)
    stop("pm_min_coverage_pct must be between 0 and 100")
  window_ns <- trunc(window_ms * 1e6)
  if (window_ns < 1 || window_ns > 2^53 - 1)
    stop("window_ms must represent between 1 and 2^53 - 1 nanoseconds")
  if (!is.null(pm_kernel_metrics) && is.null(kernels))
    stop("PM kernel metrics require a kernel activity CSV")

  input <- ke_load_telemetry(telemetry)
  samples <- input$samples
  events <- ke_load_kernels(kernels, input$origin)
  matched <- eligible <- 0
  if (!is.null(pm_kernel_metrics)) {
    pm <- ke_apply_pm(events, pm_kernel_metrics, pm_weight_metric, pm_min_coverage_pct)
    events <- pm$kernels
    matched <- pm$matched
    eligible <- pm$eligible
  }
  start <- samples$time[1]
  end <- tail(samples$time, 1)
  if (nrow(events)) {
    start <- max(start, events$.start[1])
    full_end <- start + ceiling(max(0, max(events$.end) - start) / window_ns) * window_ns
    end <- min(end, full_end)
    if (end < full_end)
      warning("Telemetry does not cover the complete final window; capture additional tail samples")
  } else warning("No valid kernel intervals; analyzing the complete telemetry timeline with 0% kernel activity")
  if (start >= end) stop("Telemetry and kernel timelines do not overlap")
  energy <- ke_integrate(samples, start, end, idle_power_mw)
  attributed <- if (nrow(events)) {
    ke_attribute(samples, events, start, end, idle_power_mw)
  } else list(kernels = events, totals = c(
    assigned = 0, unassigned = unname(energy["dynamic"]), pm_weighted = 0, fallback = 0
  ))
  windows <- ke_windows(samples, events, start, end, idle_power_mw, window_ns, input$origin)
  totals <- attributed$totals
  error <- unname(energy["dynamic"] - totals["assigned"] - totals["unassigned"])
  if (abs(error) > 1e-8 * max(1, abs(energy["dynamic"])))
    warning("Energy conservation error: ", format(error), " mJ; ",
            "the reference script's endpoint-clipped baseline is not additive across idle crossings")
  summary <- list(
    analysis_start_ns = ke_epoch_ns(start, input$origin),
    analysis_end_ns = ke_epoch_ns(end, input$origin),
    idle_power_mw = idle_power_mw, device_energy_mj = unname(energy["device"]),
    dynamic_energy_mj = unname(energy["dynamic"]),
    assigned_dynamic_energy_mj = unname(totals["assigned"]),
    unassigned_dynamic_energy_mj = unname(totals["unassigned"]),
    conservation_error_mj = error,
    utilization_dynamic_energy_pearson_r =
      ke_pearson(windows$kernel_active_pct, windows$dynamic_energy_mj),
    utilization_dynamic_power_pearson_r =
      ke_pearson(windows$kernel_active_pct, windows$avg_dynamic_power_mw),
    attribution_method = if (is.null(pm_kernel_metrics)) "equal_share_concurrent_kernels"
      else "hybrid_pm_weighted_with_equal_share_fallback",
    pm_weight_metric = if (is.null(pm_kernel_metrics)) "" else pm_weight_metric,
    pm_min_coverage_pct = if (is.null(pm_kernel_metrics)) "" else pm_min_coverage_pct,
    pm_matched_kernels = matched, pm_eligible_kernels = eligible,
    pm_weighted_energy_mj = unname(totals["pm_weighted"]),
    equal_share_fallback_energy_mj = unname(totals["fallback"])
  )
  events <- attributed$kernels
  events$start_ns <- ke_epoch_ns(events$.start, input$origin)
  events$end_ns <- ke_epoch_ns(events$.end, input$origin)
  list(kernels = events[, ke_kernel_fields], windows = windows,
       summary = data.frame(metric = names(summary),
                            value = vapply(summary, as.character, character(1))),
       origin = input$origin)
}

ke_create_plots <- function(result, output_dir) {
  windows <- result$windows
  elapsed <- ke_relative_ns(windows$start_ns, windows$start_ns[1]) / 1e6
  draw_png <- function(name, draw) {
    bitmap_type <- if (capabilities("cairo")) "cairo" else getOption("bitmapType")
    grDevices::png(file.path(output_dir, name), width = 1600, height = 800, res = 160,
                   type = bitmap_type)
    on.exit(grDevices::dev.off())
    draw()
  }
  draw_png("energy_timeline.png", function() {
    graphics::par(mar = c(5, 5, 4, 5))
    graphics::plot(elapsed, windows$dynamic_energy_mj, type = "o", col = "firebrick",
                   xlab = "Window start (ms)", ylab = "Energy per window (mJ)",
                   main = "GPU energy and kernel activity over time")
    graphics::par(new = TRUE)
    graphics::plot(elapsed, windows$kernel_active_pct, type = "l", col = "steelblue",
                   ylim = c(0, 100), axes = FALSE, xlab = "", ylab = "")
    graphics::axis(4, col.axis = "steelblue")
    graphics::mtext("Kernel active time (%)", side = 4, line = 3, col = "steelblue")
    graphics::legend("topright", c("Energy", "Kernel active time"),
                     col = c("firebrick", "steelblue"), lty = 1, bty = "n")
  })
  draw_png("utilization_energy_correlation.png", function() {
    graphics::plot(windows$kernel_active_pct, windows$dynamic_energy_mj,
                   xlab = "Kernel active time (%)", ylab = "Energy per window (mJ)",
                   main = "Kernel activity-energy correlation", pch = 19,
                   col = grDevices::adjustcolor("steelblue", alpha.f = 0.6))
    graphics::grid()
  })
}

write_kernel_energy <- function(result, output_dir, plot = FALSE) {
  if (!dir.exists(output_dir) && !dir.create(output_dir, recursive = TRUE))
    stop("Cannot create output directory: ", output_dir)
  for (name in c("kernels", "windows", "summary")) {
    filename <- c(kernels = "kernel_energy.csv", windows = "energy_windows.csv",
                  summary = "energy_summary.csv")[[name]]
    utils::write.csv(result[[name]], file.path(output_dir, filename),
                     row.names = FALSE, na = "")
  }
  if (plot) ke_create_plots(result, output_dir)
  invisible(result)
}
