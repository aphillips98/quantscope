## 04_statistical_analysis.R ---------------------------------------------------
## Confirmatory analysis for the primary response (and an ANOVA sweep over every
## available metric). Verifies assumptions automatically; when normality
## (Shapiro-Wilk) or homogeneity (Levene) fail it switches that response to the
## non-parametric path (Kruskal-Wallis). Computes partial eta^2, omega^2,
## normal-theory and bootstrap CIs, estimated marginal means and a combined
## factor-importance table (ANOVA + random forest + standardized regression).
## ---------------------------------------------------------------------------

run_statistics <- function(metrics) {
  set.seed(CFG$reproducibility$seed %||% 1L)
  primary <- attr(metrics, "primary") %||% CFG$metrics$primary
  factors <- Filter(function(f) f %in% names(metrics) &&
                      nlevels(droplevels(as.factor(metrics[[f]]))) >= 2,
                    CFG$design$factors)
  alpha  <- CFG$stats$alpha %||% 0.05
  type   <- CFG$stats$anova_type %||% 2
  boot   <- CFG$stats$bootstrap %||% list(enabled = TRUE, n_resamples = 2000,
                                          conf_level = 0.95)
  avail  <- attr(metrics, "available_metrics") %||%
    intersect(CFG$metrics$keep, names(metrics))

  ## --- Primary confirmatory ANOVA ----------------------------------------
  primary_fit <- fit_anova(primary, factors, metrics, type = type)
  if (is.null(primary_fit))
    stop("could not fit the primary ANOVA for ", primary)

  ## --- Assumptions on the primary model ----------------------------------
  resid  <- stats::residuals(primary_fit$fit)
  assum_rows <- lapply(factors, function(f) {
    v <- assumption_verdict(metrics[[primary]], metrics[[f]], resid, alpha)
    data.frame(response = primary, factor = f,
               shapiro_p = v$shapiro$p_value, levene_p = v$levene$p_value,
               normal = v$normal, homoscedastic = v$homoscedastic,
               use_parametric = v$use_parametric, stringsAsFactors = FALSE)
  })
  assumptions <- do.call(rbind, assum_rows)
  parametric_ok <- all(assumptions$use_parametric)

  ## --- Effect sizes -------------------------------------------------------
  effect_sizes <- primary_fit$table[, c("response", "term", "partial_eta_sq",
                                         "omega_sq")]

  ## --- Estimated marginal means + bootstrap CIs (per factor level) --------
  emm <- do.call(rbind, lapply(factors, function(f)
    marginal_means(primary_fit, f, conf = boot$conf_level %||% 0.95)))
  boot_ci <- do.call(rbind, lapply(factors, function(f) {
    parts <- split(metrics[[primary]], droplevels(as.factor(metrics[[f]])))
    do.call(rbind, lapply(names(parts), function(l) {
      b <- if (isTRUE(boot$enabled))
        bootstrap_ci(parts[[l]], mean, boot$n_resamples %||% 2000,
                     boot$conf_level %||% 0.95, CFG$reproducibility$seed)
        else data.frame(estimate = mean(parts[[l]], na.rm = TRUE),
                        lower = NA, upper = NA, method = "none")
      data.frame(response = primary, factor = f, level = l, b,
                 row.names = NULL)
    }))
  }))

  ## --- Non-parametric fallback (auto when assumptions fail) --------------
  nonparam <- NULL
  if (!parametric_ok) {
    nonparam <- do.call(rbind, lapply(factors, function(f) {
      k <- kruskal_check(metrics[[primary]], metrics[[f]])
      data.frame(response = primary, factor = f, k, row.names = NULL)
    }))
    message("[04] assumptions violated -> Kruskal-Wallis path engaged")
  }

  ## --- ANOVA sweep over all available metrics (for anova_results.csv) -----
  anova_all <- do.call(rbind, lapply(avail, function(m) {
    fit <- tryCatch(fit_anova(m, factors, metrics, type = type),
                    error = function(e) NULL)
    if (is.null(fit)) NULL else fit$table
  }))

  ## --- Combined factor importance (Figure 5) ------------------------------
  importance <- factor_importance(metrics, primary, factors,
                                  primary_fit$table)

  ## --- Descriptive statistics summary ------------------------------------
  summary_tbl <- descriptive_summary(metrics, avail, factors)

  message(sprintf("[04] primary=%s | parametric=%s | factors: %s",
                  primary, parametric_ok, paste(factors, collapse = ", ")))
  list(primary = primary, factors = factors, fit = primary_fit,
       anova = primary_fit$table, anova_all = anova_all,
       assumptions = assumptions, parametric = parametric_ok,
       effect_sizes = effect_sizes, emmeans = emm, bootstrap = boot_ci,
       nonparametric = nonparam, importance = importance, summary = summary_tbl,
       metrics = metrics)
}

## Combined, per-method-normalized factor-importance table for Figure 5.
factor_importance <- function(metrics, response, factors, anova_table) {
  rows <- list()

  ## ANOVA effect sizes.
  es <- anova_table[anova_table$term %in% factors, , drop = FALSE]
  rows$eta   <- data.frame(factor = es$term, method = "partial_eta_sq",
                           value = es$partial_eta_sq)
  rows$omega <- data.frame(factor = es$term, method = "omega_sq",
                           value = pmax(es$omega_sq, 0))

  d <- metrics[is.finite(metrics[[response]]), , drop = FALSE]

  ## Random forest importance (%IncMSE), normalized to [0,1].
  if (isTRUE(HAS$randomForest) && nrow(d) > length(factors) + 2) {
    rf <- tryCatch(randomForest::randomForest(
      stats::as.formula(paste(response, "~", paste(factors, collapse = " + "))),
      data = d, importance = TRUE, ntree = 500), error = function(e) NULL)
    if (!is.null(rf)) {
      imp <- randomForest::importance(rf)
      col <- if ("%IncMSE" %in% colnames(imp)) "%IncMSE" else colnames(imp)[1]
      val <- imp[factors, col]
      val <- pmax(val, 0); s <- sum(val, na.rm = TRUE)
      val <- if (is.finite(s) && s > 0) val / s else val
      rows$rf <- data.frame(factor = factors, method = "rf_importance",
                            value = as.numeric(val))
    }
  }

  ## Standardized linear-regression coefficients: |beta| aggregated per factor.
  sfit <- tryCatch(stats::lm(
    stats::as.formula(paste("scale(", response, ") ~",
                            paste(factors, collapse = " + "))), data = d),
    error = function(e) NULL)
  if (!is.null(sfit)) {
    co <- stats::coef(sfit); co <- co[names(co) != "(Intercept)"]
    fac_val <- vapply(factors, function(f) {
      idx <- startsWith(names(co), f)
      if (any(idx)) { v <- co[idx]; unname(v[which.max(abs(v))]) } else NA_real_
    }, numeric(1))
    rows$reg <- data.frame(factor = factors, method = "std_coef",
                           value = as.numeric(fac_val))
  }

  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

## Per-metric descriptive summary with the omnibus test per factor.
descriptive_summary <- function(metrics, metric_cols, factors) {
  do.call(rbind, lapply(metric_cols, function(m) {
    x <- metrics[[m]]
    base <- data.frame(
      metric = m, label = lab(m), n = sum(is.finite(x)),
      mean = mean(x, na.rm = TRUE), sd = stats::sd(x, na.rm = TRUE),
      median = stats::median(x, na.rm = TRUE),
      min = suppressWarnings(min(x, na.rm = TRUE)),
      max = suppressWarnings(max(x, na.rm = TRUE)),
      stringsAsFactors = FALSE)
    ## Kruskal-Wallis omnibus p across the primary factor set (assumption-free).
    for (f in factors) {
      k <- kruskal_check(x, metrics[[f]])
      base[[paste0("kw_p_", f)]] <- k$p_value
    }
    base
  }))
}
