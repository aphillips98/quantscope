## functions/energy.R ----------------------------------------------------------
## Physically correct energy computation for the DSE pipeline.
##
## RULE: energy is NEVER a bare sum of power samples. It is always the time
## integral of instantaneous power,  E = integral(P dt).
##   * trapezoid: E = sum_i (P_i + P_{i+1})/2 * (t_{i+1} - t_i)   [preferred]
##   * riemann  : E = sum_i P_i * dt_i
## Baseline-adjusted energy removes the idle draw over the same duration:
##   E_adj = E_raw - BaselineAveragePower * InferenceDuration
## ---------------------------------------------------------------------------

## Integrate a single power trace. `time_s` is the cumulative timestamp of each
## sample; `power` the instantaneous power. Returns energy in joules (or NA).
integrate_power <- function(time_s, power, method = "trapezoid") {
  ok <- is.finite(time_s) & is.finite(power)
  time_s <- time_s[ok]; power <- power[ok]
  ord <- order(time_s); time_s <- time_s[ord]; power <- power[ord]
  n <- length(power)
  if (n < 2) return(NA_real_)
  dt <- diff(time_s)
  if (identical(method, "riemann")) {
    ## left Riemann sum: P_i * dt_i  (still an integral, not a plain power sum)
    sum(power[-n] * dt)
  } else {
    ## trapezoidal rule
    sum((power[-n] + power[-1]) / 2 * dt)
  }
}

## Baseline-adjusted energy: E_raw minus the idle envelope over the run duration.
##   baseline_power : average idle power [W] from the paired sleep run
##   duration_s     : inference duration [s]
baseline_adjust <- function(energy_raw, baseline_power, duration_s) {
  if (!is.finite(energy_raw) || !is.finite(baseline_power) || !is.finite(duration_s))
    return(NA_real_)
  energy_raw - baseline_power * duration_s
}

## Recompute per-run raw + adjusted energy for both rails directly from the raw
## sample traces (samples_long). Returns a data.frame keyed by run_id. Baseline
## power is taken from the wide table (idle_*_power_w) since the sleep runs are
## already reduced there.
energy_from_samples <- function(samples, runs, method = "trapezoid") {
  if (is.null(samples) || !nrow(samples)) return(NULL)
  idle <- runs[, c("run_id", "idle_socket_power_w", "idle_psu_power_w")]
  parts <- split(samples, samples$run_id)
  out <- lapply(names(parts), function(rid) {
    s <- parts[[rid]]
    dur <- integrate_time(s$time_s)
    e_socket <- integrate_power(s$time_s, s$socket_power_w, method)
    e_psu    <- integrate_power(s$time_s, s$psu_power_w, method)
    b <- idle[match(rid, idle$run_id), , drop = FALSE]
    data.frame(
      run_id                = rid,
      exec_time_s           = dur,
      total_energy_socket_j = e_socket,
      total_energy_psu_j    = e_psu,
      energy_adj_socket_j   = baseline_adjust(e_socket, b$idle_socket_power_w, dur),
      energy_adj_psu_j      = baseline_adjust(e_psu,    b$idle_psu_power_w,    dur),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, out)
}

## Duration from cumulative sample timestamps (span, not a sample count).
integrate_time <- function(time_s) {
  t <- time_s[is.finite(time_s)]
  if (length(t) < 2) return(NA_real_)
  max(t) - min(t)
}

## Derived efficiency metrics. `tokens` is the number of generated tokens (may be
## NA); energy is the whole-system (rail) energy in joules.
derive_efficiency <- function(energy_j, tokens, exec_time_s) {
  tps <- ifelse(is.finite(tokens) & is.finite(exec_time_s) & exec_time_s > 0,
                tokens / exec_time_s, NA_real_)
  ept <- ifelse(is.finite(energy_j) & is.finite(tokens) & tokens > 0,
                energy_j / tokens, NA_real_)
  tpj <- ifelse(is.finite(tokens) & is.finite(energy_j) & energy_j > 0,
                tokens / energy_j, NA_real_)
  data.frame(tokens_per_sec = tps, energy_per_token_j = ept,
             tokens_per_joule = tpj)
}
