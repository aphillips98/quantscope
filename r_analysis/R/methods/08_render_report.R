## 08_render_report.R ----------------------------------------------------------
## Assemble a self-contained markdown report of the confirmatory analysis with
## the reproducibility header (software version, date, repetitions, sample size)
## required on every artefact, linking the six figures and headline tables.
## ---------------------------------------------------------------------------

render_report <- function(metrics, design, stats_res, posthoc) {
  prov <- provenance(n = nrow(metrics), reps = replicate_count(metrics))
  L <- character(0)
  add <- function(...) L[[length(L) + 1]] <<- paste0(...)

  add("# Design Space Exploration -- Energy Characterization of LLM Inference")
  add("")
  add("## Reproducibility")
  add("")
  add("| Field | Value |")
  add("|---|---|")
  add("| Software version | ", prov$software_version, " |")
  add("| Pipeline version | ", prov$pipeline_version %||% "NA", " |")
  add("| Date | ", prov$date, " |")
  add("| Sample size (runs) | ", prov$sample_size, " |")
  add("| Repetitions / cell (median) | ", prov$repetitions, " |")
  add("| Random seed | ", prov$seed, " |")
  add("| Input dataset | ", CFG$paths$input_dir, " |")
  add("| Primary response | ", lab(stats_res$primary), " |")
  add("")

  ## Design.
  s <- design$summary
  add("## Experimental design")
  add("")
  add(sprintf("- Runs: **%d** across **%d** design cells (%s-%s repetitions each).",
              s$n_runs, s$n_cells, s$min_reps, s$max_reps))
  add(sprintf("- Factors: %s.", paste(stats_res$factors, collapse = ", ")))
  add(sprintf("- Fully balanced: **%s**; under-replicated cells: **%d**.",
              s$fully_balanced, s$under_replicated_cells))
  if (length(s$missing_columns))
    add(sprintf("- Missing expected columns: %s.",
                paste(s$missing_columns, collapse = ", ")))
  add("")

  ## Assumptions.
  add("## Assumption checks")
  add("")
  add("Normality (Shapiro-Wilk) and homogeneity (Levene) on the primary model. ",
      "When violated the analysis switches to Kruskal-Wallis automatically.")
  add("")
  add(md_table(stats_res$assumptions))
  add("")
  add(sprintf("**Path used:** %s.",
              if (isTRUE(stats_res$parametric)) "parametric (ANOVA + Tukey HSD)"
              else "non-parametric (Kruskal-Wallis + Dunn)"))
  add("")

  ## ANOVA + effect sizes.
  add("## Confirmatory model")
  add("")
  add(md_table(round_df(stats_res$anova)))
  add("")
  add("### Effect sizes")
  add("")
  add(md_table(round_df(stats_res$effect_sizes)))
  add("")

  ## Non-parametric.
  if (!is.null(stats_res$nonparametric)) {
    add("### Kruskal-Wallis (non-parametric omnibus)")
    add("")
    add(md_table(round_df(stats_res$nonparametric)))
    add("")
  }

  ## Post-hoc.
  ph <- posthoc$tukey %||% posthoc$dunn
  if (!is.null(ph)) {
    sig <- ph[isTRUE(ph$significant) | (is.finite(ph$p_adj) & ph$p_adj <
              (CFG$stats$alpha %||% 0.05)), , drop = FALSE]
    add("## Significant post-hoc comparisons")
    add("")
    add(sprintf("%d of %d comparisons significant at alpha = %.2f.",
                nrow(sig), nrow(ph), CFG$stats$alpha %||% 0.05))
    add("")
    if (nrow(sig)) add(md_table(round_df(utils::head(sig, 25))))
    add("")
  }

  ## Figures.
  add("## Figures")
  add("")
  ieee_dir <- if (!is.null(CFG$figures$ieee$subdir) && nzchar(CFG$figures$ieee$subdir))
    file.path(CFG$paths$figures_dir, CFG$figures$ieee$subdir) else CFG$paths$figures_dir
  if (dir.exists(ieee_dir)) {
    ## Figures live one family subfolder deep (e.g. cpu_energy_by_model_quant/).
    pdfs <- list.files(ieee_dir, pattern = "\\.pdf$", full.names = TRUE,
                      recursive = TRUE)
    for (pdf_path in sort(pdfs)) {
      fig_name <- sub("\\.pdf$", "", basename(pdf_path))
      md_path  <- file.path(dirname(pdf_path), paste0(fig_name, ".md"))
      desc <- if (file.exists(md_path)) {
        paste(readLines(md_path, warn = FALSE), collapse = " ")
      } else fig_name
      add(sprintf("- [%s](%s)\n\n  *%s*\n", fig_name, pdf_path, desc))
    }
  }

  out <- file.path(CFG$paths$reports_dir, "analysis_report.md")
  writeLines(unlist(L), out)
  message("[08] report written: ", out)
  invisible(out)
}

## --- small markdown helpers ------------------------------------------------
round_df <- function(df, digits = 4) {
  if (is.null(df)) return(df)
  for (c in names(df)) if (is.numeric(df[[c]])) df[[c]] <- round(df[[c]], digits)
  df
}

md_table <- function(df) {
  if (is.null(df) || !nrow(df)) return("_(no rows)_")
  hdr <- paste0("| ", paste(names(df), collapse = " | "), " |")
  sep <- paste0("|", paste(rep("---", ncol(df)), collapse = "|"), "|")
  body <- apply(df, 1, function(r)
    paste0("| ", paste(format(r, trim = TRUE), collapse = " | "), " |"))
  paste(c(hdr, sep, body), collapse = "\n")
}
