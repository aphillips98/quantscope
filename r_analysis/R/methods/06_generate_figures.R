## 06_generate_figures.R -------------------------------------------------------
## Produce the energy/throughput publication figures. Each figure is saved as
## PNG + PDF with its underlying data (.csv), the plot object (.rds) and a
## provenance sidecar (.json) carrying software version, date, sample size and
## repetition count.
## ---------------------------------------------------------------------------

generate_figures <- function(metrics, stats_res, posthoc) {
  primary <- stats_res$primary
  n_runs  <- nrow(metrics)
  reps    <- replicate_count(metrics)
  prov    <- function(n = n_runs) provenance(n = n, reps = reps)

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
      md_path <- paste0(fig_base_path("figure2j_energy_by_model_execmode_linear"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2j$plot, "figure2j_energy_by_model_execmode_linear",
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
      md_path <- paste0(fig_base_path("figure2k_energy_by_model_execmode_log"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2k$plot, "figure2k_energy_by_model_execmode_log",
             data = f2k$data, prov = prov(nrow(f2k$data)),
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
      md_path <- paste0(fig_base_path("figure2p_cpu_energy_by_model_linear"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2p$plot, "figure2p_cpu_energy_by_model_linear",
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
      md_path <- paste0(fig_base_path("figure2q_cpu_energy_by_model_log"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f2q$plot, "figure2q_cpu_energy_by_model_log",
             data = f2q$data, prov = prov(nrow(f2q$data)),
             width = 14, height = 5.5, dpi = 300)
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
      md_path <- paste0(fig_base_path("figure4g_throughput_by_model_execmode_linear"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4g$plot, "figure4g_throughput_by_model_execmode_linear",
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
      md_path <- paste0(fig_base_path("figure4h_throughput_by_model_execmode_log"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f4h$plot, "figure4h_throughput_by_model_execmode_log",
             data = f4h$data, prov = prov(nrow(f4h$data)),
             width = 14, height = 5.5, dpi = 300)
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
      md_path <- paste0(fig_base_path("figure1e_energy_vs_throughput_pareto"),
                        "_legend.md")
      writeLines(md, md_path)
      message("  [md] ", basename(md_path))
    }
    save_fig(f1e$plot, "figure1e_energy_vs_throughput_pareto",
             data = f1e$data, prov = prov(nrow(f1e$data)),
             width = 12, height = 8.5, dpi = 300)
  }

  invisible(TRUE)
}

## Median number of repetitions per non-empty design cell.
replicate_count <- function(metrics) {
  fs <- Filter(function(f) f %in% names(metrics), CFG$design$factors)
  if (!length(fs)) return(NA_integer_)
  as.integer(stats::median(table(interaction(metrics[fs], drop = TRUE))))
}


