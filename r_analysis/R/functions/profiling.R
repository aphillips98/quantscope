## functions/profiling.R -------------------------------------------------------
## Helper functions for the ADDITIVE Nsight + perf profiling analysis (stages
## 09/10). Reuses the shared helpers (CFG, save_fig, write_result, theme_pub,
## coerce_factors) sourced by the orchestrator. Nothing here modifies the energy
## pipeline; it only reads the profiling CSVs produced by
## etl/build_dataset.py (profiling pipeline).
## ---------------------------------------------------------------------------

## Read one profiling CSV from the input dir; returns NULL when absent/empty.
read_profiling_csv <- function(name) {
  path <- file.path(CFG$paths$input_dir, name)
  if (!file.exists(path)) {
    message(sprintf("[09] %s not found -- skipping", name))
    return(NULL)
  }
  df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = TRUE)
  if (!nrow(df)) return(NULL)
  ## Optional exclusion of the extra Q2_K level (mirrors the energy pipeline).
  if (isTRUE(CFG$design$exclude_q2k) && "quant" %in% names(df))
    df <- df[df$quant != "Q2_K", , drop = FALSE]
  if (!nrow(df)) return(NULL)
  coerce_factors(df)
}

## Collapse a long CUDA kernel signature to a short, readable label.
short_kernel_name <- function(x) {
  x <- as.character(x)
  ## strip a leading "void " and any template/argument tail
  base <- sub("^void\\s+", "", x)
  base <- sub("[<(].*$", "", base)
  base <- sub("::$", "", base)
  base <- trimws(base)
  ifelse(nchar(base) == 0, substr(x, 1, 40), base)
}

## Stacked composition bar (NON-normalized): absolute magnitude of `value` by
## `fill` group, per run/config. Same aggregation as prof_stacked_share but the
## bars keep their true height (position = "stack") instead of being rescaled to
## 100%. `scale_factor` rescales the summed value (e.g. 1e-9 for ns -> s).
prof_stacked_absolute <- function(df, group_col, value_col, fill_col,
                                  ylab, title, subtitle = NULL, fill_lab = NULL,
                                  scale_factor = 1,
                                  y_labels = scales::label_comma()) {
  df <- df[is.finite(df[[value_col]]), , drop = FALSE]
  if (!nrow(df)) return(NULL)
  agg <- stats::aggregate(df[[value_col]],
                          by = list(g = df[[group_col]], f = df[[fill_col]]),
                          FUN = function(v) sum(v, na.rm = TRUE))
  names(agg)[3] <- "value"
  agg$value <- agg$value * scale_factor
  p <- ggplot2::ggplot(agg, ggplot2::aes(x = g, y = value, fill = f)) +
    ggplot2::geom_col(position = "stack", width = 0.8) +
    ggplot2::scale_y_continuous(labels = y_labels,
                                expand = ggplot2::expansion(mult = c(0, 0.05))) +
    ggplot2::labs(title = title, subtitle = subtitle, x = NULL, y = ylab,
                  fill = fill_lab %||% fill_col) +
    scale_fill_pub() +
    theme_pub() +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 30, hjust = 1))
  list(plot = p, data = agg)
}

## Stacked composition bars split per model: one panel per model, x = quant,
## bar height = absolute summed `value_col` by `fill_col`. Faceted counterpart
## to prof_stacked_absolute; the y-axis is shared across panels so models are
## directly comparable. `scale_factor` rescales the summed value (e.g. 1e-9 for
## ns -> s). Requires `model` and `quant` columns in `df`.
prof_stacked_absolute_by_model <- function(df, value_col, fill_col,
                                           ylab, title, subtitle = NULL,
                                           fill_lab = NULL, scale_factor = 1,
                                           y_labels = scales::label_comma()) {
  req <- c("model", "quant", value_col, fill_col)
  if (length(setdiff(req, names(df)))) return(NULL)
  df <- df[is.finite(df[[value_col]]) & !is.na(df$model) & !is.na(df$quant), ,
           drop = FALSE]
  if (!nrow(df)) return(NULL)

  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")
  present_models <- model_levels[model_levels %in% unique(as.character(df$model))]
  present_quants <- quant_levels[quant_levels %in% unique(as.character(df$quant))]
  if (!length(present_models) || !length(present_quants)) return(NULL)

  agg <- stats::aggregate(df[[value_col]],
                          by = list(model = df$model, quant = df$quant,
                                    f = df[[fill_col]]),
                          FUN = function(v) sum(v, na.rm = TRUE))
  names(agg)[4] <- "value"
  agg$value <- agg$value * scale_factor
  agg$model <- factor(agg$model, levels = present_models)
  agg$quant <- factor(agg$quant, levels = present_quants)

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = quant, y = value, fill = f)) +
    ggplot2::geom_col(position = "stack", width = 0.5) +
    ggplot2::facet_wrap(ggplot2::vars(model), scales = "free_x") +
    ggplot2::scale_y_continuous(labels = y_labels,
                                expand = ggplot2::expansion(mult = c(0, 0.18))) +
    ggplot2::labs(title = title, subtitle = subtitle, x = "Quantization",
                  y = ylab, fill = fill_lab %||% fill_col) +
    scale_fill_pub() +
    theme_pub() +
    ggplot2::theme(
      axis.text.x     = ggplot2::element_text(angle = 30, hjust = 1),
      legend.key.size = grid::unit(0.7, "lines"),
      legend.title = ggplot2::element_blank()
    )
  list(plot = p, data = agg)
}

## Stacked absolute kernel-time bars in a model x GPU-generation grid:
## columns = GPU generation, rows = model, x = quantization.
## Intended for focused comparisons on a subset of models/quantizations.
prof_stacked_absolute_model_gpu_grid <- function(df, value_col, fill_col,
                                                 ylab, title, subtitle = NULL,
                                                 fill_lab = NULL,
                                                 scale_factor = 1,
                                                 y_labels = scales::label_comma(),
                                                 model_keep = c("Phi-3.5-mini-3.8B", "Llama-3.1-8B"),
                                                 quant_keep = c("Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0"),
                                                 gpu_keep = c("V100", "A100", "H100")) {
  req <- c("model", "quant", "gpu_arch", value_col, fill_col)
  if (length(setdiff(req, names(df)))) return(NULL)

  d <- df[
    is.finite(df[[value_col]]) &
      !is.na(df$model) & !is.na(df$quant) & !is.na(df$gpu_arch) &
      as.character(df$model) %in% model_keep &
      as.character(df$quant) %in% quant_keep &
      as.character(df$gpu_arch) %in% gpu_keep,
    , drop = FALSE
  ]
  if (!nrow(d)) return(NULL)

  present_models <- model_keep[model_keep %in% unique(as.character(d$model))]
  present_quants <- quant_keep[quant_keep %in% unique(as.character(d$quant))]
  present_gpus <- gpu_keep[gpu_keep %in% unique(as.character(d$gpu_arch))]
  if (!length(present_models) || !length(present_quants) || !length(present_gpus))
    return(NULL)

  agg <- stats::aggregate(
    d[[value_col]],
    by = list(model = d$model, gpu_arch = d$gpu_arch, quant = d$quant,
              f = d[[fill_col]]),
    FUN = function(v) sum(v, na.rm = TRUE)
  )
  names(agg)[5] <- "value"
  agg$value <- agg$value * scale_factor

  agg$model <- factor(agg$model, levels = present_models)
  agg$gpu_arch <- factor(agg$gpu_arch, levels = present_gpus)
  agg$quant <- factor(agg$quant, levels = present_quants)

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = quant, y = value, fill = f)) +
    ggplot2::geom_col(position = "stack", width = 0.62) +
    ggplot2::facet_wrap(~ model + gpu_arch,
                        ncol = length(present_gpus),
                        scales = "free_y") +
    ggplot2::scale_y_continuous(
      labels = y_labels,
      expand = ggplot2::expansion(mult = c(0, 0.14))
    ) +
    ggplot2::labs(
      title = title,
      subtitle = subtitle,
      x = "Quantization",
      y = ylab,
      fill = fill_lab %||% fill_col
    ) +
    scale_fill_pub() +
    theme_pub() +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      axis.text.x = ggplot2::element_text(angle = 30, hjust = 1),
      strip.text = ggplot2::element_text(face = "bold"),
      legend.key.size = grid::unit(0.7, "lines")
    )

  list(plot = p, data = agg)
}

## Correlation table (long form) among numeric columns of a wide table.
prof_correlation <- function(df, vars, method = "pearson") {
  vars <- Filter(function(v) v %in% names(df) && is.numeric(df[[v]]) &&
                   sum(is.finite(df[[v]])) > 2 &&
                   stats::sd(df[[v]], na.rm = TRUE) > 0, vars)
  if (length(vars) < 2) return(NULL)
  m <- stats::cor(df[, vars, drop = FALSE], use = "pairwise.complete.obs",
                  method = method)
  out <- expand.grid(var_x = rownames(m), var_y = colnames(m),
                     stringsAsFactors = FALSE)
  out$r <- mapply(function(a, b) m[a, b], out$var_x, out$var_y)
  out
}

## ---------------------------------------------------------------------------
## Cache-hierarchy point + 95% CI plot: stacked panels (one per cache level in
## `level_map` order), x = model, one coloured point per quantization with a 95%
## CI whisker. `level_map` is a named character vector col -> panel label; only
## levels with finite data are kept. Panels use a free y-axis. list(plot, data).
## ---------------------------------------------------------------------------
prof_cache_points_ci <- function(df, level_map, ylab, title, subtitle = NULL,
                                 caption = NULL) {
  level_cols <- names(level_map)[names(level_map) %in% names(df) &
    vapply(names(level_map), function(cc)
      any(is.finite(df[[cc]])), logical(1))]
  if (!length(level_cols)) return(NULL)

  df <- df[!is.na(df$model) & !is.na(df$quant), , drop = FALSE]
  if (!nrow(df)) return(NULL)

  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")
  present_models <- model_levels[model_levels %in% unique(as.character(df$model))]
  present_quants <- quant_levels[quant_levels %in% unique(as.character(df$quant))]
  if (!length(present_models) || !length(present_quants)) return(NULL)

  ## Mean + 95% CI per (level, model, quant).
  agg <- do.call(rbind, lapply(level_cols, function(cc) {
    sub <- df[is.finite(df[[cc]]), c("model", "quant", cc), drop = FALSE]
    if (!nrow(sub)) return(NULL)
    grp <- interaction(sub[c("model", "quant")], drop = TRUE, sep = "\r")
    do.call(rbind, lapply(split(sub, grp), function(p) {
      ci  <- mean_ci(p[[cc]])
      data.frame(
        level = level_map[[cc]],
        model = as.character(p$model[1]),
        quant = as.character(p$quant[1]),
        mean  = unname(ci["mean"]),
        lower = unname(ci["lower"]),
        upper = unname(ci["upper"]),
        n     = unname(ci["n"]),
        stringsAsFactors = FALSE)
    }))
  }))
  rownames(agg) <- NULL
  agg <- agg[is.finite(agg$mean), , drop = FALSE]
  if (!nrow(agg)) return(NULL)

  agg$level <- factor(agg$level, levels = unname(level_map[level_cols]))
  agg$model <- factor(agg$model, levels = present_models)
  agg$quant <- factor(agg$quant, levels = present_quants)

  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.30
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)),
                    present_quants)
  else stats::setNames(0, present_quants)
  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)])

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  ## Per-level marker glyphs (in level_map order): circle, triangle, square.
  present_level_labels <- levels(agg$level)
  level_shapes <- stats::setNames(
    c(21, 24, 22, 23, 25)[seq_along(present_level_labels)],
    present_level_labels)

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower, ymax = upper, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = level),
      colour = "grey25", size = 2.6, stroke = 0.5) +
    ggplot2::facet_wrap(ggplot2::vars(level), ncol = 1, scales = "free_y") +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(order = 1, override.aes = list(shape = 21, size = 3.2))) +
    ggplot2::scale_shape_manual(
      values = level_shapes, name = "Cache level",
      guide = ggplot2::guide_legend(order = 2, override.aes = list(fill = "grey40", size = 3.2))) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))) +
    ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10))) +
    ggplot2::labs(title = title, subtitle = subtitle, caption = caption,
                  x = "Model", y = ylab) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"),
      strip.text       = ggplot2::element_blank(),
      strip.background = ggplot2::element_blank(),
      axis.text.x  = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8)))

  list(plot = p, data = agg)
}

## ---------------------------------------------------------------------------
## GPU kernel runtime by generation in one unified panel, x = model, one
## coloured point per quantization with a 95% CI, marker shape = GPU generation.
## Response = total GPU kernel time per run (sum of every kernel's total_time_ns
## within the run) converted to seconds. Optional log10 y scale. GPU-only
## Nsight data. Returns list(plot, data) (NULL when empty).
## ---------------------------------------------------------------------------
prof_gpu_kernel_runtime_ci <- function(kern, ylab = "Total GPU kernel time [s]",
                                       title = NULL, subtitle = NULL,
                                       caption = NULL, log_y = FALSE) {
  req <- c("run_id", "gpu_arch", "model", "quant", "total_time_ns")
  if (length(setdiff(req, names(kern)))) return(NULL)
  d <- kern[is.finite(kern$total_time_ns) & !is.na(kern$gpu_arch) &
              !is.na(kern$model) & !is.na(kern$quant), , drop = FALSE]
  if (!nrow(d)) return(NULL)

  gpu_levels   <- c("V100", "A100", "H100")
  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")

  ## Per-run total kernel time (seconds).
  rgrp <- interaction(d[c("run_id", "gpu_arch", "model", "quant")],
                      drop = TRUE, sep = "\r")
  runtot <- do.call(rbind, lapply(split(d, rgrp), function(p) data.frame(
    gpu_arch = as.character(p$gpu_arch[1]),
    model    = as.character(p$model[1]),
    quant    = as.character(p$quant[1]),
    total_s  = sum(p$total_time_ns, na.rm = TRUE) / 1e9,
    stringsAsFactors = FALSE)))
  rownames(runtot) <- NULL

  present_gpu    <- gpu_levels[gpu_levels %in% unique(runtot$gpu_arch)]
  present_models <- model_levels[model_levels %in% unique(runtot$model)]
  present_quants <- quant_levels[quant_levels %in% unique(runtot$quant)]
  if (!length(present_gpu) || !length(present_models) || !length(present_quants))
    return(NULL)

  ## Mean + 95% CI across repetitions per (gpu_arch, model, quant).
  agg_grp <- interaction(runtot[c("gpu_arch", "model", "quant")],
                         drop = TRUE, sep = "\r")
  agg <- do.call(rbind, lapply(split(runtot, agg_grp), function(p) {
    ci <- mean_ci(p$total_s)
    data.frame(
      gpu_arch = p$gpu_arch[1], model = p$model[1], quant = p$quant[1],
      mean = unname(ci["mean"]), lower = unname(ci["lower"]),
      upper = unname(ci["upper"]), n = unname(ci["n"]),
      stringsAsFactors = FALSE)
  }))
  rownames(agg) <- NULL
  agg <- agg[is.finite(agg$mean), , drop = FALSE]
  if (!nrow(agg)) return(NULL)

  agg$gpu_arch <- factor(agg$gpu_arch, levels = present_gpu)
  agg$model    <- factor(agg$model,    levels = present_models)
  agg$quant    <- factor(agg$quant,    levels = present_quants)

  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.30
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)),
                    present_quants)
  else stats::setNames(0, present_quants)
  g_span    <- 0.09
  gpu_off   <- if (length(present_gpu) > 1L)
    stats::setNames(seq(-g_span, g_span, length.out = length(present_gpu)),
                    present_gpu)
  else stats::setNames(0, present_gpu)
  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)]) +
           unname(gpu_off[as.character(agg$gpu_arch)])

  if (isTRUE(log_y)) {
    pos_vals <- c(agg$mean[agg$mean > 0], agg$lower[agg$lower > 0], agg$upper[agg$upper > 0])
    floor_y  <- if (length(pos_vals)) min(pos_vals, na.rm = TRUE) / 10 else 1e-6
    agg$mean_plot  <- pmax(agg$mean, floor_y)
    agg$lower_plot <- pmax(agg$lower, floor_y)
    agg$upper_plot <- pmax(agg$upper, floor_y)
  } else {
    agg$mean_plot  <- agg$mean
    agg$lower_plot <- agg$lower
    agg$upper_plot <- agg$upper
  }

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  ## Per-generation marker glyphs: V100 circle, A100 triangle, H100 square.
  gpu_shapes <- c("V100" = 21, "A100" = 24, "H100" = 22)[present_gpu]

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean_plot)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower_plot, ymax = upper_plot, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = gpu_arch),
      colour = "grey25", size = 2.6, stroke = 0.5) +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(order = 1, override.aes = list(shape = 21, size = 3.2))) +
    ggplot2::scale_shape_manual(
      values = gpu_shapes, name = "GPU generation",
      guide = ggplot2::guide_legend(order = 2, override.aes = list(fill = "grey40", size = 3.2))) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))) +
    ggplot2::labs(title = title, subtitle = subtitle, caption = caption,
                  x = "Model", y = ylab) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"),
      axis.text.x  = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8)))

  if (isTRUE(log_y)) {
    p <- p + ggplot2::scale_y_log10(
      labels = scales::label_number(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10)))
  } else {
    p <- p + ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10)))
  }

  list(plot = p, data = agg)
}

## ---------------------------------------------------------------------------
## GPU transfer "bandwidth" = memcpy data volume / total kernel runtime of the
## run, per direction (HtoD / DtoH), in GB/s. Facet grid: rows = GPU generation
## (V100 / A100 / H100, identified by marker shape), columns = transfer
## direction. x = model, one coloured point per quantization with a 95% CI.
## Rows use a free y-axis. Needs the Nsight kernels table (for the runtime) and
## the gpu_mem table (for the transferred MB). Returns list(plot, data) or NULL.
## ---------------------------------------------------------------------------
prof_gpu_transfer_bandwidth_ci <- function(kern, gm,
                                           ylab = "Transfer volume / compute time [GB/s]",
                                           title = NULL, subtitle = NULL,
                                           caption = NULL, combine = FALSE,
                                           single_panel = FALSE,
                                           log_y = FALSE) {
  if (is.null(kern) || is.null(gm)) return(NULL)
  if (length(setdiff(c("run_id", "total_time_ns"), names(kern)))) return(NULL)
  if (length(setdiff(c("run_id", "gpu_arch", "model", "quant", "operation",
                       "total_mb"), names(gm)))) return(NULL)

  gpu_levels   <- c("V100", "A100", "H100")
  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")
  dir_levels   <- c("Host \u2192 Device (HtoD)", "Device \u2192 Host (DtoH)")

  ## Per-run total kernel time (seconds).
  kk <- kern[is.finite(kern$total_time_ns), , drop = FALSE]
  if (!nrow(kk)) return(NULL)
  ktime <- stats::aggregate(kk$total_time_ns, by = list(run_id = kk$run_id),
                            FUN = function(v) sum(v, na.rm = TRUE))
  names(ktime)[2] <- "kernel_time_s"
  ktime$kernel_time_s <- ktime$kernel_time_s / 1e9

  ## memcpy volumes per run x direction (MB).
  g <- gm[grepl("memcpy", gm$operation, ignore.case = TRUE) &
            is.finite(gm$total_mb), , drop = FALSE]
  if (!nrow(g)) return(NULL)
  g$direction <- ifelse(grepl("HtoD", g$operation), dir_levels[1],
                 ifelse(grepl("DtoH", g$operation), dir_levels[2], NA_character_))
  g <- g[!is.na(g$direction), , drop = FALSE]
  if (!nrow(g)) return(NULL)
  ## Combine both directions into a single series when requested.
  if (isTRUE(combine)) {
    dir_levels <- "HtoD + DtoH (combined)"
    g$direction <- dir_levels[1]
  }

  vol <- stats::aggregate(
    g$total_mb,
    by = list(run_id = g$run_id, gpu_arch = as.character(g$gpu_arch),
              model = as.character(g$model), quant = as.character(g$quant),
              direction = g$direction),
    FUN = function(v) sum(v, na.rm = TRUE))
  names(vol)[ncol(vol)] <- "total_mb"

  m <- merge(vol, ktime, by = "run_id")
  m <- m[is.finite(m$kernel_time_s) & m$kernel_time_s > 0, , drop = FALSE]
  if (!nrow(m)) return(NULL)
  m$bw_gbs <- (m$total_mb / 1000) / m$kernel_time_s

  present_gpu    <- gpu_levels[gpu_levels %in% unique(m$gpu_arch)]
  present_models <- model_levels[model_levels %in% unique(m$model)]
  present_quants <- quant_levels[quant_levels %in% unique(m$quant)]
  present_dirs   <- dir_levels[dir_levels %in% unique(m$direction)]
  if (!length(present_gpu) || !length(present_models) ||
      !length(present_quants) || !length(present_dirs)) return(NULL)

  ## Mean + 95% CI across repetitions per (gpu_arch, model, quant, direction).
  agg_grp <- interaction(m[c("gpu_arch", "model", "quant", "direction")],
                         drop = TRUE, sep = "\r")
  agg <- do.call(rbind, lapply(split(m, agg_grp), function(p) {
    ci <- mean_ci(p$bw_gbs)
    data.frame(
      gpu_arch = p$gpu_arch[1], model = p$model[1], quant = p$quant[1],
      direction = p$direction[1], mean = unname(ci["mean"]),
      lower = unname(ci["lower"]), upper = unname(ci["upper"]),
      n = unname(ci["n"]), stringsAsFactors = FALSE)
  }))
  rownames(agg) <- NULL
  agg <- agg[is.finite(agg$mean), , drop = FALSE]
  if (!nrow(agg)) return(NULL)

  agg$gpu_arch  <- factor(agg$gpu_arch,  levels = present_gpu)
  agg$model     <- factor(agg$model,     levels = present_models)
  agg$quant     <- factor(agg$quant,     levels = present_quants)
  agg$direction <- factor(agg$direction, levels = present_dirs)

  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.30
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)),
                    present_quants)
  else stats::setNames(0, present_quants)
  g_span    <- 0.09
  gpu_off   <- if (isTRUE(single_panel) && length(present_gpu) > 1L)
    stats::setNames(seq(-g_span, g_span, length.out = length(present_gpu)),
                    present_gpu)
  else stats::setNames(rep(0, length(present_gpu)), present_gpu)
  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)]) +
           unname(gpu_off[as.character(agg$gpu_arch)])

  if (isTRUE(log_y)) {
    pos_vals <- c(agg$mean[agg$mean > 0], agg$lower[agg$lower > 0], agg$upper[agg$upper > 0])
    floor_y  <- if (length(pos_vals)) min(pos_vals, na.rm = TRUE) / 10 else 1e-6
    agg$mean_plot  <- pmax(agg$mean, floor_y)
    agg$lower_plot <- pmax(agg$lower, floor_y)
    agg$upper_plot <- pmax(agg$upper, floor_y)
  } else {
    agg$mean_plot  <- agg$mean
    agg$lower_plot <- agg$lower
    agg$upper_plot <- agg$upper
  }

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  gpu_shapes <- c("V100" = 21, "A100" = 24, "H100" = 22)[present_gpu]

  ## One column per direction, or a single combined column (facet by GPU only),
  ## unless a unified single-panel view is explicitly requested.
  facet_layer <- if (isTRUE(single_panel)) {
    NULL
  } else if (length(present_dirs) > 1L) {
    ggplot2::facet_grid(rows = ggplot2::vars(gpu_arch),
                        cols = ggplot2::vars(direction), scales = "free_y")
  } else {
    ggplot2::facet_wrap(ggplot2::vars(gpu_arch), ncol = 1, scales = "free_y")
  }

  ## When directions are combined the top strips would only repeat the GPU name
  ## (already encoded by the marker shape), so hide them; keep the direction
  ## strips in the split (facet_grid) layout.
  multi_dir      <- length(present_dirs) > 1L
  strip_x_elem   <- if (multi_dir)
    ggplot2::element_text(face = "bold", size = 11) else ggplot2::element_blank()
  strip_bg_elem  <- if (multi_dir)
    ggplot2::element_rect(fill = "grey92", colour = NA) else ggplot2::element_blank()

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean_plot)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower_plot, ymax = upper_plot, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = gpu_arch),
      colour = "grey25", size = 2.6, stroke = 0.5) +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(order = 1, override.aes = list(shape = 21, size = 3.2))) +
    ggplot2::scale_shape_manual(
      values = gpu_shapes, name = "GPU generation",
      guide = ggplot2::guide_legend(order = 2, override.aes = list(fill = "grey40", size = 3.2))) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))) +
    ggplot2::labs(title = title, subtitle = subtitle, caption = caption,
                  x = "Model", y = ylab) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"),
      strip.text.x     = strip_x_elem,
      strip.text.y     = ggplot2::element_blank(),
      strip.background = strip_bg_elem,
      axis.text.x  = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8)))

  if (!is.null(facet_layer)) p <- p + facet_layer

  p <- p + if (isTRUE(log_y)) {
    decade_breaks <- function(lims) {
      lims <- lims[is.finite(lims) & lims > 0]
      if (!length(lims)) return(numeric(0))
      10^(floor(log10(min(lims))):ceiling(log10(max(lims))))
    }
    ggplot2::scale_y_log10(
      breaks = decade_breaks,
      minor_breaks = scales::minor_breaks_log(10),
      labels = scales::label_comma(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10))
    )
  } else {
    ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10))
    )
  }

  list(plot = p, data = agg)
}

