## 07_generate_tables.R --------------------------------------------------------
## Export the statistical results as tidy tables (CSV + RDS + JSON via
## write_result) and, when xtable is available, publication booktabs .tex copies.
## Guarantees the four headline artefacts: anova_results, effect_sizes,
## tukey_results and statistics_summary.
## ---------------------------------------------------------------------------

generate_tables <- function(stats_res, posthoc, metrics = NULL) {
  ## --- ANOVA (full sweep, else primary) ----------------------------------
  anova_tbl <- stats_res$anova_all %||% stats_res$anova
  write_result(anova_tbl, "anova_results")

  ## --- Effect sizes ------------------------------------------------------
  write_result(stats_res$effect_sizes, "effect_sizes")

  ## --- Post-hoc (Tukey preferred; Dunn when non-parametric) --------------
  tukey_tbl <- posthoc$tukey %||% posthoc$dunn
  write_result(tukey_tbl, "tukey_results")

  ## --- Assumptions + EMMs + bootstrap + non-parametric -------------------
  write_result(stats_res$assumptions, "assumption_checks")
  write_result(stats_res$emmeans, "estimated_marginal_means")
  write_result(stats_res$bootstrap, "bootstrap_ci")
  if (!is.null(stats_res$nonparametric))
    write_result(stats_res$nonparametric, "nonparametric_results")
  write_result(stats_res$importance, "factor_importance")

  ## --- Headline summary --------------------------------------------------
  write_result(stats_res$summary, "statistics_summary")

  ## --- Pareto-optimal configurations (max throughput / min energy) -------
  pareto <- if (!is.null(metrics)) pareto_optimal_table(metrics) else NULL
  if (!is.null(pareto) && nrow(pareto))
    write_result(pareto, "pareto_optimal_configurations")

  ## --- Optional LaTeX booktabs -------------------------------------------
  if (has_pkg("xtable")) {
    emit_tex(anova_tbl, "anova_results", "Factorial ANOVA results")
    emit_tex(stats_res$effect_sizes, "effect_sizes", "Effect sizes")
    emit_tex(tukey_tbl, "tukey_results", "Significant post-hoc comparisons")
    if (!is.null(pareto) && nrow(pareto))
      emit_tex(pareto, "pareto_optimal_configurations",
               "Pareto-optimal configurations (max throughput, min total energy)")
  }
  message("[07] tables exported to ", CFG$paths$results_dir)
  invisible(TRUE)
}

emit_tex <- function(df, name, caption) {
  if (is.null(df) || !nrow(df)) return(invisible(NULL))
  tex <- file.path(CFG$paths$tables_dir, paste0(name, ".tex"))
  xt <- xtable::xtable(df, caption = caption, label = paste0("tab:", name))
  print(xt, file = tex, include.rownames = FALSE, booktabs = TRUE,
        floating = TRUE, NA.string = "NA",
        sanitize.text.function = function(x) x)
  invisible(tex)
}
