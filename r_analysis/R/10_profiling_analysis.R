## 10_profiling_analysis.R -----------------------------------------------------
## Figures, tables and descriptive statistics for the Nsight + perf profiling
## data. Additive to the energy pipeline: figures continue the shared
## `figure<num>_<name>` numbering (figure12-figure20) after the energy figures,
## and result tables use `perf_` / `nsight_` prefixes so nothing collides with
## the existing outputs. Sourced and driven by run_analysis.R.
## ---------------------------------------------------------------------------

analyze_profiling <- function(prof) {
  prov <- provenance

  ## =========================================================================
  ## perf (Linux perf stat) -- CPU-only runs
  ## =========================================================================
  pw <- prof$perf_wide
  if (!is.null(pw) && nrow(pw)) {
    n <- nrow(pw)

    ## NOTE: the standalone L3 cache-miss figure was removed as redundant --
    ## `cache_miss_pct` is the last-level (L3) rate already shown as the L3 panel
    ## of the cache-hierarchy figure below.

    ## ---- Cache hierarchy miss rates (L1 / L2 / L3), CIs over reps.
    ## Only rendered when the extended counters are present (second batch on).
    ## cache_miss_pct is perf's generic cache-misses/references == last-level (L3).
    level_map <- c(l1d_miss_pct = "L1 data (L1d)",
                   l1i_miss_pct = "L1 instruction (L1i)",
                   l2_miss_pct = "L2 (from L1d misses)",
                   cache_miss_pct = "L3 (last-level cache)")
    level_cols <- names(level_map)[names(level_map) %in% names(pw) &
      vapply(names(level_map), function(cc)
        any(is.finite(pw[[cc]])), logical(1))]
    if (length(level_cols)) {
      model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                        "Gemma-2-9B", "Mixtral-8x7B")
      quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")
      arch_levels <- c("AMD", "Intel")

      build_hier_data <- function(src, model_keep = NULL, arch_keep = NULL) {
        if (is.null(src) || !nrow(src)) return(NULL)
        d <- src
        if (!is.null(model_keep) && "model" %in% names(d)) {
          d <- d[!is.na(d$model) & as.character(d$model) %in% model_keep, , drop = FALSE]
        }
        if (!is.null(arch_keep) && "cpu_arch" %in% names(d)) {
          d <- d[!is.na(d$cpu_arch) & as.character(d$cpu_arch) %in% arch_keep, , drop = FALSE]
        }
        if (!nrow(d)) return(NULL)
        out <- do.call(rbind, lapply(level_cols, function(cc) {
          keys <- c("model", "quant")
          if ("cpu_arch" %in% names(d) && any(!is.na(d$cpu_arch)))
            keys <- c("cpu_arch", keys)
          if ("node" %in% names(d) && all(!is.na(d$node)))
            keys <- c("node", keys)
          sub <- d[is.finite(d[[cc]]), c(keys, cc), drop = FALSE]
          if (!nrow(sub)) return(NULL)
          grp <- interaction(sub[keys], drop = TRUE, sep = "\r")
          do.call(rbind, lapply(split(sub, grp), function(p) {
            ci <- mean_ci(p[[cc]])
            row <- p[1, keys, drop = FALSE]
            row$level <- factor(level_map[[cc]], levels = unname(level_map))
            row$mean <- unname(ci["mean"])
            row$lower <- unname(ci["lower"])
            row$upper <- unname(ci["upper"])
            row
          }))
        }))
        if (is.null(out) || !nrow(out)) return(NULL)
        rownames(out) <- NULL
        if ("model" %in% names(out)) {
          present_models <- model_levels[model_levels %in% unique(as.character(out$model))]
          out$model <- factor(out$model, levels = present_models)
        }
        if ("quant" %in% names(out)) {
          present_quants <- quant_levels[quant_levels %in% unique(as.character(out$quant))]
          out$quant <- factor(out$quant, levels = present_quants)
        }
        if ("cpu_arch" %in% names(out)) {
          present_arch <- arch_levels[arch_levels %in% unique(as.character(out$cpu_arch))]
          out$cpu_arch <- factor(out$cpu_arch, levels = present_arch)
        }
        out
      }

      save_cache_hierarchy <- function(hier_df, fig_name,
                                       legend_top = FALSE,
                                       remove_legend_title = FALSE) {
        if (is.null(hier_df) || !nrow(hier_df)) return(invisible(NULL))
        fill_title <- if (isTRUE(remove_legend_title)) NULL else "Model"
        p <- ggplot2::ggplot(hier_df, ggplot2::aes(x = quant, y = mean,
                                                   fill = model)) +
          ggplot2::geom_col(position = ggplot2::position_dodge(width = 0.8),
                            width = 0.75) +
          ggplot2::facet_wrap(ggplot2::vars(level), scales = "free_y") +
          ggplot2::labs(title = "CPU cache hierarchy miss rates (L1 / L2 / L3)",
                        subtitle = paste("Mean miss rate per model x",
                                         "quantization. Panels follow the L1 ->",
                                         "L2 -> L3 hierarchy."),
                        x = "Quantization", y = "Miss rate [%]", fill = fill_title) +
          scale_fill_pub() + theme_pub()
        if (isTRUE(legend_top)) {
          p <- p + ggplot2::theme(
            legend.position = "top",
            legend.box = "horizontal",
            legend.direction = "horizontal",
            legend.justification = "center",
            legend.justification.bottom = "center",
            legend.spacing.x     = grid::unit(15, "pt"),
            legend.margin          = ggplot2::margin(1, 1, 1, 1),
          )
        }
        save_fig(p, fig_name, data = hier_df,
                 prov = prov(n), width = 11, height = 7)
      }

      save_ieee_copy <- function(fig_name) {
        ieee_subdir <- CFG$figures$ieee$subdir %||% "ieee_format"
        ieee_name <- sub("^figure[0-9]+[a-z]*_", "", fig_name)
        src_pdf <- file.path(CFG$paths$figures_dir, ieee_subdir,
                             paste0(ieee_name, ".pdf"))
        if (!file.exists(src_pdf)) return(invisible(FALSE))
        dst_dir <- file.path(CFG$paths$figures_dir, "ieee")
        if (!dir.exists(dst_dir)) dir.create(dst_dir, recursive = TRUE)
        file.copy(src_pdf, file.path(dst_dir, basename(src_pdf)), overwrite = TRUE)
        invisible(TRUE)
      }

      save_cache_hierarchy_arch_grid <- function(hier_df, fig_name,
                                                 subtitle,
                                                 md_lines = NULL) {
        if (is.null(hier_df) || !nrow(hier_df) ||
            !all(c("cpu_arch", "model", "quant", "level", "mean") %in% names(hier_df)))
          return(invisible(NULL))
        facet_layer <- if (requireNamespace("ggh4x", quietly = TRUE)) {
          ggh4x::facet_grid2(
            rows = ggplot2::vars(cpu_arch),
            cols = ggplot2::vars(level),
            scales = "free_y", switch = "y",
            independent = "y"
          )
        } else {
          ggplot2::facet_grid(
            rows = ggplot2::vars(cpu_arch),
            cols = ggplot2::vars(level),
            scales = "free_y", switch = "y"
          )
        }
        p <- ggplot2::ggplot(hier_df, ggplot2::aes(x = quant, y = mean, fill = model)) +
          ggplot2::geom_col(position = ggplot2::position_dodge(width = 0.78),
                            width = 0.68) +
          facet_layer +
          ggplot2::scale_y_continuous(
            labels = scales::label_comma(),
            expand = ggplot2::expansion(mult = c(0, 0.08))) +
          ggplot2::labs(
            title = "CPU cache hierarchy miss rates by CPU generation",
            subtitle = subtitle,
            x = "Quantization",
            y = "Miss rate [%]",
            fill = NULL
          ) +
          scale_fill_pub() +
          theme_pub(base_size = 13) +
          ggplot2::theme(
            legend.position = "top",
            legend.box = "horizontal",
            legend.direction = "horizontal",
            legend.justification = "center",
            legend.key.size = grid::unit(0.8, "lines"),
            panel.grid.major.x = ggplot2::element_blank(),
            panel.grid.minor = ggplot2::element_blank(),
            panel.grid.major.y = ggplot2::element_line(
              colour = "grey88", linewidth = 0.4),
            strip.text = ggplot2::element_text(face = "bold"),
            strip.background = ggplot2::element_rect(fill = "grey94", colour = NA),
            strip.placement = "outside",
            axis.text.x = ggplot2::element_text(angle = 0, hjust = 0.5),
            axis.title.x = ggplot2::element_text(face = "bold",
                                                 margin = ggplot2::margin(t = 8)),
            axis.title.y = ggplot2::element_text(face = "bold",
                                                 margin = ggplot2::margin(r = 8))
          )
        save_fig(p, fig_name, data = hier_df, prov = prov(n),
                 width = 12.5, height = 8.5)
        if (!is.null(md_lines)) {
          writeLines(md_lines, file.path(CFG$paths$figures_dir,
                                         paste0(fig_name, ".md")))
        }
        save_ieee_copy(fig_name)
      }

      ## All available CPU perf runs (existing Figure 21 behavior).
      hier <- build_hier_data(pw)
      save_cache_hierarchy(hier, "figure21_perf_cache_hierarchy")

      ## Intel-only counterpart from GPU_CPU ZIP perf rows (or any Intel CPU rows).
      intel_pw <- pw[
        (!is.na(pw$cpu_arch) & as.character(pw$cpu_arch) == "Intel") |
          (!is.na(pw$node) & grepl("GPU_CPU", as.character(pw$node), fixed = TRUE)),
        ,
        drop = FALSE
      ]
      hier_intel <- build_hier_data(intel_pw)
      save_cache_hierarchy(hier_intel, "figure21_perf_cache_hierarchy_intel",
               legend_top = TRUE, remove_legend_title = TRUE)

      hier_amd_intel <- build_hier_data(pw, arch_keep = arch_levels)
      save_cache_hierarchy_arch_grid(
        hier_amd_intel,
        "figure31_perf_cache_hierarchy_amd_intel",
        paste("Columns = cache level (L1d, L1i, L2, L3); rows = CPU generation",
              "(AMD, Intel). Bars show mean miss rate per model x quantization."),
        md_lines = c(
          "# CPU cache hierarchy miss rates by architecture (AMD vs Intel)",
          "",
          "Row 1: AMD CPU runs across all available models.",
          "Row 2: Intel CPU runs across all available models."
        )
      )

      focus_models <- c("Phi-3.5-mini-3.8B", "Llama-3.1-8B")
      hier_amd_intel_focus <- build_hier_data(
        pw,
        model_keep = focus_models,
        arch_keep = arch_levels
      )
      save_cache_hierarchy_arch_grid(
        hier_amd_intel_focus,
        "figure31b_perf_cache_hierarchy_amd_intel_focus_models",
        paste("Columns = cache level (L1d, L1i, L2, L3); rows = CPU generation",
              "(AMD, Intel). Restricted to Phi-3.5-mini-3.8B and Llama-3.1-8B."),
        md_lines = c(
          "# CPU cache hierarchy miss rates by architecture (AMD vs Intel), focused models",
          "",
          "Rows: AMD and Intel CPU runs.",
          "Models: Phi-3.5-mini-3.8B and Llama-3.1-8B only."
        )
      )

      ## ---- Cache-miss rate by level, stacked panels (L1d / L2 / L3) in the
      ## figure7 aesthetic: x = model, one point per quantization with 95% CI.
      cache_level_map <- c(l1d_miss_pct   = "L1 data (L1d)",
                           l2_miss_pct    = "L2 (from L1d misses)",
                           cache_miss_pct = "L3 (last-level)")
      fcache <- prof_cache_points_ci(
        pw, cache_level_map, "Cache-miss rate [%]",
        "CPU cache-miss rate by level (L1d / L2 / L3)",
        paste("perf stat (user-mode); each point = mean over repetitions,",
              "error bars = 95% CI. Colour = quantization."),
        "Panels top-to-bottom: L1d, L2, L3. Each panel uses its own y-axis.")
      if (!is.null(fcache))
        save_fig(fcache$plot, "figure28_perf_cache_miss_levels",
                 data = fcache$data, prov = prov(n), width = 13, height = 11)
    }

    ## Summary table (per model x quant means of the key derived metrics).
    metrics_cols <- intersect(c("ipc", "cpi", "ghz", "cache_miss_pct",
                                "branch_miss_pct", "l1d_miss_pct", "l1i_miss_pct",
                                "l2_miss_pct", "instructions", "cycles",
                                "task_clock_ns", "page_faults"), names(pw))
    summ <- stats::aggregate(pw[, metrics_cols, drop = FALSE],
                             by = list(model = pw$model, quant = pw$quant),
                             FUN = function(v) round(mean(v, na.rm = TRUE), 4))
    write_result(summ, "perf_summary_by_model_quant")

    ## Correlation among perf counters.
    corr <- prof_correlation(pw, c("ipc", "cpi", "ghz", "cache_miss_pct",
                                   "branch_miss_pct", "l1d_miss_pct",
                                   "l1i_miss_pct", "l2_miss_pct", "instructions",
                                   "cycles", "page_faults"),
                             method = CFG$stats$correlation$method %||% "pearson")
    if (!is.null(corr)) write_result(corr, "perf_counter_correlation")

    ## Optional: relate CPU efficiency to energy (config-level join).
    if (!is.null(prof$energy_cfg)) {
      j <- merge(pw, prof$energy_cfg, by = c("node", "model", "quant"),
                 suffixes = c("", "_energy"))
      yvar <- if ("energy_per_token_j" %in% names(j)) "energy_per_token_j" else
        if ("energy_psu_j" %in% names(j)) "energy_psu_j" else NA
      ## -------------------------------------------------------------------
      ## How perf counters drive energy and throughput. A counter/outcome
      ## correlation table and standardized regressions ranking the drivers.
      ## -------------------------------------------------------------------
      tput_var <- if ("generation_tps" %in% names(j)) "generation_tps" else NA

      ## Correlation of each perf counter with the energy/throughput outcomes.
      counters <- intersect(c("ipc", "cpi", "ghz", "cache_miss_pct",
                              "branch_miss_pct", "l1d_miss_pct", "l1i_miss_pct",
                              "l2_miss_pct", "page_faults"), names(j))
      outcomes <- intersect(c(yvar, tput_var), names(j))
      outcomes <- outcomes[!is.na(outcomes)]
      if (length(counters) && length(outcomes)) {
        oc <- do.call(rbind, lapply(outcomes, function(oc_name) {
          do.call(rbind, lapply(counters, function(cn) {
            ok <- is.finite(j[[cn]]) & is.finite(j[[oc_name]])
            if (sum(ok) < 3L || stats::sd(j[[cn]][ok]) == 0 ||
                stats::sd(j[[oc_name]][ok]) == 0)
              return(NULL)
            ct <- suppressWarnings(stats::cor.test(j[[cn]][ok], j[[oc_name]][ok],
                                                   method = "pearson"))
            data.frame(outcome = oc_name, counter = cn,
                       r = unname(ct$estimate), p_value = ct$p.value,
                       n = sum(ok), stringsAsFactors = FALSE)
          }))
        }))
        if (!is.null(oc) && nrow(oc)) {
          oc[, c("r", "p_value")] <- round(oc[, c("r", "p_value")], 4)
          write_result(oc, "perf_outcome_correlation")
        }
      }

      ## Standardized linear regressions: which counters most drive the outcome.
      predictors <- intersect(c("cache_miss_pct", "branch_miss_pct", "ipc",
                                "ghz", "l1d_miss_pct", "l2_miss_pct"), names(j))
      fit_std <- function(outcome_name) {
        keep <- c(outcome_name, predictors)
        d <- j[stats::complete.cases(j[, keep, drop = FALSE]), keep, drop = FALSE]
        preds <- predictors[vapply(predictors, function(v)
          stats::sd(d[[v]]) > 0, logical(1))]
        if (nrow(d) <= length(preds) + 1L || !length(preds)) return(NULL)
        z <- as.data.frame(scale(d[, c(outcome_name, preds), drop = FALSE]))
        form <- stats::as.formula(paste(outcome_name, "~",
                                        paste(preds, collapse = " + ")))
        co <- summary(stats::lm(form, data = z))$coefficients
        co <- co[rownames(co) != "(Intercept)", , drop = FALSE]
        data.frame(outcome = outcome_name, predictor = rownames(co),
                   std_coef = round(co[, "Estimate"], 4),
                   p_value = round(co[, "Pr(>|t|)"], 4),
                   n = nrow(d), stringsAsFactors = FALSE)
      }
      reg <- do.call(rbind, Filter(Negate(is.null),
                                   lapply(outcomes, fit_std)))
      if (!is.null(reg) && nrow(reg)) {
        rownames(reg) <- NULL
        write_result(reg, "perf_outcome_regression")
      }
    }
  } else {
    message("[10] no perf runs -- skipping perf figures")
  }

  ## =========================================================================
  ## Nsight Systems -- GPU-only runs
  ## =========================================================================
  nw <- prof$nsight_wide
  kern <- prof$kernels
  if (!is.null(nw) && nrow(nw)) {
    n <- nrow(nw)

    ## ---- N1: kernel time composition (top kernels, share of GPU kernel time)
    if (!is.null(kern) && nrow(kern)) {
      k <- kern
      k$kshort <- short_kernel_name(k$kernel)
      ## top kernels globally by total time; lump the rest as "Other".
      by_short <- stats::aggregate(k$total_time_ns, by = list(kshort = k$kshort),
                                   FUN = function(v) sum(v, na.rm = TRUE))
      by_short <- by_short[order(-by_short$x), ]
      topn <- utils::head(by_short$kshort, 7)
      k$kgroup <- ifelse(k$kshort %in% topn, k$kshort, "Other")
      k$cfg <- paste(k$model, k$quant, sep = " / ")
      ## ---- N1b: same composition, NON-normalized (absolute device time in s)
      f_abs <- prof_stacked_absolute(k, "cfg", "total_time_ns", "kgroup",
                              "GPU kernel time (s)",
                              "GPU kernel-time composition (Nsight, absolute)",
                              "Top kernels by total device time; remainder lumped as 'Other'.",
                              fill_lab = "Kernel", scale_factor = 1e-9)
      if (!is.null(f_abs)) save_fig(f_abs$plot, "figure16b_nsight_kernel_time_abs",
                                data = f_abs$data, prov = prov(n),
                                width = 12, height = 6.5)

      ## ---- N1c: same composition, faceted per model (one panel each).
      f_abs_m <- prof_stacked_absolute_by_model(
        k, "total_time_ns", "kgroup",
        "GPU kernel time (s)",
        "GPU kernel-time composition by model (Nsight, absolute)",
        paste("Top kernels by total device time; remainder lumped as 'Other'.",
              "One panel per model, x = quantization."),
        fill_lab = "Kernel", scale_factor = 1e-9)
      if (!is.null(f_abs_m))
        save_fig(f_abs_m$plot, "figure16c_nsight_kernel_time_abs_by_model",
                 data = f_abs_m$data, prov = prov(n),
                 width = 12, height = 9.5)

      ## ---- N1e: focused model x GPU grid (rows = model, cols = GPU arch).
      ## Models: Phi-3.5-mini-3.8B and Llama-3.1-8B only.
      ## Quantizations: Q4_K_M / Q5_K_M / Q6_K / Q8_0.
      f_abs_grid <- prof_stacked_absolute_model_gpu_grid(
        k, "total_time_ns", "kgroup",
        "GPU kernel time (s)",
        "GPU kernel-time composition by model and GPU generation",
        paste("Top kernels by total device time; remainder lumped as 'Other'.",
              "Rows = model (Phi-3.5-mini-3.8B, Llama-3.1-8B),",
              "columns = GPU generation (V100, A100, H100)."),
        fill_lab = "Kernel", scale_factor = 1e-9,
        model_keep = c("Phi-3.5-mini-3.8B", "Llama-3.1-8B"),
        quant_keep = c("Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0"),
        gpu_keep = c("V100", "A100", "H100")
      )
      if (!is.null(f_abs_grid))
        save_fig(f_abs_grid$plot, "figure32_nsight_kernel_time_by_gpu_model_grid",
                 data = f_abs_grid$data, prov = prov(n),
                 width = 12.5, height = 8.5)

      ## ---- N1d: total GPU kernel runtime by GPU generation in one panel.
      ## x = model, point per quantization + CI, shape = GPU generation.
      f_rt_lin <- prof_gpu_kernel_runtime_ci(
        k, "Total GPU kernel time [s]",
        "GPU kernel runtime by GPU generation (V100 / A100 / H100)",
        paste("GPU-only Nsight runs; response = sum of all kernels' device time",
          "per run. Each point = mean over repetitions, error bars = 95% CI.",
          "Colour = quantization, shape = GPU generation."),
        "Unified panel with linear y-axis.",
        log_y = FALSE)
      if (!is.null(f_rt_lin)) save_fig(f_rt_lin$plot, "figure29a_nsight_kernel_runtime_gpu_linear",
                data = f_rt_lin$data, prov = prov(n),
                width = 11, height = 6)

      f_rt_log <- prof_gpu_kernel_runtime_ci(
        k, "Total GPU kernel time [s] (log10)",
        "GPU kernel runtime by GPU generation (V100 / A100 / H100)",
        paste("GPU-only Nsight runs; response = sum of all kernels' device time",
          "per run. Each point = mean over repetitions, error bars = 95% CI.",
          "Colour = quantization, shape = GPU generation."),
        "Unified panel with logarithmic y-axis.",
        log_y = TRUE)
      if (!is.null(f_rt_log)) save_fig(f_rt_log$plot, "figure29b_nsight_kernel_runtime_gpu_log",
                data = f_rt_log$data, prov = prov(n),
                width = 11, height = 6)
    }

    ## ---- N2: CUDA API time breakdown (memcpy / sync / launch)
    api_cols <- intersect(c("cuda_memcpy_time_ns", "cuda_sync_time_ns",
                            "cuda_launch_time_ns"), names(nw))
    if (length(api_cols) >= 2) {
      long <- do.call(rbind, lapply(api_cols, function(cc) {
        data.frame(cfg = paste(nw$model, nw$quant, sep = " / "),
                   category = c(cuda_memcpy_time_ns = "Memcpy",
                                cuda_sync_time_ns = "Stream sync",
                                cuda_launch_time_ns = "Kernel launch")[[cc]],
                   value = suppressWarnings(as.numeric(nw[[cc]])),
                   stringsAsFactors = FALSE)
      }))
      ## ---- N2b: same breakdown, NON-normalized (absolute CUDA API time in s)
      f_abs <- prof_stacked_absolute(long, "cfg", "value", "category",
                              "CUDA API time (s)",
                              "CUDA API time composition (Nsight, absolute)",
                              "Where host-side CUDA time goes per configuration.",
                              fill_lab = "CUDA API", scale_factor = 1e-9)
      if (!is.null(f_abs)) save_fig(f_abs$plot, "figure17b_nsight_cuda_api_abs",
                                data = f_abs$data, prov = prov(n),
                                width = 12, height = 6.5)
    }

    ## ---- N3: host<->device transfer volume (HtoD / DtoH)
    gm <- prof$gpu_mem
    if (!is.null(gm) && nrow(gm)) {
      ## ---- N3b: transfer "bandwidth" = memcpy volume / total kernel runtime,
      ## combined over both directions (HtoD + DtoH), by GPU generation.
      f_bw <- prof_gpu_transfer_bandwidth_ci(
        kern, gm, "Transfer volume / compute time [GB/s]",
        "GPU transfer bandwidth by GPU generation (HtoD + DtoH combined)",
        paste("GPU-only Nsight runs; bandwidth = total memcpy data volume",
              "(HtoD + DtoH) divided by the run's total kernel runtime. Each",
              "point = mean over repetitions, error bars = 95% CI. Colour =",
              "quantization, shape = GPU generation."),
        paste("Panels top-to-bottom: V100 (circle), A100 (triangle), H100",
              "(square). Each GPU panel uses its own y-axis."),
        combine = TRUE)
      if (!is.null(f_bw)) save_fig(f_bw$plot, "figure30_nsight_transfer_bandwidth",
                                data = f_bw$data, prov = prov(n),
                                width = 11, height = 11)

      ## ---- N3c: same transfer-bandwidth response in one unified panel,
      ## combining V100/A100/H100 with a logarithmic y-axis.
      f_bw_log <- prof_gpu_transfer_bandwidth_ci(
        kern, gm, "Transfer volume / compute time [GB/s] (log10)",
        "GPU transfer bandwidth (combined panel, log scale)",
        paste("GPU-only Nsight runs; bandwidth = total memcpy data volume",
              "(HtoD + DtoH) divided by the run's total kernel runtime. Each",
              "point = mean over repetitions, error bars = 95% CI. Colour =",
              "quantization, shape = GPU generation."),
        "Single panel combining V100, A100 and H100 on a log10 y-axis.",
        combine = TRUE, single_panel = TRUE, log_y = TRUE)
      if (!is.null(f_bw_log))
        save_fig(f_bw_log$plot, "figure33_nsight_transfer_bandwidth_combined_log",
                 data = f_bw_log$data, prov = prov(n),
                 width = 11, height = 6)
    }

    ## ---- summary table (per run, curated columns)
    keep <- intersect(c("model", "quant", "kernel_total_time_ns",
                        "kernel_instances", "n_distinct_kernels",
                        "top_kernel_time_pct", "cuda_api_total_time_ns",
                        "cuda_memcpy_time_ns", "cuda_sync_time_ns",
                        "gpu_memcpy_htod_mb", "gpu_memcpy_dtoh_mb"), names(nw))
    write_result(nw[, keep, drop = FALSE], "nsight_summary_by_run")

  } else {
    message("[10] no Nsight runs -- skipping Nsight figures")
  }

  invisible(TRUE)
}
