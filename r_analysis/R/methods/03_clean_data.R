## 03_clean_data.R -------------------------------------------------------------
## Final tidy pass before analysis: drop runs with no primary response, remove
## unused factor levels, flag extreme outliers (reported, not deleted) and record
## the per-metric completeness that the report surfaces.
## ---------------------------------------------------------------------------

clean_data <- function(metrics) {
  primary <- attr(metrics, "primary") %||% CFG$metrics$primary
  n0 <- nrow(metrics)

  ## Drop rows missing the primary response -- they cannot enter the model.
  metrics <- metrics[is.finite(metrics[[primary]]), , drop = FALSE]

  ## Remove factor levels that no longer occur.
  for (f in intersect(c(CFG$design$factors, CFG$design$facet_factors),
                      names(metrics)))
    if (is.factor(metrics[[f]])) metrics[[f]] <- droplevels(metrics[[f]])

  ## Completeness report for every curated metric.
  metric_cols <- intersect(CFG$metrics$keep, names(metrics))
  completeness <- data.frame(
    metric = metric_cols,
    label  = lab(metric_cols),
    n_obs  = vapply(metric_cols, function(m) sum(is.finite(metrics[[m]])), integer(1)),
    n_missing = vapply(metric_cols, function(m) sum(!is.finite(metrics[[m]])), integer(1)),
    row.names = NULL, stringsAsFactors = FALSE)
  completeness$pct_complete <- round(100 * completeness$n_obs / nrow(metrics), 1)

  ## Outlier flag (>3 IQR from the quartiles) on the primary response -- kept.
  q <- stats::quantile(metrics[[primary]], c(.25, .75), na.rm = TRUE)
  iqr <- diff(q)
  outliers <- metrics[[primary]] < q[1] - 3 * iqr |
              metrics[[primary]] > q[2] + 3 * iqr
  n_out <- sum(outliers, na.rm = TRUE)

  write_result(completeness, "metric_completeness")
  attr(metrics, "primary") <- primary
  attr(metrics, "available_metrics") <-
    completeness$metric[completeness$n_obs >= 4]
  message(sprintf("[03] cleaned: %d -> %d runs | %d extreme outliers flagged (kept)",
                  n0, nrow(metrics), n_out))
  metrics
}
