## 06_generate_figures.R -------------------------------------------------------
## Produce the six publication figures (and nothing else, unless diagnostics mode
## is on). Each figure is saved as PNG + PDF with its underlying data (.csv), the
## plot object (.rds) and a provenance sidecar (.json) carrying software version,
## date, sample size and repetition count.
## ---------------------------------------------------------------------------

generate_figures <- function(metrics, stats_res, posthoc) {
  primary <- stats_res$primary
  n_runs  <- nrow(metrics)
  reps    <- replicate_count(metrics)
  prov    <- function(n = n_runs) provenance(n = n, reps = reps)

  ## ---- Figure 2i: energy vs quantization, CPU (top) / GPU (bottom) split -
  ## Same content as figure 2g (all models side by side within each
  ## quantization) but split into two stacked sub-panels -- CPU-only on top,
  ## GPU-only on the bottom -- each with its own y-axis. Execution mode is read
  ## from the marker shape (circle = CPU-only, triangle = GPU-only). Title /
  ## subtitle / caption go to a markdown sidecar.
  f2i <- fig_quant_energy_by_exec_models(metrics, energy = primary,
                                         energy_label = lab(primary),
                                         facet_exec = TRUE)
  if (!is.null(f2i$plot)) {
    if (!is.null(f2i$annot)) {
      md <- c(
        paste("#", f2i$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2i$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2i$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2i_quant_energy_cpu_gpu_models_split_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2i$plot, "figure2i_quant_energy_cpu_gpu_models_split",
             data = f2i$data, prov = prov(nrow(f2i$data)),
             width = 14, height = 8.5, dpi = 300)
  }

  ## ---- Figure 2j: energy vs model, CPU + GPU in one panel ---------------
  ## Both execution modes share one plot; x = model, colour = quantization,
  ## shape = execution mode (circle = CPU, square = GPU).
  f2j <- fig_model_energy_by_quant(metrics, energy = primary,
                                   energy_label = lab(primary),
                                   facet_exec = FALSE,
                                   log_y = FALSE,
                                   exec_shapes = c("CPU" = 21, "GPU" = 22))
  if (!is.null(f2j$plot)) {
    if (!is.null(f2j$annot)) {
      md <- c(
        paste("#", f2j$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2j$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2j$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2j_quant_energy_cpu_gpu_models_combined_linear_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2j$plot, "figure2j_quant_energy_cpu_gpu_models_combined_linear",
             data = f2j$data, prov = prov(nrow(f2j$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2k: energy vs model, CPU + GPU in one panel, log y --------
  f2k <- fig_model_energy_by_quant(metrics, energy = primary,
                                   energy_label = lab(primary),
                                   facet_exec = FALSE,
                                   log_y = TRUE,
                                   exec_shapes = c("CPU" = 21, "GPU" = 22))
  if (!is.null(f2k$plot)) {
    if (!is.null(f2k$annot)) {
      md <- c(
        paste("#", f2k$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2k$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2k$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2k_quant_energy_cpu_gpu_models_combined_log_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2k$plot, "figure2k_quant_energy_cpu_gpu_models_combined_log",
             data = f2k$data, prov = prov(nrow(f2k$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2l: GPU energy by model and quantization (linear) ----------
  ## GPU-only runs for V100/A100/H100 in one panel: x = model, colour =
  ## quantization, shape = GPU generation.
  f2l <- fig_gpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J]",
    response_name = "Total energy",
    log_y = FALSE
  )
  if (!is.null(f2l$plot)) {
    if (!is.null(f2l$annot)) {
      md <- c(
        paste("#", f2l$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2l$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2l$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2l_gpu_energy_by_model_quant_linear_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2l$plot, "figure2l_gpu_energy_by_model_quant_linear",
             data = f2l$data, prov = prov(nrow(f2l$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2m: GPU energy by model and quantization (log y) -----------
  f2m <- fig_gpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J] (log10)",
    response_name = "Total energy",
    log_y = TRUE
  )
  if (!is.null(f2m$plot)) {
    if (!is.null(f2m$annot)) {
      md <- c(
        paste("#", f2m$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2m$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2m$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2m_gpu_energy_by_model_quant_log_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2m$plot, "figure2m_gpu_energy_by_model_quant_log",
             data = f2m$data, prov = prov(nrow(f2m$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2n: GPU energy by model and quantization (linear, 50% CI) --
  f2n <- fig_gpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J]",
    response_name = "Total energy",
    log_y = FALSE,
    ci_level = 0.10
  )
  if (!is.null(f2n$plot)) {
    if (!is.null(f2n$annot)) {
      md <- c(
        paste("#", f2n$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2n$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2n$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2n_gpu_energy_by_model_quant_linear_ci50_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2n$plot, "figure2n_gpu_energy_by_model_quant_linear_ci50",
             data = f2n$data, prov = prov(nrow(f2n$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2o: GPU energy by model and quantization (log, 50% CI) -----
  f2o <- fig_gpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J] (log10)",
    response_name = "Total energy",
    log_y = TRUE,
    ci_level = 0.50
  )
  if (!is.null(f2o$plot)) {
    if (!is.null(f2o$annot)) {
      md <- c(
        paste("#", f2o$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2o$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2o$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2o_gpu_energy_by_model_quant_log_ci50_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2o$plot, "figure2o_gpu_energy_by_model_quant_log_ci50",
             data = f2o$data, prov = prov(nrow(f2o$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2p: CPU energy by model and quantization (Intel vs AMD) ----
  f2p <- fig_cpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J]",
    response_name = "Total energy",
    log_y = FALSE
  )
  if (!is.null(f2p$plot)) {
    if (!is.null(f2p$annot)) {
      md <- c(
        paste("#", f2p$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2p$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2p$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2p_cpu_energy_by_model_quant_linear_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2p$plot, "figure2p_cpu_energy_by_model_quant_linear",
             data = f2p$data, prov = prov(nrow(f2p$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 2q: CPU energy by model and quantization (log y) -----------
  f2q <- fig_cpu_generation_energy_by_model(
    metrics,
    energy = primary,
    energy_label = "Total energy [J] (log10)",
    response_name = "Total energy",
    log_y = TRUE
  )
  if (!is.null(f2q$plot)) {
    if (!is.null(f2q$annot)) {
      md <- c(
        paste("#", f2q$annot$title),
        "",
        "**Subtitle:**",
        "",
        f2q$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f2q$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure2q_cpu_energy_by_model_quant_log_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2q$plot, "figure2q_cpu_energy_by_model_quant_log",
             data = f2q$data, prov = prov(nrow(f2q$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 4e: throughput vs model, CPU (top) / GPU (bottom) split ----
  ## Same content as figure 4c (quantizations side by side within each model)
  ## but split into two stacked sub-panels -- CPU-only on top, GPU-only on the
  ## bottom -- each with its own y-axis. Title / subtitle / caption go to a
  ## markdown sidecar.
  f4e <- fig_model_energy_by_quant(metrics, energy = "tokens_per_sec",
                                   energy_label = lab("tokens_per_sec"),
                                   response_name = "Throughput", facet_exec = TRUE)
  if (!is.null(f4e$plot)) {
    if (!is.null(f4e$annot)) {
      md <- c(
        paste("#", f4e$annot$title),
        "",
        "**Subtitle:**",
        "",
        f4e$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f4e$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure4e_model_throughput_by_quant_split_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4e$plot, "figure4e_model_throughput_by_quant_split",
             data = f4e$data, prov = prov(nrow(f4e$data)),
             width = 13, height = 8.5, dpi = 300)
  }

  ## ---- Figure 4g: throughput vs model, CPU + GPU combined (linear) ------
  ## Combines the CPU (top) and GPU (bottom) subfigures from Figure 4e into a
  ## single panel: x = model, colour = quantization, shape = execution mode.
  f4g <- fig_model_energy_by_quant(metrics, energy = "tokens_per_sec",
                                   energy_label = lab("tokens_per_sec"),
                                   response_name = "Throughput",
                                   facet_exec = FALSE,
                                   log_y = FALSE)
  if (!is.null(f4g$plot)) {
    if (!is.null(f4g$annot)) {
      md <- c(
        paste("#", f4g$annot$title),
        "",
        "**Subtitle:**",
        "",
        f4g$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f4g$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure4g_model_throughput_by_quant_combined_linear_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4g$plot, "figure4g_model_throughput_by_quant_combined_linear",
             data = f4g$data, prov = prov(nrow(f4g$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 4h: throughput vs model, CPU + GPU combined (log y) --------
  ## Same as Figure 4g but with log10 y-axis and log-grid/ticks handled by the
  ## plotting function for readability across CPU and GPU ranges.
  f4h <- fig_model_energy_by_quant(metrics, energy = "tokens_per_sec",
                                   energy_label = lab("tokens_per_sec"),
                                   response_name = "Throughput",
                                   facet_exec = FALSE,
                                   log_y = TRUE,
                                   log_decade_grid = FALSE)
  if (!is.null(f4h$plot)) {
    if (!is.null(f4h$annot)) {
      md <- c(
        paste("#", f4h$annot$title),
        "",
        "**Subtitle:**",
        "",
        f4h$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f4h$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure4h_model_throughput_by_quant_combined_log_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4h$plot, "figure4h_model_throughput_by_quant_combined_log",
             data = f4h$data, prov = prov(nrow(f4h$data)),
             width = 14, height = 5.5, dpi = 300)
  }

  ## ---- Figure 4f: throughput vs quantization, CPU (top) / GPU (bottom) ---
  ## x = quantization, all models side by side within each quantization; split
  ## into two stacked sub-panels -- CPU-only on top, GPU-only on the bottom --
  ## each with its own y-axis. Execution mode is read from the marker shape
  ## (circle = CPU-only, triangle = GPU-only). Title / subtitle / caption go to
  ## a markdown sidecar.
  f4f <- fig_quant_energy_by_exec_models(metrics, energy = "tokens_per_sec",
                                         energy_label = lab("tokens_per_sec"),
                                         response_name = "Throughput",
                                         facet_exec = TRUE)
  if (!is.null(f4f$plot)) {
    if (!is.null(f4f$annot)) {
      md <- c(
        paste("#", f4f$annot$title),
        "",
        "**Subtitle:**",
        "",
        f4f$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f4f$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure4f_quant_throughput_cpu_gpu_models_split_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4f$plot, "figure4f_quant_throughput_cpu_gpu_models_split",
             data = f4f$data, prov = prov(nrow(f4f$data)),
             width = 14, height = 8.5, dpi = 300)
  }

  ## ---- Figure 1c: energy vs throughput, CPU (top) / GPU (bottom) --------
  ## Scatter of total energy against generation throughput; each point is a
  ## configuration mean with 95% CI on both axes. Colour = quantization, shape =
  ## execution mode; CPU on top, GPU on the bottom. Title / subtitle / caption
  ## go to a markdown sidecar.
  f1c <- fig_energy_vs_throughput(metrics, energy = primary,
                                  energy_label = lab(primary),
                                  tput = "tokens_per_sec",
                                  tput_label = lab("tokens_per_sec"))
  if (!is.null(f1c$plot)) {
    if (!is.null(f1c$annot)) {
      md <- c(
        paste("#", f1c$annot$title),
        "",
        "**Subtitle:**",
        "",
        f1c$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f1c$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure1c_energy_vs_throughput_split_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f1c$plot, "figure1c_energy_vs_throughput_split",
             data = f1c$data, prov = prov(nrow(f1c$data)),
             width = 12, height = 8.5, dpi = 300)
  }

  ## ---- Figure 1d: energy vs throughput, raw runs (no aggregation) -------
  ## Same as figure 1c but each point is an individual run -- no per-config mean
  ## and no confidence intervals. Title / subtitle / caption go to a sidecar.
  f1d <- fig_energy_vs_throughput(metrics, energy = primary,
                                  energy_label = lab(primary),
                                  tput = "tokens_per_sec",
                                  tput_label = lab("tokens_per_sec"),
                                  aggregate = FALSE)
  if (!is.null(f1d$plot)) {
    if (!is.null(f1d$annot)) {
      md <- c(
        paste("#", f1d$annot$title),
        "",
        "**Subtitle:**",
        "",
        f1d$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f1d$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure1d_energy_vs_throughput_raw_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f1d$plot, "figure1d_energy_vs_throughput_raw",
             data = f1d$data, prov = prov(nrow(f1d$data)),
             width = 12, height = 8.5, dpi = 300)
  }

  ## ---- Figure 1e: energy vs throughput with the Pareto frontier ---------
  ## Same as figure 1c (per-config means, CPU top / GPU bottom) with the
  ## per-panel Pareto frontier (minimise energy, maximise throughput) overlaid.
  ## Title / subtitle / caption go to a markdown sidecar.
  f1e <- fig_energy_vs_throughput(metrics, energy = primary,
                                  energy_label = lab(primary),
                                  tput = "tokens_per_sec",
                                  tput_label = lab("tokens_per_sec"),
                                  pareto = TRUE)
  if (!is.null(f1e$plot)) {
    if (!is.null(f1e$annot)) {
      md <- c(
        paste("#", f1e$annot$title),
        "",
        "**Subtitle:**",
        "",
        f1e$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f1e$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure1e_energy_vs_throughput_pareto_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f1e$plot, "figure1e_energy_vs_throughput_pareto",
             data = f1e$data, prov = prov(nrow(f1e$data)),
             width = 12, height = 8.5, dpi = 300)
  }

  ## ---- Figure 1f: energy vs throughput, raw runs with Pareto frontier ---
  ## Same as figure 1d (individual runs, no averaging) with the per-panel Pareto
  ## frontier (minimise energy, maximise throughput) over the raw runs overlaid.
  ## Title / subtitle / caption go to a markdown sidecar.
  f1f <- fig_energy_vs_throughput(metrics, energy = primary,
                                  energy_label = lab(primary),
                                  tput = "tokens_per_sec",
                                  tput_label = lab("tokens_per_sec"),
                                  aggregate = FALSE, pareto = TRUE)
  if (!is.null(f1f$plot)) {
    if (!is.null(f1f$annot)) {
      md <- c(
        paste("#", f1f$annot$title),
        "",
        "**Subtitle:**",
        "",
        f1f$annot$subtitle,
        "",
        "**Caption:**",
        "",
        f1f$annot$caption
      )
      md_path <- file.path(CFG$paths$figures_dir,
                           "figure1f_energy_vs_throughput_raw_pareto_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f1f$plot, "figure1f_energy_vs_throughput_raw_pareto",
             data = f1f$data, prov = prov(nrow(f1f$data)),
             width = 12, height = 8.5, dpi = 300)
  }

  ## ---- Figure 5: Factor importance --------------------------------------
  if (!is.null(stats_res$importance) && nrow(stats_res$importance)) {
    f4 <- fig_factor_importance(stats_res$importance)
    save_fig(f4$plot, "figure5_factor_importance", data = f4$data, prov = prov(),
             width = 9, height = 4.5)
  }

  ## ---- Diagnostics (supplementary only) ---------------------------------
  if (isTRUE(CFG$diagnostics$enabled)) generate_diagnostics(metrics, stats_res, prov)

  invisible(TRUE)
}

## Median number of repetitions per non-empty design cell.
replicate_count <- function(metrics) {
  fs <- Filter(function(f) f %in% names(metrics), CFG$design$factors)
  if (!length(fs)) return(NA_integer_)
  as.integer(stats::median(table(interaction(metrics[fs], drop = TRUE))))
}

## Dunn-test fallback forest (used when the parametric path is not valid).
fig_dunn_forest <- function(dunn_df, alpha = 0.05) {
  sig <- dunn_df[is.finite(dunn_df$p_adj) & dunn_df$p_adj < alpha, , drop = FALSE]
  if (!nrow(sig)) return(list(plot = NULL, data = sig))
  sig$label <- paste0(sig$comparison, "  (p=",
                      format.pval(sig$p_adj, digits = 2, eps = 1e-4), ")")
  sig <- sig[order(sig$factor, sig$Z), , drop = FALSE]
  sig$label <- factor(sig$label, levels = rev(unique(sig$label)))
  p <- ggplot2::ggplot(sig, ggplot2::aes(x = Z, y = label, colour = factor)) +
    ggplot2::geom_vline(xintercept = 0, linetype = "dashed", colour = "grey60") +
    ggplot2::geom_point(size = 2.2) +
    ggplot2::facet_grid(factor ~ ., scales = "free_y", space = "free_y") +
    scale_col_pub(guide = "none") +
    ggplot2::labs(title = "Significant pairwise differences (Dunn, BH-adjusted)",
                  subtitle = sprintf("Rank-sum Z statistic; adjusted p < %.2f", alpha),
                  x = "Dunn Z statistic", y = NULL) +
    theme_pub() +
    ggplot2::theme(strip.text.y = ggplot2::element_text(angle = 0))
  list(plot = p, data = sig)
}

## Supplementary diagnostics: distribution + Q-Q + residual views. Only emitted
## when --diagnostics is set; these belong to supplementary material.
generate_diagnostics <- function(metrics, stats_res, prov) {
  primary <- stats_res$primary
  ## Distribution of the primary response.
  dp <- ggplot2::ggplot(metrics, ggplot2::aes(x = .data[[primary]])) +
    ggplot2::geom_histogram(ggplot2::aes(y = ggplot2::after_stat(density)),
                            bins = 30, fill = "grey80", colour = "white") +
    ggplot2::geom_density(colour = "#B40426") +
    ggplot2::labs(title = "Diagnostic: response distribution", x = lab(primary),
                  y = "Density") + theme_pub()
  save_fig(dp, "supp_distribution", data = metrics[primary], prov = prov())

  ## Q-Q plot of model residuals.
  r <- stats::residuals(stats_res$fit$fit)
  qq <- ggplot2::ggplot(data.frame(r = r), ggplot2::aes(sample = r)) +
    ggplot2::stat_qq(colour = "#21908C") + ggplot2::stat_qq_line() +
    ggplot2::labs(title = "Diagnostic: residual Q-Q", x = "Theoretical",
                  y = "Sample") + theme_pub()
  save_fig(qq, "supp_qq_residuals", data = data.frame(residual = r), prov = prov())

  ## Residuals vs fitted.
  rf <- data.frame(fitted = stats::fitted(stats_res$fit$fit), resid = r)
  rvf <- ggplot2::ggplot(rf, ggplot2::aes(fitted, resid)) +
    ggplot2::geom_point(alpha = 0.6, colour = "#21908C") +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed") +
    ggplot2::labs(title = "Diagnostic: residuals vs fitted", x = "Fitted",
                  y = "Residual") + theme_pub()
  save_fig(rvf, "supp_residuals_fitted", data = rf, prov = prov())
  message("[06] diagnostics written to supplementary figures")
}
