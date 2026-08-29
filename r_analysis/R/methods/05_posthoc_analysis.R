## 05_posthoc_analysis.R -------------------------------------------------------
## Pairwise post-hoc comparisons. When the primary model met the parametric
## assumptions we run Tukey HSD; otherwise we run Dunn's test (Benjamini-Hochberg
## adjusted). Comparisons are produced for each grouping factor (Execution Mode,
## Model, Quantization and GPU Architecture) so Figure 6 can facet by factor.
## ---------------------------------------------------------------------------

run_posthoc <- function(stats_res) {
  metrics <- stats_res$metrics
  primary <- stats_res$primary
  conf    <- CFG$stats$bootstrap$conf_level %||% 0.95
  alpha   <- CFG$stats$alpha %||% 0.05

  group_factors <- Filter(function(f) f %in% names(metrics) &&
                            nlevels(droplevels(as.factor(metrics[[f]]))) >= 2,
                          unique(c(stats_res$factors, "gpu_arch")))

  tukey <- NULL; dunn <- NULL; effects <- NULL
  if (isTRUE(stats_res$parametric)) {
    ## Refit including gpu_arch so Tukey covers every grouping factor.
    fit <- fit_anova(primary, group_factors, metrics,
                     type = CFG$stats$anova_type %||% 2)
    tukey <- tukey_all(fit, group_factors, conf)
    if (!is.null(tukey)) {
      tukey$significant <- is.finite(tukey$p_adj) & tukey$p_adj < alpha
      effects <- tukey[, c("factor", "comparison", "mean_diff", "lower",
                           "upper", "p_adj", "significant")]
    }
    message(sprintf("[05] Tukey HSD: %d comparisons, %d significant",
                    if (is.null(tukey)) 0 else nrow(tukey),
                    if (is.null(tukey)) 0 else sum(tukey$significant, na.rm = TRUE)))
  } else {
    dunn <- do.call(rbind, lapply(group_factors, function(f) {
      d <- dunn_posthoc(metrics[[primary]], metrics[[f]], method = "BH")
      if (is.null(d)) NULL else cbind(factor = f, response = primary, d)
    }))
    if (!is.null(dunn))
      dunn$significant <- is.finite(dunn$p_adj) & dunn$p_adj < alpha
    ## Attach observed mean differences + CIs so Figure 6 can show effect sizes
    ## (in Joules) even on the non-parametric path; significance comes from Dunn.
    effects <- do.call(rbind, lapply(group_factors, function(f) {
      pe <- pairwise_effects(metrics[[primary]], metrics[[f]], conf)
      if (is.null(pe)) return(NULL)
      dd <- dunn[dunn$factor == f, , drop = FALSE]
      dkey <- vapply(strsplit(dd$comparison, " - ", fixed = TRUE), function(p)
        paste(sort(trimws(p)), collapse = "\r"), character(1))
      pe$p_adj       <- dd$p_adj[match(pe$pair_key, dkey)]
      pe$significant <- is.finite(pe$p_adj) & pe$p_adj < alpha
      data.frame(factor = f, pe[, c("comparison", "mean_diff", "lower",
                                    "upper", "p_adj", "significant")],
                 stringsAsFactors = FALSE)
    }))
    message(sprintf("[05] Dunn post-hoc: %d comparisons, %d significant",
                    if (is.null(dunn)) 0 else nrow(dunn),
                    if (is.null(dunn)) 0 else sum(dunn$significant, na.rm = TRUE)))
  }

  list(parametric = stats_res$parametric, factors = group_factors,
       tukey = tukey, dunn = dunn, effects = effects)
}
