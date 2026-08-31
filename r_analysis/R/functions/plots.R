## functions/plots.R -----------------------------------------------------------
## Publication figure builders. Each function answers exactly ONE scientific
## question and returns list(plot, data) so the caller can persist the figure and
## its underlying data together. No diagnostic/distribution plots live here.
## ---------------------------------------------------------------------------

## ---------------------------------------------------------------------------
## Figure 1 -- Observed model effects on Total Energy, split by execution mode.
## Uses the raw experimental runs (NOT estimated marginal means): repetitions
## are collapsed to a configuration-level mean, then each model shows the
## individual configuration means (jittered), the model-level mean and its 95%
## confidence interval for CPU-only and GPU-only execution. No connecting lines
## and no in-plot statistics.
## ---------------------------------------------------------------------------
fig_main_effects <- function(
    metrics,
    response = "total_energy_j",
    response_label = "Total PSU energy (J)",
    config_cols,
    aggregate_fun = mean,
    seed = 20260717
) {

  # ---------------------------------------------------------------------------
  # 1. Validate inputs
  # ---------------------------------------------------------------------------

  required_cols <- c(
    response,
    "exec_mode",
    "model"
  )

  missing_cols <- setdiff(
    required_cols,
    names(metrics)
  )

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  if (missing(config_cols) || is.null(config_cols)) {
    stop(
      "config_cols must contain all columns that uniquely define ",
      "an experimental configuration."
    )
  }

  config_cols <- intersect(
    config_cols,
    names(metrics)
  )

  # Always preserve the variables required by this figure
  config_cols <- unique(
    c(
      "exec_mode",
      "model",
      config_cols
    )
  )

  if (!length(config_cols)) {
    stop("None of the supplied config_cols exist in metrics.")
  }

  # ---------------------------------------------------------------------------
  # 2. Filter valid CPU-only and GPU-only observations
  # ---------------------------------------------------------------------------

  d <- metrics[
    is.finite(metrics[[response]]) &
      !is.na(metrics$exec_mode) &
      !is.na(metrics$model) &
      as.character(metrics$exec_mode) %in%
        c("CPU-only", "GPU-only"),
    ,
    drop = FALSE
  ]

  if (!nrow(d)) {
    return(
      list(
        plot = NULL,
        data = NULL,
        observations = NULL,
        configuration_data = NULL
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 3. Aggregate repetitions at configuration level
  # ---------------------------------------------------------------------------

  configuration_data <- d |>
    dplyr::group_by(
      dplyr::across(
        dplyr::all_of(config_cols)
      )
    ) |>
    dplyr::summarise(
      value = aggregate_fun(
        .data[[response]],
        na.rm = TRUE
      ),
      repetitions = dplyr::n(),
      .groups = "drop"
    ) |>
    dplyr::filter(
      is.finite(value)
    )

  # ---------------------------------------------------------------------------
  # 4. Stable model and execution-mode ordering
  # ---------------------------------------------------------------------------

  preferred_model_order <- c(
    "Phi-3.5-mini-3.8B",
    "Mistral-7B",
    "Llama-3.1-8B",
    "Gemma-2-9B",
    "Mixtral-8x7B"
  )

  present_models <- unique(
    as.character(configuration_data$model)
  )

  present_models <- present_models[
    !is.na(present_models)
  ]

  model_order <- c(
    preferred_model_order[
      preferred_model_order %in% present_models
    ],
    setdiff(
      present_models,
      preferred_model_order
    )
  )

  configuration_data$model <- factor(
    configuration_data$model,
    levels = model_order
  )

  configuration_data$exec_mode <- factor(
    configuration_data$exec_mode,
    levels = c(
      "CPU-only",
      "GPU-only"
    )
  )

  # ---------------------------------------------------------------------------
  # 5. Controlled horizontal positions
  # ---------------------------------------------------------------------------

  model_positions <- stats::setNames(
    seq_along(model_order),
    model_order
  )

  mode_offsets <- c(
    "CPU-only" = -0.11,
    "GPU-only" =  0.11
  )

  configuration_data <- configuration_data |>
    dplyr::mutate(
      model_center = unname(
        model_positions[as.character(model)]
      ),
      mode_offset = unname(
        mode_offsets[as.character(exec_mode)]
      ),
      x_position = model_center + mode_offset
    )

  # ---------------------------------------------------------------------------
  # 6. Configuration-level observations with reproducible jitter
  # ---------------------------------------------------------------------------

  set.seed(seed)

  observations <- configuration_data |>
    dplyr::filter(
      !is.na(model),
      !is.na(exec_mode),
      is.finite(value)
    ) |>
    dplyr::mutate(
      x_jitter = x_position +
        stats::runif(
          dplyr::n(),
          min = -0.03,
          max = 0.03
        )
    ) |>
    dplyr::select(
      model,
      exec_mode,
      value,
      repetitions,
      model_center,
      x_position,
      x_jitter
    )

  # ---------------------------------------------------------------------------
  # 7. Model-level means and 95% confidence intervals
  # ---------------------------------------------------------------------------

  summary_data <- observations |>
    dplyr::group_by(
      model,
      exec_mode,
      model_center,
      x_position
    ) |>
    dplyr::summarise(
      n = dplyr::n(),

      mean = mean(
        value,
        na.rm = TRUE
      ),

      sd = stats::sd(
        value,
        na.rm = TRUE
      ),

      se = dplyr::if_else(
        n > 1L,
        sd / sqrt(n),
        NA_real_
      ),

      t_critical = dplyr::if_else(
        n > 1L,
        stats::qt(
          0.975,
          df = pmax(n - 1L, 1L)
        ),
        NA_real_
      ),

      lower = mean - t_critical * se,
      upper = mean + t_critical * se,

      .groups = "drop"
    )

  # ---------------------------------------------------------------------------
  # 8. Visual definitions
  # ---------------------------------------------------------------------------

  mode_colors <- c(
    "CPU-only" = "#4C78A8",
    "GPU-only" = "#F58518"
  )

  legend_data <- data.frame(
    exec_mode = factor(
      c("CPU-only", "GPU-only"),
      levels = c("CPU-only", "GPU-only")
    ),
    x = NA_real_,
    y = NA_real_
  )

  # ---------------------------------------------------------------------------
  # 9. Plot
  # ---------------------------------------------------------------------------

  p <- ggplot2::ggplot() +

    # Small configuration-level means
    ggplot2::geom_point(
      data = observations,
      mapping = ggplot2::aes(
        x = x_jitter,
        y = value,
        colour = exec_mode
      ),
      shape = 16,
      size = 1.45,
      alpha = 0.24,
      stroke = 0,
      show.legend = FALSE,
      na.rm = TRUE
    ) +

    # Colored 95% confidence intervals
    ggplot2::geom_errorbar(
      data = summary_data,
      mapping = ggplot2::aes(
        x = x_position,
        ymin = lower,
        ymax = upper,
        colour = exec_mode
      ),
      width = 0.075,
      linewidth = 0.90,
      lineend = "round",
      na.rm = TRUE
    ) +

    # Colored model-level means
    ggplot2::geom_point(
      data = summary_data,
      mapping = ggplot2::aes(
        x = x_position,
        y = mean,
        fill = exec_mode,
        colour = exec_mode
      ),
      shape = 21,
      size = 3.7,
      stroke = 0.8,
      na.rm = TRUE
    ) +

    # Invisible layer used to construct the legend
    ggplot2::geom_point(
      data = legend_data,
      mapping = ggplot2::aes(
        x = x,
        y = y,
        colour = exec_mode
      ),
      size = 3.2,
      show.legend = TRUE,
      na.rm = TRUE
    ) +

    # -------------------------------------------------------------------------
    # Scales
    # -------------------------------------------------------------------------

    ggplot2::scale_colour_manual(
      values = mode_colors,
      breaks = c(
        "CPU-only",
        "GPU-only"
      ),
      name = "Execution mode"
    ) +

    ggplot2::scale_fill_manual(
      values = mode_colors,
      breaks = c(
        "CPU-only",
        "GPU-only"
      ),
      guide = "none"
    ) +

    ggplot2::scale_x_continuous(
      breaks = seq_along(model_order),
      labels = model_order,
      limits = c(
        0.55,
        length(model_order) + 0.45
      ),
      expand = ggplot2::expansion(
        mult = c(0, 0)
      )
    ) +

    ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(
        mult = c(0.015, 0.045)
      )
    ) +

    # -------------------------------------------------------------------------
    # Labels
    # -------------------------------------------------------------------------

    ggplot2::labs(
      title = "Model Effects on Total PSU Energy by Execution Mode",
      subtitle = paste(
        "Configuration-level means across repetitions;",
        "error bars indicate 95% confidence intervals."
      ),
      x = NULL,
      y = response_label,
      caption = paste(
        "Small points show configuration-level means;",
        "large markers and error bars show model-level means and 95% CIs."
      )
    ) +

    theme_pub(
      base_size = 13
    ) +

    # -------------------------------------------------------------------------
    # Publication styling
    # -------------------------------------------------------------------------

    ggplot2::theme(
      plot.title = ggplot2::element_text(
        face = "bold",
        size = 17,
        hjust = 0.5,
        margin = ggplot2::margin(
          b = 3
        )
      ),

      plot.subtitle = ggplot2::element_text(
        colour = "grey35",
        size = 11,
        hjust = 0.5,
        margin = ggplot2::margin(
          b = 8
        )
      ),

      plot.caption = ggplot2::element_text(
        colour = "grey40",
        size = 8.5,
        hjust = 0.5,
        lineheight = 1.1,
        margin = ggplot2::margin(
          t = 8
        )
      ),

      axis.title.y = ggplot2::element_text(
        size = 11.5,
        margin = ggplot2::margin(
          r = 7
        )
      ),

      axis.title.x = ggplot2::element_blank(),

      axis.text.y = ggplot2::element_text(
        size = 9.5,
        colour = "grey25"
      ),

      axis.text.x = ggplot2::element_text(
        size = 9.5,
        colour = "grey25",
        angle = 0,
        hjust = 0.5,
        vjust = 0.5,
        margin = ggplot2::margin(
          t = 6
        )
      ),

      panel.border = ggplot2::element_rect(
        colour = "grey55",
        fill = NA,
        linewidth = 0.4
      ),

      panel.grid.major.y = ggplot2::element_line(
        colour = "grey88",
        linewidth = 0.4
      ),

      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor = ggplot2::element_blank(),

      # Legend on the right, matching Figure 1
      legend.position = "right",
      legend.direction = "vertical",
      legend.justification = "top",

      legend.background = ggplot2::element_blank(),
      legend.title = ggplot2::element_text(
        face = "bold",
        size = 11.5
      ),

      legend.text = ggplot2::element_text(
        size = 10
      ),

      legend.key.width = grid::unit(
        1.2,
        "lines"
      ),

      legend.key.height = grid::unit(
        0.9,
        "lines"
      ),

      legend.spacing.x = grid::unit(
        0.25,
        "cm"
      ),

      plot.margin = ggplot2::margin(
        t = 8,
        r = 8,
        b = 6,
        l = 8
      )
    ) +

    ggplot2::guides(
      colour = ggplot2::guide_legend(
        override.aes = list(
          shape = 16,
          size = 3.3,
          alpha = 1
        )
      )
    )

  # ---------------------------------------------------------------------------
  # 10. Return plot and supporting data
  # ---------------------------------------------------------------------------

  list(
    plot = p,
    data = summary_data,
    observations = observations,
    configuration_data = configuration_data
  )
}

## ---------------------------------------------------------------------------
## Figure 3 -- Pareto front: Energy vs Performance. Scatter of Total Energy
## against Throughput (tokens/sec); colour = Model, shape = Quantization. The
## Pareto front (MAXIMISE throughput AND MINIMISE energy) is overlaid: the set of
## non-dominated configurations forming the lower-right efficiency envelope.
## ---------------------------------------------------------------------------

# ## Frontier for "minimise x AND minimise y" (lower-left envelope).
# pareto_frontier <- function(df, x = "exec_time_s", y = "total_energy_j") {
#   d <- df[is.finite(df[[x]]) & is.finite(df[[y]]), , drop = FALSE]
#   if (!nrow(d)) return(d[0, , drop = FALSE])
#   d <- d[order(d[[x]], d[[y]]), , drop = FALSE]
#   keep <- logical(nrow(d)); best_y <- Inf
#   for (i in seq_len(nrow(d))) {
#     if (d[[y]][i] < best_y) { keep[i] <- TRUE; best_y <- d[[y]][i] }
#   }
#   d[keep, , drop = FALSE]
# }

# ## Frontier for "maximise x AND minimise y" (lower-right envelope). A point is
# ## non-dominated iff no other point has both higher x and lower y.
# pareto_frontier_maxx <- function(df, x = "tokens_per_sec", y = "total_energy_j") {
#   d <- df[is.finite(df[[x]]) & is.finite(df[[y]]), , drop = FALSE]
#   if (!nrow(d)) return(d[0, , drop = FALSE])
#   ## Sort by throughput descending; keep a point when its energy is the lowest
#   ## seen so far among all points with >= throughput.
#   d <- d[order(-d[[x]], d[[y]]), , drop = FALSE]
#   keep <- logical(nrow(d)); best_y <- Inf
#   for (i in seq_len(nrow(d))) {
#     if (d[[y]][i] < best_y) { keep[i] <- TRUE; best_y <- d[[y]][i] }
#   }
#   d[keep, , drop = FALSE]
# }

# fig_energy_performance <- function(df) {

#   # ---------------------------------------------------------------------------
#   # 1. Validate and prepare data
#   # ---------------------------------------------------------------------------

#   required_cols <- c(
#     "tokens_per_sec",
#     "total_energy_j",
#     "model",
#     "quant"
#   )

#   missing_cols <- setdiff(required_cols, names(df))

#   if (length(missing_cols) > 0L) {
#     stop(
#       "Missing required columns: ",
#       paste(missing_cols, collapse = ", ")
#     )
#   }

#   d <- df[
#     is.finite(df$tokens_per_sec) &
#       is.finite(df$total_energy_j),
#     ,
#     drop = FALSE
#   ]

#   has_mode <- "exec_mode" %in% names(d)

#   if (has_mode) {
#     d <- d[
#       !is.na(d$exec_mode) &
#         d$exec_mode %in% c("CPU-only", "GPU-only"),
#       ,
#       drop = FALSE
#     ]

#     d$exec_mode <- factor(
#       d$exec_mode,
#       levels = c("CPU-only", "GPU-only")
#     )
#   }

#   if (!nrow(d)) {
#     return(
#       list(
#         plot = NULL,
#         data = NULL,
#         frontier = NULL
#       )
#     )
#   }

#   # ---------------------------------------------------------------------------
#   # 2. Stable display order
#   # ---------------------------------------------------------------------------

#   model_order <- c(
#     "Phi-3.5-mini-3.8B",
#     "Mistral-7B",
#     "Llama-3.1-8B",
#     "Gemma-2-9B",
#     "Mixtral-8x7B"
#   )

#   quant_order <- c(
#     "Q2_K",
#     "Q4_K_M",
#     "Q5_K_M",
#     "Q6_K",
#     "Q8_0",
#     "FP16"
#   )

#   present_models <- model_order[
#     model_order %in% unique(as.character(d$model))
#   ]

#   extra_models <- setdiff(
#     unique(as.character(d$model)),
#     model_order
#   )

#   present_quants <- quant_order[
#     quant_order %in% unique(as.character(d$quant))
#   ]

#   extra_quants <- setdiff(
#     unique(as.character(d$quant)),
#     quant_order
#   )

#   d$model <- factor(
#     d$model,
#     levels = c(present_models, extra_models)
#   )

#   d$quant <- factor(
#     d$quant,
#     levels = c(present_quants, extra_quants)
#   )

#   # ---------------------------------------------------------------------------
#   # 3. Compute Pareto frontier independently by execution mode
#   # ---------------------------------------------------------------------------

#   modes <- if (has_mode) {
#     levels(droplevels(d$exec_mode))
#   } else {
#     "All"
#   }

#   front_list <- lapply(modes, function(mode_name) {

#     dm <- if (has_mode) {
#       d[d$exec_mode == mode_name, , drop = FALSE]
#     } else {
#       d
#     }

#     fm <- pareto_frontier_maxx(
#       dm,
#       x = "tokens_per_sec",
#       y = "total_energy_j"
#     )

#     if (!nrow(fm)) {
#       return(NULL)
#     }

#     fm <- fm[
#       order(fm$tokens_per_sec, fm$total_energy_j),
#       ,
#       drop = FALSE
#     ]

#     if (has_mode) {
#       fm$exec_mode <- factor(
#         mode_name,
#         levels = c("CPU-only", "GPU-only")
#       )
#     }

#     fm
#   })

#   front_list <- Filter(Negate(is.null), front_list)

#   front <- if (length(front_list) > 0L) {
#     do.call(rbind, front_list)
#   } else {
#     d[0, , drop = FALSE]
#   }

#   # Draw a line only in panels with at least two Pareto points
#   if (has_mode && nrow(front) > 0L) {

#     front_counts <- table(front$exec_mode)

#     line_modes <- names(
#       front_counts[front_counts >= 2L]
#     )

#     front_line <- front[
#       as.character(front$exec_mode) %in% line_modes,
#       ,
#       drop = FALSE
#     ]

#   } else if (nrow(front) >= 2L) {

#     front_line <- front

#   } else {

#     front_line <- front[0, , drop = FALSE]
#   }

#   # ---------------------------------------------------------------------------
#   # 4. Visual mappings
#   # ---------------------------------------------------------------------------

#   model_cols <- c(
#     "Phi-3.5-mini-3.8B" = "#1F77B4",
#     "Mistral-7B"        = "#FF7F0E",
#     "Llama-3.1-8B"      = "#2CA02C",
#     "Gemma-2-9B"        = "#D62728",
#     "Mixtral-8x7B"      = "#9467BD"
#   )

#   unknown_models <- setdiff(
#     levels(d$model),
#     names(model_cols)
#   )

#   if (length(unknown_models) > 0L) {
#     fallback_cols <- scales::hue_pal()(
#       length(unknown_models)
#     )

#     names(fallback_cols) <- unknown_models

#     model_cols <- c(
#       model_cols,
#       fallback_cols
#     )
#   }

#   quant_shapes <- c(
#     "Q2_K"   = 16,
#     "Q4_K_M" = 17,
#     "Q5_K_M" = 15,
#     "Q6_K"   = 18,
#     "Q8_0"   = 8,
#     "FP16"   = 7
#   )

#   unknown_quants <- setdiff(
#     levels(d$quant),
#     names(quant_shapes)
#   )

#   if (length(unknown_quants) > 0L) {
#     fallback_pool <- c(
#       3, 4, 9, 10, 12, 13, 14
#     )

#     fallback_shapes <- fallback_pool[
#       seq_along(unknown_quants)
#     ]

#     names(fallback_shapes) <- unknown_quants

#     quant_shapes <- c(
#       quant_shapes,
#       fallback_shapes
#     )
#   }

#   pareto_label <- "Pareto front"

#   # ---------------------------------------------------------------------------
#   # 5. Build plot
#   # ---------------------------------------------------------------------------

#   p <- ggplot2::ggplot(
#     d,
#     ggplot2::aes(
#       x = tokens_per_sec,
#       y = total_energy_j
#     )
#   ) +

#     # All evaluated configurations
#     ggplot2::geom_point(
#       ggplot2::aes(
#         colour = model,
#         shape = quant
#       ),
#       size = 2.25,
#       alpha = 0.78,
#       stroke = 0.4
#     ) +

#     # Pareto line, only when multiple non-dominated points exist
#     ggplot2::geom_line(
#       data = front_line,
#       mapping = ggplot2::aes(
#         x = tokens_per_sec,
#         y = total_energy_j,
#         linetype = pareto_label,
#         group = if (has_mode) exec_mode else 1
#       ),
#       inherit.aes = FALSE,
#       colour = "black",
#       linewidth = 1.05,
#       lineend = "round"
#     ) +

#     # Pareto points
#     ggplot2::geom_point(
#       data = front,
#       mapping = ggplot2::aes(
#         x = tokens_per_sec,
#         y = total_energy_j
#       ),
#       inherit.aes = FALSE,
#       colour = "black",
#       fill = "black",
#       shape = 21,
#       size = 3.2,
#       stroke = 0.7
#     ) +

#     # -------------------------------------------------------------------------
#     # Scales
#     # -------------------------------------------------------------------------

#     ggplot2::scale_colour_manual(
#       values = model_cols,
#       breaks = levels(d$model),
#       drop = TRUE,
#       name = "Model"
#     ) +

#     ggplot2::scale_shape_manual(
#       values = quant_shapes,
#       breaks = levels(d$quant),
#       drop = TRUE,
#       name = "Quantization"
#     ) +

#     ggplot2::scale_linetype_manual(
#       values = stats::setNames(
#         "solid",
#         pareto_label
#       ),
#       name = NULL
#     ) +

#     # Linear scales; each facet gets its own range
#     ggplot2::scale_x_continuous(
#       labels = scales::label_number(
#         accuracy = 0.1,
#         big.mark = ",",
#         trim = TRUE
#       ),
#       expand = ggplot2::expansion(
#         mult = c(0.03, 0.05)
#       )
#     ) +

#     ggplot2::scale_y_continuous(
#       labels = scales::label_comma(),
#       expand = ggplot2::expansion(
#         mult = c(0.02, 0.06)
#       )
#     ) +

#     # -------------------------------------------------------------------------
#     # Labels
#     # -------------------------------------------------------------------------

#     ggplot2::labs(
#       title = "Energy vs. Performance (Pareto Front)",
#       subtitle = paste(
#         "Each point represents a configuration.",
#         "Colors indicate models; shapes indicate quantization."
#       ),
#       x = "Throughput (tokens/s)",
#       y = "Total PSU energy (J)",
#       caption = paste(
#         "Black markers identify non-dominated configurations.",
#         "Lines connect multiple Pareto-optimal points as a visual guide.",
#         "CPU-only and GPU-only panels use independently scaled axes."
#       )
#     ) +

#     # -------------------------------------------------------------------------
#     # Base theme
#     # -------------------------------------------------------------------------

#     theme_pub() +

#     # -------------------------------------------------------------------------
#     # Legends
#     # -------------------------------------------------------------------------

#     ggplot2::guides(
#       colour = ggplot2::guide_legend(
#         order = 1,
#         override.aes = list(
#           shape = 16,
#           size = 3.2,
#           alpha = 1
#         )
#       ),
#       shape = ggplot2::guide_legend(
#         order = 2,
#         override.aes = list(
#           colour = "grey25",
#           size = 3.0,
#           alpha = 1
#         )
#       ),
#       linetype = ggplot2::guide_legend(
#         order = 3,
#         override.aes = list(
#           colour = "black",
#           linewidth = 1.05
#         )
#       )
#     ) +

#     # -------------------------------------------------------------------------
#     # Publication styling
#     # -------------------------------------------------------------------------

#     ggplot2::theme(
#       plot.title = ggplot2::element_text(
#         face = "bold",
#         size = 18,
#         hjust = 0.5,
#         margin = ggplot2::margin(
#           b = 4
#         )
#       ),

#       plot.subtitle = ggplot2::element_text(
#         size = 12,
#         colour = "grey35",
#         hjust = 0.5,
#         margin = ggplot2::margin(
#           b = 11
#         )
#       ),

#       plot.caption = ggplot2::element_text(
#         size = 9,
#         colour = "grey35",
#         hjust = 0,
#         lineheight = 1.15,
#         margin = ggplot2::margin(
#           t = 10
#         )
#       ),

#       strip.background = ggplot2::element_blank(),

#       strip.text = ggplot2::element_text(
#         face = "bold",
#         size = 13.5,
#         colour = "grey10",
#         margin = ggplot2::margin(
#           t = 2,
#           b = 6
#         )
#       ),

#       axis.title = ggplot2::element_text(
#         size = 12
#       ),

#       axis.text = ggplot2::element_text(
#         size = 10,
#         colour = "grey25"
#       ),

#       panel.border = ggplot2::element_rect(
#         colour = "grey35",
#         fill = NA,
#         linewidth = 0.5
#       ),

#       panel.grid.major = ggplot2::element_line(
#         colour = "grey87",
#         linewidth = 0.45
#       ),

#       panel.grid.minor = ggplot2::element_blank(),

#       panel.spacing = grid::unit(
#         1.7,
#         "lines"
#       ),

#       legend.position = "right",
#       legend.justification = "top",
#       legend.box = "vertical",
#       legend.box.just = "left",

#       legend.box.spacing = grid::unit(
#         0.25,
#         "cm"
#       ),

#       legend.title = ggplot2::element_text(
#         face = "bold",
#         size = 11.5
#       ),

#       legend.text = ggplot2::element_text(
#         size = 10
#       ),

#       legend.key.height = grid::unit(
#         0.95,
#         "lines"
#       ),

#       legend.key.width = grid::unit(
#         1.15,
#         "lines"
#       ),

#       plot.margin = ggplot2::margin(
#         t = 10,
#         r = 8,
#         b = 8,
#         l = 8
#       )
#     )

#   # ---------------------------------------------------------------------------
#   # 6. CPU/GPU panels
#   # ---------------------------------------------------------------------------

#   if (has_mode) {

#     panel_labels <- c(
#       "CPU-only" = "(A) CPU-only",
#       "GPU-only" = "(B) GPU-only"
#     )

#     p <- p +
#       ggplot2::facet_wrap(
#         ~ exec_mode,
#         nrow = 1,
#         scales = "free",
#         labeller = ggplot2::as_labeller(
#           panel_labels
#         )
#       )
#   }

#   # ---------------------------------------------------------------------------
#   # 7. Return figure and data
#   # ---------------------------------------------------------------------------

#   list(
#     plot = p,
#     data = d,
#     frontier = front
#   )
# }

pareto_frontier <- function(
    df,
    x = "exec_time_s",
    y = "total_energy_j"
) {

  required_cols <- c(x, y)
  missing_cols <- setdiff(required_cols, names(df))

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  d <- df[
    is.finite(df[[x]]) &
      is.finite(df[[y]]),
    ,
    drop = FALSE
  ]

  if (!nrow(d)) {
    return(d[0, , drop = FALSE])
  }

  ## Remove exact duplicate objective pairs. Keep the first configuration
  ## representing each identical energy-performance result.
  d <- d[
    !duplicated(
      d[c(x, y)]
    ),
    ,
    drop = FALSE
  ]

  ## Lower x first; for tied x, lower y first.
  d <- d[
    order(
      d[[x]],
      d[[y]]
    ),
    ,
    drop = FALSE
  ]

  keep <- logical(nrow(d))
  best_y <- Inf

  for (i in seq_len(nrow(d))) {

    ## Strict comparison is intentional. If a later point has the same energy
    ## but a larger x, it is dominated by the earlier point.
    if (d[[y]][i] < best_y) {
      keep[i] <- TRUE
      best_y <- d[[y]][i]
    }
  }

  frontier <- d[
    keep,
    ,
    drop = FALSE
  ]

  frontier <- frontier[
    order(
      frontier[[x]],
      frontier[[y]]
    ),
    ,
    drop = FALSE
  ]

  rownames(frontier) <- NULL

  frontier
}


## Frontier for "maximise x AND minimise y" (lower-right envelope).
##
## A point is non-dominated when no other point has:
##   x >= candidate_x
##   y <= candidate_y
## with at least one strict inequality.
pareto_frontier_maxx <- function(
    df,
    x = "tokens_per_sec",
    y = "total_energy_j"
) {

  required_cols <- c(x, y)
  missing_cols <- setdiff(required_cols, names(df))

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  d <- df[
    is.finite(df[[x]]) &
      is.finite(df[[y]]),
    ,
    drop = FALSE
  ]

  if (!nrow(d)) {
    return(d[0, , drop = FALSE])
  }

  ## Remove exact duplicate objective pairs. Keep the first configuration
  ## representing each identical energy-performance result.
  d <- d[
    !duplicated(
      d[c(x, y)]
    ),
    ,
    drop = FALSE
  ]

  ## Higher throughput first; for tied throughput, lower energy first.
  d <- d[
    order(
      -d[[x]],
      d[[y]]
    ),
    ,
    drop = FALSE
  ]

  keep <- logical(nrow(d))
  best_y <- Inf

  for (i in seq_len(nrow(d))) {

    ## Strict comparison is intentional. If a later point has the same energy
    ## but lower throughput, it is dominated by the earlier point.
    if (d[[y]][i] < best_y) {
      keep[i] <- TRUE
      best_y <- d[[y]][i]
    }
  }

  frontier <- d[
    keep,
    ,
    drop = FALSE
  ]

  ## Return the points from lower to higher throughput so geom_line() draws
  ## the frontier naturally from left to right.
  frontier <- frontier[
    order(
      frontier[[x]],
      frontier[[y]]
    ),
    ,
    drop = FALSE
  ]

  rownames(frontier) <- NULL

  frontier
}


## =============================================================================
## Energy-performance Pareto figure
## =============================================================================

fig_energy_performance <- function(
    df,
    seed = 20260717
) {

  # ---------------------------------------------------------------------------
  # 1. Validate required columns
  # ---------------------------------------------------------------------------

  required_cols <- c(
    "tokens_per_sec",
    "total_energy_j",
    "model",
    "quant"
  )

  missing_cols <- setdiff(
    required_cols,
    names(df)
  )

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  # ---------------------------------------------------------------------------
  # 2. Keep valid observations
  # ---------------------------------------------------------------------------

  raw_data <- df[
    is.finite(df$tokens_per_sec) &
      is.finite(df$total_energy_j) &
      !is.na(df$model) &
      !is.na(df$quant),
    ,
    drop = FALSE
  ]

  has_mode <- "exec_mode" %in% names(raw_data)

  if (has_mode) {

    raw_data <- raw_data[
      !is.na(raw_data$exec_mode) &
        as.character(raw_data$exec_mode) %in%
          c("CPU-only", "GPU-only"),
      ,
      drop = FALSE
    ]

    raw_data$exec_mode <- factor(
      raw_data$exec_mode,
      levels = c(
        "CPU-only",
        "GPU-only"
      )
    )
  }

  if (!nrow(raw_data)) {
    return(
      list(
        plot = NULL,
        data = NULL,
        raw_data = NULL,
        configuration_data = NULL,
        frontier = NULL,
        uncertainty = NULL
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 3. Aggregate repetitions at configuration level
  #
  # One plotted point represents one design configuration, not one run.
  # Repetitions are used to estimate the mean and 95% confidence intervals.
  # ---------------------------------------------------------------------------

  candidate_config_keys <- c(
    "exec_mode",
    "node",
    "gpu_arch",
    "cpu_arch",
    "model",
    "quant",
    "threads",
    "gpu_layers",
    "batch_size",
    "context_size",
    "backend"
  )

  config_keys <- candidate_config_keys[
    candidate_config_keys %in% names(raw_data)
  ]

  ## These columns must always identify separate configurations when present.
  config_keys <- unique(
    c(
      intersect(
        c(
          "exec_mode",
          "gpu_arch",
          "cpu_arch",
          "model",
          "quant"
        ),
        names(raw_data)
      ),
      config_keys
    )
  )

  if (!all(c("model", "quant") %in% config_keys)) {
    stop(
      "The configuration keys must include model and quant."
    )
  }

  config_data <- raw_data |>
    dplyr::group_by(
      dplyr::across(
        dplyr::all_of(config_keys)
      )
    ) |>
    dplyr::summarise(
      repetitions = dplyr::n(),

      tokens_per_sec = mean(
        .data$tokens_per_sec,
        na.rm = TRUE
      ),

      tokens_per_sec_sd = dplyr::if_else(
        repetitions > 1L,
        stats::sd(
          .data$tokens_per_sec,
          na.rm = TRUE
        ),
        NA_real_
      ),

      total_energy_j = mean(
        .data$total_energy_j,
        na.rm = TRUE
      ),

      total_energy_j_sd = dplyr::if_else(
        repetitions > 1L,
        stats::sd(
          .data$total_energy_j,
          na.rm = TRUE
        ),
        NA_real_
      ),

      .groups = "drop"
    ) |>
    dplyr::mutate(
      tokens_per_sec_se = dplyr::if_else(
        repetitions > 1L,
        tokens_per_sec_sd / sqrt(repetitions),
        NA_real_
      ),

      total_energy_j_se = dplyr::if_else(
        repetitions > 1L,
        total_energy_j_sd / sqrt(repetitions),
        NA_real_
      ),

      t_critical = dplyr::if_else(
        repetitions > 1L,
        stats::qt(
          0.975,
          df = pmax(repetitions - 1L, 1L)
        ),
        NA_real_
      ),

      tokens_per_sec_margin = t_critical * tokens_per_sec_se,
      total_energy_j_margin = t_critical * total_energy_j_se,

      tokens_per_sec_lower =
        tokens_per_sec - tokens_per_sec_margin,

      tokens_per_sec_upper =
        tokens_per_sec + tokens_per_sec_margin,

      total_energy_j_lower =
        total_energy_j - total_energy_j_margin,

      total_energy_j_upper =
        total_energy_j + total_energy_j_margin
    ) |>
    dplyr::filter(
      is.finite(tokens_per_sec),
      is.finite(total_energy_j)
    )

  if (!nrow(config_data)) {
    return(
      list(
        plot = NULL,
        data = NULL,
        raw_data = raw_data,
        configuration_data = NULL,
        frontier = NULL,
        uncertainty = NULL
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 4. Stable display order
  # ---------------------------------------------------------------------------

  model_order <- c(
    "Phi-3.5-mini-3.8B",
    "Mistral-7B",
    "Llama-3.1-8B",
    "Gemma-2-9B",
    "Mixtral-8x7B"
  )

  quant_order <- c(
    "Q2_K",
    "Q4_K_M",
    "Q5_K_M",
    "Q6_K",
    "Q8_0",
    "FP16"
  )

  present_models <- model_order[
    model_order %in%
      unique(as.character(config_data$model))
  ]

  extra_models <- setdiff(
    unique(as.character(config_data$model)),
    model_order
  )

  present_quants <- quant_order[
    quant_order %in%
      unique(as.character(config_data$quant))
  ]

  extra_quants <- setdiff(
    unique(as.character(config_data$quant)),
    quant_order
  )

  model_levels <- c(
    present_models,
    extra_models
  )

  quant_levels <- c(
    present_quants,
    extra_quants
  )

  config_data$model <- factor(
    config_data$model,
    levels = model_levels
  )

  config_data$quant <- factor(
    config_data$quant,
    levels = quant_levels
  )

  if (has_mode) {
    config_data$exec_mode <- factor(
      config_data$exec_mode,
      levels = c(
        "CPU-only",
        "GPU-only"
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 5. Compute Pareto frontier independently by execution mode
  # ---------------------------------------------------------------------------

  modes <- if (has_mode) {
    levels(
      droplevels(
        config_data$exec_mode
      )
    )
  } else {
    "All"
  }

  front_list <- lapply(
    modes,
    function(mode_name) {

      mode_data <- if (has_mode) {
        config_data[
          config_data$exec_mode == mode_name,
          ,
          drop = FALSE
        ]
      } else {
        config_data
      }

      mode_front <- pareto_frontier_maxx(
        mode_data,
        x = "tokens_per_sec",
        y = "total_energy_j"
      )

      if (!nrow(mode_front)) {
        return(NULL)
      }

      if (has_mode) {
        mode_front$exec_mode <- factor(
          mode_name,
          levels = c(
            "CPU-only",
            "GPU-only"
          )
        )
      }

      mode_front
    }
  )

  front_list <- Filter(
    Negate(is.null),
    front_list
  )

  front <- if (length(front_list) > 0L) {
    dplyr::bind_rows(front_list)
  } else {
    config_data[0, , drop = FALSE]
  }

  # ---------------------------------------------------------------------------
  # 6. Validate that every selected point is truly non-dominated
  # ---------------------------------------------------------------------------

  is_dominated <- function(
      candidate,
      reference_data,
      x = "tokens_per_sec",
      y = "total_energy_j"
  ) {

    any(
      reference_data[[x]] >= candidate[[x]] &
        reference_data[[y]] <= candidate[[y]] &
        (
          reference_data[[x]] > candidate[[x]] |
            reference_data[[y]] < candidate[[y]]
        )
    )
  }

  if (nrow(front) > 0L) {

    validation_results <- lapply(
      modes,
      function(mode_name) {

        reference_data <- if (has_mode) {
          config_data[
            config_data$exec_mode == mode_name,
            ,
            drop = FALSE
          ]
        } else {
          config_data
        }

        selected_front <- if (has_mode) {
          front[
            front$exec_mode == mode_name,
            ,
            drop = FALSE
          ]
        } else {
          front
        }

        if (!nrow(selected_front)) {
          return(logical(0))
        }

        vapply(
          seq_len(nrow(selected_front)),
          function(i) {
            is_dominated(
              candidate = selected_front[i, , drop = FALSE],
              reference_data = reference_data
            )
          },
          logical(1)
        )
      }
    )

    validation_results <- unlist(
      validation_results,
      use.names = FALSE
    )

    if (any(validation_results)) {
      stop(
        "Internal Pareto validation failed: ",
        "at least one selected point is dominated."
      )
    }
  }

  # ---------------------------------------------------------------------------
  # 7. Draw a line only when a panel has at least two Pareto points
  # ---------------------------------------------------------------------------

  if (has_mode && nrow(front) > 0L) {

    front_counts <- table(
      front$exec_mode
    )

    line_modes <- names(
      front_counts[
        front_counts >= 2L
      ]
    )

    front_line <- front[
      as.character(front$exec_mode) %in% line_modes,
      ,
      drop = FALSE
    ]

  } else if (nrow(front) >= 2L) {

    front_line <- front

  } else {

    front_line <- front[0, , drop = FALSE]
  }

  # ---------------------------------------------------------------------------
  # 8. Visual mappings
  # ---------------------------------------------------------------------------

  model_cols <- c(
    "Phi-3.5-mini-3.8B" = "#1F77B4",
    "Mistral-7B"        = "#FF7F0E",
    "Llama-3.1-8B"      = "#2CA02C",
    "Gemma-2-9B"        = "#D62728",
    "Mixtral-8x7B"      = "#9467BD"
  )

  unknown_models <- setdiff(
    levels(config_data$model),
    names(model_cols)
  )

  if (length(unknown_models) > 0L) {

    fallback_cols <- scales::hue_pal()(
      length(unknown_models)
    )

    names(fallback_cols) <- unknown_models

    model_cols <- c(
      model_cols,
      fallback_cols
    )
  }

  quant_shapes <- c(
    "Q2_K"   = 16,
    "Q4_K_M" = 17,
    "Q5_K_M" = 15,
    "Q6_K"   = 18,
    "Q8_0"   = 8,
    "FP16"   = 7
  )

  unknown_quants <- setdiff(
    levels(config_data$quant),
    names(quant_shapes)
  )

  if (length(unknown_quants) > 0L) {

    fallback_pool <- c(
      3, 4, 9, 10, 12, 13, 14
    )

    if (length(unknown_quants) > length(fallback_pool)) {
      stop(
        "Too many unknown quantization levels for the available ",
        "fallback shapes."
      )
    }

    fallback_shapes <- fallback_pool[
      seq_along(unknown_quants)
    ]

    names(fallback_shapes) <- unknown_quants

    quant_shapes <- c(
      quant_shapes,
      fallback_shapes
    )
  }

  pareto_label <- "Pareto front"

  # ---------------------------------------------------------------------------
  # 9. Build plot
  # ---------------------------------------------------------------------------

  p <- ggplot2::ggplot(
    config_data,
    ggplot2::aes(
      x = tokens_per_sec,
      y = total_energy_j
    )
  ) +

    # All evaluated configuration means
    ggplot2::geom_point(
      ggplot2::aes(
        colour = model,
        shape = quant
      ),
      size = 2.25,
      alpha = 0.68,
      stroke = 0.4,
      na.rm = TRUE
    ) +

    # Pareto line
    ggplot2::geom_line(
      data = front_line,
      mapping = ggplot2::aes(
        x = tokens_per_sec,
        y = total_energy_j,
        linetype = pareto_label,
        group = if (has_mode) exec_mode else 1
      ),
      inherit.aes = FALSE,
      colour = "black",
      linewidth = 1.00,
      lineend = "round"
    ) +

    # Pareto points
    ggplot2::geom_point(
      data = front,
      mapping = ggplot2::aes(
        x = tokens_per_sec,
        y = total_energy_j
      ),
      inherit.aes = FALSE,
      colour = "black",
      fill = "black",
      shape = 21,
      size = 3.4,
      stroke = 0.7,
      na.rm = TRUE
    ) +

    # 95% confidence intervals only for Pareto-optimal configurations
    ggplot2::geom_errorbar(
      data = front,
      mapping = ggplot2::aes(
        x = tokens_per_sec,
        ymin = total_energy_j_lower,
        ymax = total_energy_j_upper
      ),
      inherit.aes = FALSE,
      width = 0,
      colour = "black",
      linewidth = 0.55,
      alpha = 0.70,
      na.rm = TRUE
    ) +

    ggplot2::geom_errorbar(
      data = front,
      mapping = ggplot2::aes(
        y = total_energy_j,
        xmin = tokens_per_sec_lower,
        xmax = tokens_per_sec_upper
      ),
      orientation = "y",
      inherit.aes = FALSE,
      width = 0,
      colour = "black",
      linewidth = 0.55,
      alpha = 0.70,
      na.rm = TRUE
    ) +

    # -------------------------------------------------------------------------
    # Scales
    # -------------------------------------------------------------------------

    ggplot2::scale_colour_manual(
      values = model_cols,
      breaks = levels(config_data$model),
      drop = TRUE,
      name = "Model"
    ) +

    ggplot2::scale_shape_manual(
      values = quant_shapes,
      breaks = levels(config_data$quant),
      drop = TRUE,
      name = "Quantization"
    ) +

    ggplot2::scale_linetype_manual(
      values = stats::setNames(
        "solid",
        pareto_label
      ),
      name = NULL
    ) +

    ggplot2::scale_x_continuous(
      labels = scales::label_number(
        accuracy = 0.1,
        big.mark = ",",
        trim = TRUE
      ),
      expand = ggplot2::expansion(
        mult = c(0.04, 0.07)
      )
    ) +

    ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(
        mult = c(0.03, 0.07)
      )
    ) +

    # -------------------------------------------------------------------------
    # Labels
    # -------------------------------------------------------------------------

    ggplot2::labs(
      title = "Energy vs. Performance (Pareto Front)",
      subtitle = sprintf(
        paste(
          "Each point represents the mean of one configuration",
          "across repetitions (n = %d configurations).",
          "Colors indicate models; shapes indicate quantization."
        ),
        nrow(config_data)
      ),
      x = "Throughput (tokens/s)",
      y = "Total PSU energy (J)",
      caption = paste(
        "Black markers identify non-dominated configuration means.",
        "Black error bars show 95% confidence intervals for Pareto points.",
        "Lines connect Pareto-optimal points only as a visual guide.",
        "CPU-only and GPU-only panels use independently scaled axes."
      )
    ) +

    theme_pub() +

    # -------------------------------------------------------------------------
    # Legends
    # -------------------------------------------------------------------------

    ggplot2::guides(
      colour = ggplot2::guide_legend(
        order = 1,
        override.aes = list(
          shape = 16,
          size = 3.2,
          alpha = 1
        )
      ),

      shape = ggplot2::guide_legend(
        order = 2,
        override.aes = list(
          colour = "grey25",
          size = 3.0,
          alpha = 1
        )
      ),

      linetype = ggplot2::guide_legend(
        order = 3,
        override.aes = list(
          colour = "black",
          linewidth = 1.00
        )
      )
    ) +

    # -------------------------------------------------------------------------
    # Publication styling
    # -------------------------------------------------------------------------

    ggplot2::theme(
      plot.title = ggplot2::element_text(
        face = "bold",
        size = 18,
        hjust = 0.5,
        margin = ggplot2::margin(
          b = 4
        )
      ),

      plot.subtitle = ggplot2::element_text(
        size = 11.5,
        colour = "grey35",
        hjust = 0.5,
        lineheight = 1.10,
        margin = ggplot2::margin(
          b = 11
        )
      ),

      plot.caption = ggplot2::element_text(
        size = 8.8,
        colour = "grey35",
        hjust = 0,
        lineheight = 1.15,
        margin = ggplot2::margin(
          t = 10
        )
      ),

      strip.background = ggplot2::element_blank(),

      strip.text = ggplot2::element_text(
        face = "bold",
        size = 13.5,
        colour = "grey10",
        margin = ggplot2::margin(
          t = 2,
          b = 6
        )
      ),

      axis.title = ggplot2::element_text(
        size = 12
      ),

      axis.text = ggplot2::element_text(
        size = 10,
        colour = "grey25"
      ),

      panel.border = ggplot2::element_rect(
        colour = "grey35",
        fill = NA,
        linewidth = 0.5
      ),

      panel.grid.major = ggplot2::element_line(
        colour = "grey87",
        linewidth = 0.45
      ),

      panel.grid.minor = ggplot2::element_blank(),

      panel.spacing = grid::unit(
        1.7,
        "lines"
      ),

      legend.position = "right",
      legend.justification = "top",
      legend.box = "vertical",
      legend.box.just = "left",

      legend.box.spacing = grid::unit(
        0.25,
        "cm"
      ),

      legend.title = ggplot2::element_text(
        face = "bold",
        size = 11.5
      ),

      legend.text = ggplot2::element_text(
        size = 10
      ),

      legend.key.height = grid::unit(
        0.95,
        "lines"
      ),

      legend.key.width = grid::unit(
        1.15,
        "lines"
      ),

      plot.margin = ggplot2::margin(
        t = 10,
        r = 8,
        b = 8,
        l = 8
      )
    )

  # ---------------------------------------------------------------------------
  # 10. CPU/GPU panels
  # ---------------------------------------------------------------------------

  if (has_mode) {

    panel_labels <- c(
      "CPU-only" = "(A) CPU-only",
      "GPU-only" = "(B) GPU-only"
    )

    p <- p +
      ggplot2::facet_wrap(
        ~ exec_mode,
        nrow = 1,
        scales = "free",
        labeller = ggplot2::as_labeller(
          panel_labels
        )
      )
  }

  # ---------------------------------------------------------------------------
  # 11. Return figure and supporting data
  # ---------------------------------------------------------------------------

  list(
    plot = p,
    data = config_data,
    raw_data = raw_data,
    configuration_data = config_data,
    frontier = front,
    uncertainty = config_data |>
      dplyr::select(
        dplyr::all_of(config_keys),
        repetitions,
        tokens_per_sec,
        tokens_per_sec_lower,
        tokens_per_sec_upper,
        total_energy_j,
        total_energy_j_lower,
        total_energy_j_upper
      )
  )
}

## ---------------------------------------------------------------------------
## Figure 4 -- Correlation matrix (lower triangle, hierarchically clustered).
## Correlations with |r| < threshold are blanked; significance is overlaid.
## ---------------------------------------------------------------------------
compute_correlations <- function(df, vars, method = "spearman") {
  vars <- Filter(function(v) v %in% names(df) && sum(is.finite(df[[v]])) >= 4, vars)
  m <- as.matrix(df[, vars, drop = FALSE])
  storage.mode(m) <- "double"
  r <- stats::cor(m, use = "pairwise.complete.obs", method = method)
  ## p-values per pair.
  p <- matrix(NA_real_, length(vars), length(vars), dimnames = list(vars, vars))
  for (i in seq_along(vars)) for (j in seq_along(vars)) if (i != j) {
    ct <- tryCatch(stats::cor.test(m[, i], m[, j], method = method,
                                   exact = FALSE), error = function(e) NULL)
    if (!is.null(ct)) p[i, j] <- ct$p.value
  }
  list(r = r, p = p, vars = vars)
}

fig_correlation <- function(cor_obj, hide_below = 0.30, cluster = FALSE,
                            alpha = 0.05) {
  r <- cor_obj$r; p <- cor_obj$p
  if (isTRUE(cluster) && nrow(r) > 2) {
    ord <- stats::hclust(stats::as.dist(1 - abs(r)))$order
    r <- r[ord, ord]; p <- p[ord, ord]
  }
  vars <- rownames(r); n <- length(vars)
  long <- do.call(rbind, lapply(seq_len(n), function(i)
    do.call(rbind, lapply(seq_len(n), function(j) data.frame(
      row = vars[i], col = vars[j], i = i, j = j,
      r = r[i, j], p = p[i, j], stringsAsFactors = FALSE)))))
  ## Lower triangle only.
  long <- long[long$i > long$j, , drop = FALSE]
  ## Annotate only correlations at/above the threshold.
  long$r_show <- ifelse(abs(long$r) >= hide_below, long$r, NA_real_)

  ## Short, publication-friendly axis labels.
  short_map <- c(total_energy_j = "Energy", energy_adj_j = "Energy (adj)",
                 total_energy_socket_j = "Socket energy", exec_time_s = "Time",
                 tokens_per_joule = "Tokens/J", tokens_per_sec = "Throughput",
                 energy_per_token_j = "J/token",
                 avg_psu_power_w = "Avg power", avg_socket_power_w = "Avg power",
                 peak_psu_power_w = "Peak power", avg_cpu_freq_mhz = "CPU freq",
                 avg_cpu_util_pct = "CPU usage")
  short_fn <- function(x) ifelse(x %in% names(short_map), short_map[x], lab(x))

  long$row <- factor(long$row, levels = vars)
  long$col <- factor(long$col, levels = vars)

  p_plot <- ggplot2::ggplot(long, ggplot2::aes(col, row, fill = r)) +
    ggplot2::geom_tile() +
    ggplot2::geom_text(ggplot2::aes(label = ifelse(is.na(r_show), "",
                       sprintf("%.2f", r_show))), colour = "black", size = 3) +
    ggplot2::scale_fill_viridis_c(option = "D", limits = c(-1, 1),
      breaks = seq(-1, 1, 0.25), labels = function(b) sprintf("%.2f", b),
      na.value = "white", name = "Pearson r",
      guide = ggplot2::guide_colourbar(title.position = "right",
        barheight = ggplot2::unit(15, "lines"),
        barwidth  = ggplot2::unit(0.8, "lines"))) +
    ggplot2::scale_x_discrete(limits = vars, labels = short_fn, drop = FALSE,
                              expand = c(0, 0)) +
    ggplot2::scale_y_discrete(limits = rev(vars), labels = short_fn, drop = FALSE,
                              expand = c(0, 0)) +
    ggplot2::labs(title = "Runtime metric correlations", x = NULL, y = NULL) +
    theme_pub() +
    ggplot2::theme(
      legend.position = "right",
      legend.title    = ggplot2::element_text(angle = 90, hjust = 0.5),
      axis.text.x     = ggplot2::element_text(angle = 45, hjust = 1),
      panel.grid      = ggplot2::element_blank(),
      panel.border    = ggplot2::element_rect(colour = "black", fill = NA,
                                              linewidth = 0.8),
      plot.title      = ggplot2::element_text(face = "plain", hjust = 0.5, size = 15),
      plot.subtitle   = ggplot2::element_blank())
  list(plot = p_plot, data = long)
}

## ---------------------------------------------------------------------------
## Figure 8 -- Model x Quantization interaction on Total Energy. Mean total
## energy per (model, quant) cell with 95% CIs, one line per model across the
## quantization axis. Non-parallel lines indicate a model x quant interaction
## (e.g. a larger model's energy rising faster with higher-bit quantization).
## ---------------------------------------------------------------------------
fig_model_quant_interaction <- function(metrics, response = "total_energy_j",
                                        response_label = "Mean total energy (J)") {
  if (!all(c("model", "quant", response) %in% names(metrics)))
    return(list(plot = NULL, data = NULL))
  d <- metrics[is.finite(metrics[[response]]) &
                 !is.na(metrics$model) & !is.na(metrics$quant), , drop = FALSE]
  if (!nrow(d)) return(list(plot = NULL, data = NULL))

  quant_lv <- levels(droplevels(as.factor(d$quant)))
  model_lv <- levels(droplevels(as.factor(d$model)))

  ## Per-cell observed mean + 95% CI.
  summ <- do.call(rbind, lapply(model_lv, function(m)
    do.call(rbind, lapply(quant_lv, function(q) {
      x  <- d[[response]][as.character(d$model) == m & as.character(d$quant) == q]
      ci <- mean_ci(x)
      data.frame(model = m, quant = q, mean = unname(ci["mean"]),
                 lower = unname(ci["lower"]), upper = unname(ci["upper"]),
                 n = unname(ci["n"]), stringsAsFactors = FALSE)
    }))))
  summ <- summ[is.finite(summ$mean), , drop = FALSE]
  if (!nrow(summ)) return(list(plot = NULL, data = summ))
  summ$model <- factor(summ$model, levels = model_lv)
  summ$quant <- factor(summ$quant, levels = quant_lv)

  ## Model palette consistent with Figure 3 (tab10).
  model_cols <- c("Phi-3.5-mini-3.8B" = "#1f77b4", "Mistral-7B" = "#ff7f0e",
                  "Llama-3.1-8B" = "#2ca02c", "Gemma-2-9B" = "#d62728",
                  "Mixtral-8x7B" = "#9467bd")
  dodge <- ggplot2::position_dodge(width = 0.3)

  p <- ggplot2::ggplot(summ, ggplot2::aes(x = quant, y = mean, colour = model,
                                          group = model)) +
    ggplot2::geom_line(position = dodge, linewidth = 0.8) +
    ggplot2::geom_errorbar(ggplot2::aes(ymin = lower, ymax = upper),
                           position = dodge, width = 0.22, linewidth = 0.6) +
    ggplot2::geom_point(position = dodge, size = 2.8) +
    ggplot2::scale_colour_manual(values = model_cols, name = "Model",
                                 limits = model_lv) +
    ggplot2::scale_y_continuous(labels = scales::label_comma(),
                                expand = ggplot2::expansion(mult = c(0.04, 0.08))) +
    ggplot2::labs(title = "Model \u00d7 quantization interaction on total energy",
                  subtitle = "Cell means with 95% confidence intervals",
                  x = "Quantization", y = response_label) +
    theme_pub() +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      plot.title       = ggplot2::element_text(face = "bold"),
      plot.subtitle    = ggplot2::element_text(colour = "grey35"))
  list(plot = p, data = summ)
}

## ---------------------------------------------------------------------------
## Figure 9 -- Execution time and average power as drivers of total energy. Two
## side-by-side panels: (a) execution time vs total PSU energy, (b) average PSU
## power vs total PSU energy. Points are configuration-level means (across
## repetitions) with 95% CIs on both axes; a per-execution-mode linear trend and
## Pearson's r (overall + per mode) are shown per panel. Answers whether time or
## power is the stronger correlate of energy-to-solution.
## ---------------------------------------------------------------------------
fig_energy_drivers <- function(
    metrics,
    energy = "total_energy_j",
    time = "exec_time_s",
    power = "avg_psu_power_w"
) {

  # ---------------------------------------------------------------------------
  # 1. Validate required columns
  # ---------------------------------------------------------------------------

  required_cols <- c(
    energy,
    time,
    power,
    "exec_mode"
  )

  missing_cols <- setdiff(required_cols, names(metrics))

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  d <- metrics[
    is.finite(metrics[[energy]]) &
      is.finite(metrics[[time]]) &
      is.finite(metrics[[power]]) &
      !is.na(metrics$exec_mode),
    ,
    drop = FALSE
  ]

  if (!nrow(d)) {
    return(
      list(
        plot = NULL,
        data = NULL,
        long_data = NULL,
        correlations = NULL
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 2. Aggregate repetitions at configuration level
  # ---------------------------------------------------------------------------

  config_keys <- Filter(
    function(column) column %in% names(d),
    c(
      "node",
      "exec_mode",
      "gpu_arch",
      "cpu_arch",
      "model",
      "quant",
      "threads",
      "gpu_layers",
      "batch_size",
      "context_size",
      "backend"
    )
  )

  if (!length(config_keys)) {
    stop("No valid configuration-identifying columns were found.")
  }

  configuration_data <- d |>
    dplyr::group_by(
      dplyr::across(
        dplyr::all_of(config_keys)
      )
    ) |>
    dplyr::summarise(
      energy = mean(
        .data[[energy]],
        na.rm = TRUE
      ),
      execution_time = mean(
        .data[[time]],
        na.rm = TRUE
      ),
      average_power = mean(
        .data[[power]],
        na.rm = TRUE
      ),
      repetitions = dplyr::n(),
      .groups = "drop"
    )

  # Keep execution-mode order stable
  mode_order <- c(
    "CPU-only",
    "GPU-only",
    "CPU-GPU"
  )

  present_modes <- mode_order[
    mode_order %in%
      unique(as.character(configuration_data$exec_mode))
  ]

  extra_modes <- setdiff(
    unique(as.character(configuration_data$exec_mode)),
    mode_order
  )

  configuration_data$exec_mode <- factor(
    configuration_data$exec_mode,
    levels = c(
      present_modes,
      extra_modes
    )
  )

  # ---------------------------------------------------------------------------
  # 3. Convert to long format
  # ---------------------------------------------------------------------------

  driver_time <- "(A) Execution time vs. total energy"
  driver_power <- "(B) Average PSU power vs. total energy"

  long_data <- dplyr::bind_rows(
    configuration_data |>
      dplyr::transmute(
        exec_mode,
        driver = driver_time,
        x = execution_time,
        energy = energy
      ),

    configuration_data |>
      dplyr::transmute(
        exec_mode,
        driver = driver_power,
        x = average_power,
        energy = energy
      )
  )

  long_data$driver <- factor(
    long_data$driver,
    levels = c(
      driver_time,
      driver_power
    )
  )

  # ---------------------------------------------------------------------------
  # 4. Pearson correlations by execution mode
  # ---------------------------------------------------------------------------

  safe_pearson <- function(x, y) {

    valid <- is.finite(x) & is.finite(y)

    if (sum(valid) < 3L) {
      return(NA_real_)
    }

    x_valid <- x[valid]
    y_valid <- y[valid]

    if (
      stats::sd(x_valid) == 0 ||
        stats::sd(y_valid) == 0
    ) {
      return(NA_real_)
    }

    stats::cor(
      x_valid,
      y_valid,
      method = "pearson"
    )
  }

  correlation_data <- long_data |>
    dplyr::group_by(
      driver,
      exec_mode
    ) |>
    dplyr::summarise(
      n = dplyr::n(),
      r = safe_pearson(
        x,
        energy
      ),
      .groups = "drop"
    ) |>
    dplyr::filter(
      is.finite(r)
    ) |>
    dplyr::mutate(
      label = sprintf(
        "%s: r = %.2f",
        as.character(exec_mode),
        r
      )
    )

  # ---------------------------------------------------------------------------
  # 5. Execution-mode colors
  # ---------------------------------------------------------------------------

  mode_colors <- c(
    "CPU-only" = "#7A5195",
    "GPU-only" = "#EF5675",
    "CPU-GPU"  = "#FFA600"
  )

  missing_modes <- setdiff(
    levels(configuration_data$exec_mode),
    names(mode_colors)
  )

  if (length(missing_modes) > 0L) {
    fallback_colors <- scales::hue_pal()(
      length(missing_modes)
    )

    names(fallback_colors) <- missing_modes

    mode_colors <- c(
      mode_colors,
      fallback_colors
    )
  }

  # ---------------------------------------------------------------------------
  # 6. Shared panel builder
  # ---------------------------------------------------------------------------

  make_panel <- function(
      driver_name,
      x_label
  ) {

    panel_data <- long_data[
      long_data$driver == driver_name,
      ,
      drop = FALSE
    ]

    ggplot2::ggplot(
      panel_data,
      ggplot2::aes(
        x = x,
        y = energy,
        colour = exec_mode,
        fill = exec_mode
      )
    ) +

      # Linear fit with 95% confidence interval by execution mode
      ggplot2::geom_smooth(
        ggplot2::aes(
          group = exec_mode
        ),
        method = "lm",
        formula = y ~ x,
        se = TRUE,
        linewidth = 0.9,
        alpha = 0.13,
        show.legend = FALSE
      ) +

      # Configuration-level means
      ggplot2::geom_point(
        size = 1.8,
        alpha = 0.72,
        stroke = 0.35
      ) +

      ggplot2::scale_colour_manual(
        values = mode_colors,
        name = "Execution mode",
        drop = TRUE
      ) +

      ggplot2::scale_fill_manual(
        values = mode_colors,
        guide = "none",
        drop = TRUE
      ) +

      ggplot2::scale_x_continuous(
        labels = scales::label_comma(),
        expand = ggplot2::expansion(
          mult = c(0.03, 0.06)
        )
      ) +

      ggplot2::scale_y_continuous(
        labels = scales::label_comma(),
        expand = ggplot2::expansion(
          mult = c(0.03, 0.08)
        )
      ) +

      ggplot2::labs(
        title = driver_name,
        x = x_label,
        y = "Total PSU energy (J)"
      ) +

      theme_pub(base_size = 13) +

      ggplot2::theme(
        plot.title = ggplot2::element_text(
          face = "bold",
          size = 14,
          hjust = 0
        ),

        axis.title = ggplot2::element_text(
          size = 12
        ),

        axis.text = ggplot2::element_text(
          size = 10.5,
          colour = "grey25"
        ),

        panel.border = ggplot2::element_rect(
          colour = "grey40",
          fill = NA,
          linewidth = 0.45
        ),

        panel.grid.major = ggplot2::element_line(
          colour = "grey87",
          linewidth = 0.45
        ),

        panel.grid.minor = ggplot2::element_blank(),

        legend.position = "right",
        legend.direction = "vertical",
        legend.justification = "top",
        legend.title = ggplot2::element_text(
          size = 11,
          face = "bold"
        ),
        legend.text = ggplot2::element_text(
          size = 10
        ),

        plot.margin = ggplot2::margin(
          t = 5,
          r = 8,
          b = 5,
          l = 5
        )
      )
  }

  # ---------------------------------------------------------------------------
  # 7. Create both panels
  # ---------------------------------------------------------------------------

  panel_time <- make_panel(
    driver_name = driver_time,
    x_label = "Execution time (s)"
  )

  # ---------------------------------------------------------------------------
  # 8. Global title, subtitle, and caption
  # ---------------------------------------------------------------------------

  n_configurations <- nrow(
    configuration_data
  )

  title <- "Energy Association with Execution Time"

  subtitle <- sprintf(
    paste0(
      "Configuration-level means across repetitions (n = %d); ",
      "linear fits and 95%% CIs by execution mode."
    ),
    n_configurations
  )

  corr_txt <- correlation_data[
    correlation_data$driver == driver_time,
    ,
    drop = FALSE
  ]

  pearson_line <- if (nrow(corr_txt) > 0L) {
    paste0(
      "Pearson r by execution mode: ",
      paste(corr_txt$label, collapse = "; "), "."
    )
  } else {
    "Pearson r by execution mode."
  }

  caption <- paste0(
    "Points are configuration-level means; ",
    "lines and shaded bands show per-mode linear fits with 95% CIs.\n",
    pearson_line
  )

  # ---------------------------------------------------------------------------
  # 9. Assemble the execution-time figure (legend on the right)
  # ---------------------------------------------------------------------------

  combined_plot <- panel_time +
    ggplot2::labs(
      title = title,
      subtitle = subtitle,
      caption = caption
    ) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(
        face = "bold",
        size = 18,
        hjust = 0.5,
        margin = ggplot2::margin(
          b = 4
        )
      ),

      plot.subtitle = ggplot2::element_text(
        colour = "grey35",
        size = 12,
        hjust = 0.5,
        margin = ggplot2::margin(
          b = 10
        )
      ),

      plot.caption = ggplot2::element_text(
        colour = "grey35",
        size = 9,
        hjust = 0,
        lineheight = 1.15,
        margin = ggplot2::margin(
          t = 8
        )
      )
    )

  # ---------------------------------------------------------------------------
  # 10. Return
  # ---------------------------------------------------------------------------

  list(
    plot = combined_plot,
    data = configuration_data,
    long_data = long_data,
    correlations = correlation_data
  )
}

## ---------------------------------------------------------------------------
## GPU architecture effect on energy and throughput.
## Builds two standalone figures (identical aesthetic) comparing
## V100 / A100 / H100 on (1) mean total PSU energy and (2) mean throughput,
## each with 95% CIs computed over configuration-level means (repetitions
## collapsed per node x model x quant). CPU-only runs are excluded.
## Returns list(plot_energy, plot_throughput, data = arch-level summary).
## ---------------------------------------------------------------------------

fig_gpu_arch_effect <- function(
    metrics,
    energy = "total_energy_j",
    tput = "tokens_per_sec",
    energy_label = "Total PSU energy (J)",
    interval = c("ci", "iqr"),
    seed = 20260717
) {

  interval <- match.arg(interval)

  # ---------------------------------------------------------------------------
  # 1. Validate required columns
  # ---------------------------------------------------------------------------

  required_cols <- c(
    energy,
    tput,
    "gpu_arch",
    "model",
    "quant",
    "exec_mode"
  )

  missing_cols <- setdiff(
    required_cols,
    names(metrics)
  )

  if (length(missing_cols) > 0L) {
    stop(
      "Missing required columns: ",
      paste(missing_cols, collapse = ", ")
    )
  }

  gpu_levels <- c(
    "V100",
    "A100",
    "H100"
  )

  model_levels <- c(
    "Gemma-2-9B",
    "Llama-3.1-8B",
    "Mistral-7B",
    "Phi-3.5-mini-3.8B"
  )

  quant_levels <- c(
    "Q2_K",
    "Q4_K_M",
    "Q5_K_M",
    "Q6_K",
    "Q8_0",
    "FP16"
  )

  # ---------------------------------------------------------------------------
  # 2. Keep GPU-only observations
  # ---------------------------------------------------------------------------

  d <- metrics[
    !is.na(metrics$exec_mode) &
      as.character(metrics$exec_mode) != "CPU-only" &
      !is.na(metrics$gpu_arch) &
      !is.na(metrics$model) &
      !is.na(metrics$quant) &
      as.character(metrics$gpu_arch) %in% gpu_levels &
      as.character(metrics$model) %in% model_levels &
      as.character(metrics$quant) %in% quant_levels &
      is.finite(metrics[[energy]]) &
      is.finite(metrics[[tput]]),
    ,
    drop = FALSE
  ]

  if (!nrow(d)) {
    return(
      list(
        plot_energy = NULL,
        plot_throughput = NULL,
        data = NULL,
        observations = NULL,
        repetition_data = NULL,
        configuration_data = NULL
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 3. Determine present factor levels
  # ---------------------------------------------------------------------------

  present_gpus <- gpu_levels[
    gpu_levels %in% unique(as.character(d$gpu_arch))
  ]

  present_models <- model_levels[
    model_levels %in% unique(as.character(d$model))
  ]

  present_quants <- quant_levels[
    quant_levels %in% unique(as.character(d$quant))
  ]

  d$gpu_arch <- factor(
    d$gpu_arch,
    levels = present_gpus
  )

  d$model <- factor(
    d$model,
    levels = present_models
  )

  d$quant <- factor(
    d$quant,
    levels = present_quants
  )

  # ---------------------------------------------------------------------------
  # 4. Aggregate repetitions at configuration level
  #
  # These values are used for the small background points.
  # ---------------------------------------------------------------------------

  config_keys <- Filter(
    function(column) column %in% names(d),
    c(
      "node",
      "gpu_arch",
      "model",
      "quant",
      "threads",
      "gpu_layers",
      "batch_size",
      "context_size",
      "backend"
    )
  )

  config_keys <- unique(
    c(
      "gpu_arch",
      "model",
      "quant",
      config_keys
    )
  )

  config_data <- d |>
    dplyr::group_by(
      dplyr::across(
        dplyr::all_of(config_keys)
      )
    ) |>
    dplyr::summarise(
      energy = mean(
        .data[[energy]],
        na.rm = TRUE
      ),

      throughput = mean(
        .data[[tput]],
        na.rm = TRUE
      ),

      repetitions = dplyr::n(),

      .groups = "drop"
    ) |>
    dplyr::filter(
      is.finite(energy),
      is.finite(throughput)
    )

  config_data$gpu_arch <- factor(
    config_data$gpu_arch,
    levels = present_gpus
  )

  config_data$model <- factor(
    config_data$model,
    levels = present_models
  )

  config_data$quant <- factor(
    config_data$quant,
    levels = present_quants
  )

  # ---------------------------------------------------------------------------
  # 5. Controlled horizontal positions
  # ---------------------------------------------------------------------------

  model_positions <- stats::setNames(
    seq_along(present_models),
    present_models
  )

  quant_offsets <- seq(
    from = -0.27,
    to = 0.27,
    length.out = length(present_quants)
  )

  names(quant_offsets) <- present_quants

  add_positions <- function(data) {

    data |>
      dplyr::mutate(
        model_center = unname(
          model_positions[as.character(model)]
        ),

        quant_offset = unname(
          quant_offsets[as.character(quant)]
        ),

        x_position = model_center + quant_offset
      )
  }

  config_data <- add_positions(config_data)
  d <- add_positions(d)

  # ---------------------------------------------------------------------------
  # 6. Configuration-level means in long format
  # ---------------------------------------------------------------------------

  observations <- dplyr::bind_rows(

    config_data |>
      dplyr::transmute(
        gpu_arch,
        model,
        quant,
        metric = "energy",
        value = energy,
        repetitions,
        model_center,
        x_position
      ),

    config_data |>
      dplyr::transmute(
        gpu_arch,
        model,
        quant,
        metric = "throughput",
        value = throughput,
        repetitions,
        model_center,
        x_position
      )
  )

  observations$metric <- factor(
    observations$metric,
    levels = c(
      "energy",
      "throughput"
    )
  )

  # ---------------------------------------------------------------------------
  # 7. Original repetitions in long format
  #
  # These values are used to calculate means and 95% confidence intervals.
  # ---------------------------------------------------------------------------

  repetition_data <- dplyr::bind_rows(

    d |>
      dplyr::transmute(
        gpu_arch,
        model,
        quant,
        metric = "energy",
        value = .data[[energy]],
        model_center,
        x_position
      ),

    d |>
      dplyr::transmute(
        gpu_arch,
        model,
        quant,
        metric = "throughput",
        value = .data[[tput]],
        model_center,
        x_position
      )
  ) |>
    dplyr::filter(
      is.finite(value)
    )

  repetition_data$metric <- factor(
    repetition_data$metric,
    levels = c(
      "energy",
      "throughput"
    )
  )

  # ---------------------------------------------------------------------------
  # 8. Reproducible jitter for configuration-level points
  # ---------------------------------------------------------------------------

  set.seed(seed)

  observations <- observations |>
    dplyr::mutate(
      x_jitter = x_position +
        stats::runif(
          dplyr::n(),
          min = -0.017,
          max = 0.017
        )
    )

  # ---------------------------------------------------------------------------
  # 9. Mean and 95% confidence interval across original repetitions
  # ---------------------------------------------------------------------------

  summary_data <- repetition_data |>
    dplyr::group_by(
      gpu_arch,
      model,
      quant,
      metric,
      model_center,
      x_position
    ) |>
    dplyr::summarise(
      n = dplyr::n(),

      mean_val = mean(
        value,
        na.rm = TRUE
      ),

      sd = dplyr::if_else(
        n > 1L,
        stats::sd(
          value,
          na.rm = TRUE
        ),
        NA_real_
      ),

      se = dplyr::if_else(
        n > 1L,
        sd / sqrt(n),
        NA_real_
      ),

      t_critical = dplyr::if_else(
        n > 1L,
        stats::qt(
          p = 0.975,
          df = pmax(n - 1L, 1L)
        ),
        NA_real_
      ),

      margin_error = dplyr::if_else(
        n > 1L,
        t_critical * se,
        NA_real_
      ),

      median_val = stats::median(
        value,
        na.rm = TRUE
      ),

      q25 = stats::quantile(
        value,
        probs = 0.25,
        na.rm = TRUE,
        names = FALSE
      ),

      q75 = stats::quantile(
        value,
        probs = 0.75,
        na.rm = TRUE,
        names = FALSE
      ),

      .groups = "drop"
    )

  # For the robust variant (interval = "iqr") the central marker is the median
  # and the error bars span the interquartile range; otherwise the marker is
  # the mean with a 95% confidence interval.
  if (identical(interval, "iqr")) {
    summary_data$mean  <- summary_data$median_val
    summary_data$lower <- summary_data$q25
    summary_data$upper <- summary_data$q75
  } else {
    summary_data$mean  <- summary_data$mean_val
    summary_data$lower <- summary_data$mean_val - summary_data$margin_error
    summary_data$upper <- summary_data$mean_val + summary_data$margin_error
  }

  # ---------------------------------------------------------------------------
  # 10. Quantization colors
  # ---------------------------------------------------------------------------

  quant_colors <- c(
    "Q2_K"   = "#E64B35",
    "Q4_K_M" = "#EFAF00",
    "Q5_K_M" = "#4DAF4A",
    "Q6_K"   = "#377EB8",
    "Q8_0"   = "#984EA3",
    "FP16"   = "#8C564B"
  )

  quant_colors <- quant_colors[
    present_quants
  ]

  # ---------------------------------------------------------------------------
  # 11. Shared plot builder
  # ---------------------------------------------------------------------------

  make_panel <- function(
      metric_name,
      y_label
  ) {

    panel_observations <- observations[
      observations$metric == metric_name,
      ,
      drop = FALSE
    ]

    panel_summary <- summary_data[
      summary_data$metric == metric_name,
      ,
      drop = FALSE
    ]

    ggplot2::ggplot() +

      # Subtle separators between model groups
      ggplot2::geom_vline(
        xintercept = seq(
          1.5,
          length(present_models) - 0.5,
          by = 1
        ),
        colour = "grey94",
        linewidth = 0.3
      ) +

      # Configuration-level means
      ggplot2::geom_point(
        data = panel_observations,
        mapping = ggplot2::aes(
          x = x_jitter,
          y = value,
          colour = quant
        ),
        shape = 16,
        size = 1.6,
        alpha = 0.22,
        stroke = 0,
        show.legend = FALSE
      ) +

      # 95% confidence intervals
      ggplot2::geom_errorbar(
        data = panel_summary,
        mapping = ggplot2::aes(
          x = x_position,
          ymin = lower,
          ymax = upper,
          colour = quant
        ),
        width = 0.045,
        linewidth = 0.85,
        lineend = "round",
        na.rm = TRUE,
        show.legend = FALSE
      ) +

      # Mean markers
      ggplot2::geom_point(
        data = panel_summary,
        mapping = ggplot2::aes(
          x = x_position,
          y = mean,
          fill = quant,
          colour = quant
        ),
        shape = 21,
        size = 3.25,
        stroke = 0.7
      ) +

      # GPU panels
      ggplot2::facet_wrap(
        facets = ggplot2::vars(gpu_arch),
        nrow = 1,
        scales = "free_y"
      ) +

      ggplot2::scale_colour_manual(
        values = quant_colors,
        breaks = present_quants,
        name = "Quantization",
        drop = FALSE
      ) +

      ggplot2::scale_fill_manual(
        values = quant_colors,
        breaks = present_quants,
        guide = "none",
        drop = FALSE
      ) +

      ggplot2::scale_x_continuous(
        breaks = seq_along(present_models),
        labels = present_models,
        limits = c(
          0.48,
          length(present_models) + 0.52
        ),
        expand = ggplot2::expansion(
          mult = c(0, 0)
        )
      ) +

      ggplot2::scale_y_continuous(
        labels = scales::label_comma(),
        expand = ggplot2::expansion(
          mult = c(0.03, 0.10)
        )
      ) +

      ggplot2::labs(
        x = "Model",
        y = y_label
      ) +

      ggplot2::guides(
        colour = ggplot2::guide_legend(
          title.position = "top",
          title.hjust = 0.5,
          nrow = 1,
          byrow = TRUE,
          override.aes = list(
            shape = 16,
            size = 3.4,
            alpha = 1
          )
        )
      ) +

      theme_pub(
        base_size = 13
      ) +

      ggplot2::theme(
        axis.title.x = ggplot2::element_text(
          size = 11.5,
          face = "bold",
          margin = ggplot2::margin(
            t = 12
          )
        ),

        axis.title.y = ggplot2::element_text(
          size = 11.5,
          face = "bold",
          margin = ggplot2::margin(
            r = 8
          )
        ),

        axis.text.x = ggplot2::element_text(
          size = 8.5,
          face = "bold",
          colour = "grey20",
          angle = 0,
          hjust = 0.5,
          margin = ggplot2::margin(
            t = 5
          )
        ),

        axis.text.y = ggplot2::element_text(
          size = 9.5,
          colour = "grey25"
        ),

        strip.background = ggplot2::element_blank(),

        strip.text.x = ggplot2::element_text(
          size = 12,
          face = "bold",
          colour = "grey20",
          margin = ggplot2::margin(
            b = 8
          )
        ),

        panel.border = ggplot2::element_blank(),

        panel.grid.major.y = ggplot2::element_line(
          colour = "grey86",
          linewidth = 0.45,
          linetype = "dashed"
        ),

        panel.grid.major.x = ggplot2::element_blank(),
        panel.grid.minor = ggplot2::element_blank(),

        panel.spacing.x = grid::unit(
          1.2,
          "cm"
        ),

        legend.position = "bottom",
        legend.direction = "horizontal",
        legend.justification = "center",

        legend.title = ggplot2::element_text(
          face = "bold",
          size = 10.5
        ),

        legend.text = ggplot2::element_text(
          size = 9.5
        ),

        legend.key.width = grid::unit(
          1.15,
          "lines"
        ),

        legend.key.height = grid::unit(
          0.9,
          "lines"
        ),

        legend.spacing.x = grid::unit(
          0.20,
          "cm"
        ),

        plot.margin = ggplot2::margin(
          t = 6,
          r = 10,
          b = 6,
          l = 7
        )
      )
  }

  # ---------------------------------------------------------------------------
  # 12. Create energy and throughput panels
  # ---------------------------------------------------------------------------

  panel_energy <- make_panel(
    metric_name = "energy",
    y_label = energy_label
  )

  panel_throughput <- make_panel(
    metric_name = "throughput",
    y_label = "Throughput (tokens/s)"
  )

  # ---------------------------------------------------------------------------
  # 13. Titles and annotations
  # ---------------------------------------------------------------------------

  energy_title_metric <- if (identical(energy, "energy_per_token_j")) {
    "Energy per Token"
  } else if (identical(energy, "tokens_per_joule")) {
    "Energy Efficiency"
  } else {
    "Total Energy"
  }

  title_energy <- paste(
    "Model and Quantization Effects on",
    energy_title_metric,
    if (identical(interval, "iqr")) "(GPU-by-Model, median \u00b1 IQR)"
    else "(GPU-by-Model)"
  )

  title_throughput <- paste(
    "Model and Quantization Effects on Throughput",
    if (identical(interval, "iqr")) "(GPU-by-Model, median \u00b1 IQR)"
    else "(GPU-by-Model)"
  )

  subtitle <- if (identical(interval, "iqr")) {
    sprintf(
      paste0(
        "Medians across experimental repetitions ",
        "(n = %d GPU-only runs); ",
        "error bars show the interquartile range (Q1-Q3); ",
        "each GPU subplot uses an independent y-axis scale."
      ),
      nrow(d)
    )
  } else {
    sprintf(
      paste0(
        "Means across experimental repetitions ",
        "(n = %d GPU-only runs); ",
        "error bars show 95%% confidence intervals; ",
        "each GPU subplot uses an independent y-axis scale."
      ),
      nrow(d)
    )
  }

  caption <- if (identical(interval, "iqr")) {
    paste(
      "Small points show configuration-level values;",
      "large markers show medians across repetitions,",
      "and error bars show the interquartile range (Q1-Q3)."
    )
  } else {
    paste(
      "Small points show configuration-level means;",
      "large markers show means across repetitions,",
      "and error bars show 95% confidence intervals."
    )
  }

  annotation_theme <- ggplot2::theme(
    plot.title = ggplot2::element_text(
      face = "bold",
      size = 17,
      hjust = 0.5,
      margin = ggplot2::margin(
        b = 3
      )
    ),

    plot.subtitle = ggplot2::element_text(
      colour = "grey35",
      size = 10.5,
      hjust = 0.5,
      margin = ggplot2::margin(
        b = 8
      )
    ),

    plot.caption = ggplot2::element_text(
      colour = "grey40",
      size = 8.5,
      hjust = 0.5,
      margin = ggplot2::margin(
        t = 9
      )
    )
  )

  # ---------------------------------------------------------------------------
  # 14. Assemble standalone figures
  # ---------------------------------------------------------------------------

  plot_energy <- panel_energy +
    ggplot2::labs(
      title = title_energy,
      subtitle = subtitle,
      caption = caption
    ) +
    annotation_theme

  plot_throughput <- panel_throughput +
    ggplot2::labs(
      title = title_throughput,
      subtitle = subtitle,
      caption = caption
    ) +
    annotation_theme

  # ---------------------------------------------------------------------------
  # 15. Return plots and supporting data
  # ---------------------------------------------------------------------------

  list(
    plot_energy = plot_energy,
    plot_throughput = plot_throughput,
    data = summary_data,
    observations = observations,
    repetition_data = repetition_data,
    configuration_data = config_data
  )
}

## ---------------------------------------------------------------------------
## fig_model_energy_by_quant -- Energy vs Model with ALL quantizations laid out
## side by side within each model cluster. x = model, colour = quantization
## (ordered side by side), shape = execution mode (CPU-only vs GPU-only, kept
## distinct so the two are never pooled). Large markers are means across
## repetitions with a 95% confidence interval.
## ---------------------------------------------------------------------------
fig_model_energy_by_quant <- function(metrics, energy = "total_energy_j",
                                      energy_label = "Total energy (J)",
                                      response_name = "Energy",
                                      log_y = FALSE,
                                      log_decade_grid = TRUE,
                                      facet_exec = FALSE,
                                      exec_shapes = c("CPU" = 21, "GPU" = 24),
                                      seed = 20260717) {
  req <- c(energy, "exec_mode", "model", "quant")
  if (length(setdiff(req, names(metrics))))
    return(list(plot = NULL, data = NULL))

  exec_levels  <- c("CPU", "GPU")
  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")

  d <- metrics[
    !is.na(metrics$exec_mode) & !is.na(metrics$model) & !is.na(metrics$quant) &
      as.character(metrics$exec_mode) %in% exec_levels &
      as.character(metrics$model) %in% model_levels &
      as.character(metrics$quant) %in% quant_levels &
      is.finite(metrics[[energy]]), , drop = FALSE]
  if (!nrow(d)) return(list(plot = NULL, data = NULL))

  present_models <- model_levels[model_levels %in% unique(as.character(d$model))]
  present_quants <- quant_levels[quant_levels %in% unique(as.character(d$quant))]
  present_exec   <- exec_levels[exec_levels %in% unique(as.character(d$exec_mode))]

  d$model     <- factor(d$model,     levels = present_models)
  d$quant     <- factor(d$quant,     levels = present_quants)
  d$exec_mode <- factor(d$exec_mode, levels = present_exec)

  ## Mean + 95% CI across repetitions per (model, quant, exec_mode).
  agg <- d |>
    dplyr::group_by(model, quant, exec_mode) |>
    dplyr::summarise(
      n        = dplyr::n(),
      mean_val = mean(.data[[energy]], na.rm = TRUE),
      sd       = dplyr::if_else(n > 1L, stats::sd(.data[[energy]], na.rm = TRUE), NA_real_),
      se       = dplyr::if_else(n > 1L, sd / sqrt(n), NA_real_),
      tcrit    = dplyr::if_else(n > 1L, stats::qt(0.975, pmax(n - 1L, 1L)), NA_real_),
      .groups  = "drop"
    ) |>
    dplyr::mutate(
      lower = mean_val - tcrit * se,
      upper = mean_val + tcrit * se
    )

  ## On a log y-axis a CI whose lower bound is <= 0 cannot be drawn; clamp it to
  ## a small positive fraction of the mean so the whisker stays visible.
  if (isTRUE(log_y))
    agg$lower <- pmax(agg$lower, agg$mean_val * 1e-3)

  ## x positions: model cluster -> quantization side-by-side -> exec micro-offset.
  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.34
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)), present_quants)
  else stats::setNames(0, present_quants)
  e_span    <- 0.05
  ## When faceting by execution mode, each panel holds a single mode, so the
  ## per-mode micro-offset is dropped and points align by quantization only.
  exec_off  <- if (isTRUE(facet_exec) || length(present_exec) <= 1L)
    stats::setNames(rep(0, length(present_exec)), present_exec)
  else
    stats::setNames(seq(-e_span, e_span, length.out = length(present_exec)), present_exec)

  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)]) +
           unname(exec_off[as.character(agg$exec_mode)])

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  exec_shapes  <- exec_shapes[present_exec]

  ## Title / subtitle / caption -- kept OUT of the plot; emitted to the sidecar.
  title_txt <- sprintf(
    "Model and Quantization Effects on %s (quantizations side by side%s)",
    response_name,
    if (isTRUE(log_y)) ", log scale" else ""
  )
  subtitle_txt <- sprintf(
    paste0("Means across repetitions (n = %d runs); error bars = 95%% CI. ",
           "Colour = quantization (side by side), shape = execution mode.%s"),
    nrow(d),
    if (isTRUE(log_y)) sprintf(" %s on a log10 y-axis.", response_name) else ""
  )
  caption_txt <- "Within each model, markers are ordered by quantization; execution modes stay distinct (never pooled)."

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean_val)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3
    ) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower, ymax = upper, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE
    ) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = exec_mode),
      colour = "grey25", size = 2.6, stroke = 0.5
    ) +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(
        order = 1, nrow = 1, byrow = TRUE,
        override.aes = list(shape = 21, size = 3.2))
    ) +
    ggplot2::scale_shape_manual(
      values = exec_shapes, name = "Execution mode",
      guide = ggplot2::guide_legend(
        order = 2, nrow = 1, byrow = TRUE,
        override.aes = list(fill = "grey40", size = 3.2))
    ) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))
    ) +
    ggplot2::labs(x = "Model", y = energy_label) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      legend.direction = "horizontal",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"
      ),
      axis.text.x   = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8))
    )

  ## Optionally split CPU (top) and GPU (bottom) into two stacked sub-panels,
  ## each with its own y-axis so their very different scales are both readable.
  ## The strip labels are dropped -- the execution mode is read from the marker
  ## shape legend (circle = CPU-only, triangle = GPU-only) instead.
  if (isTRUE(facet_exec))
    p <- p + ggplot2::facet_wrap(~ exec_mode, ncol = 1, scales = "free_y") +
      ggplot2::theme(
        strip.text       = ggplot2::element_blank(),
        strip.background = ggplot2::element_blank()
      )

  ## y-axis: linear (comma labels) or log10 depending on `log_y`.
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

  if (isTRUE(log_y) && isTRUE(log_decade_grid)) {
    add_decade_bands <- function(plot_obj, yvals) {
      yy <- yvals[is.finite(yvals) & yvals > 0]
      if (!length(yy)) return(plot_obj)
      dec <- 10^(floor(log10(min(yy))):ceiling(log10(max(yy))))
      if (length(dec) < 2L) return(plot_obj)
      bands <- data.frame(
        ymin = dec[-length(dec)],
        ymax = dec[-1],
        odd = seq_len(length(dec) - 1L) %% 2L == 1L
      )
      lyr_odd <- ggplot2::geom_rect(
        data = bands[bands$odd, , drop = FALSE],
        ggplot2::aes(xmin = -Inf, xmax = Inf, ymin = ymin, ymax = ymax),
        inherit.aes = FALSE, fill = "#F7F7F7", colour = NA
      )
      lyr_even <- ggplot2::geom_rect(
        data = bands[!bands$odd, , drop = FALSE],
        ggplot2::aes(xmin = -Inf, xmax = Inf, ymin = ymin, ymax = ymax),
        inherit.aes = FALSE, fill = "#FFFFFF", colour = NA
      )
      plot_obj$layers <- c(list(lyr_odd, lyr_even), plot_obj$layers)
      plot_obj
    }
    p <- add_decade_bands(p, c(agg$lower, agg$upper, agg$mean_val))
    p <- p + ggplot2::theme(
      panel.background = ggplot2::element_rect(fill = "grey99", colour = NA),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey82", linewidth = 0.50, linetype = "dashed"
      ),
      panel.grid.minor.y = ggplot2::element_line(
        colour = "grey91", linewidth = 0.28
      )
    )
  }

  annot <- list(
    title    = title_txt,
    subtitle = subtitle_txt,
    caption  = caption_txt
  )

  list(plot = p, data = agg, annot = annot)
}

## ---------------------------------------------------------------------------
## fig_cpu_generation_energy_by_model -- CPU-only energy vs model with
## quantizations side by side and CPU generation encoded by marker shape.
## x = model, colour = quantization, shape = Intel / AMD.
## ---------------------------------------------------------------------------
fig_cpu_generation_energy_by_model <- function(metrics, energy = "total_energy_j",
                                               energy_label = "Total energy [J]",
                                               response_name = "Total energy",
                                               log_y = FALSE,
                                               ci_level = 0.95) {
  req <- c(energy, "cpu_arch", "model", "quant")
  if (length(setdiff(req, names(metrics))))
    return(list(plot = NULL, data = NULL))

  cpu_levels   <- c("Intel", "AMD")
  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")

  d_all <- metrics[
    !is.na(metrics$cpu_arch) & !is.na(metrics$model) & !is.na(metrics$quant) &
      as.character(metrics$cpu_arch) %in% cpu_levels &
      as.character(metrics$model) %in% model_levels &
      as.character(metrics$quant) %in% quant_levels &
      is.finite(metrics[[energy]]), , drop = FALSE]
  d <- d_all
  scope_txt <- "all runs with CPU architecture metadata"
  if ("exec_mode" %in% names(d_all)) {
    d_cpu <- d_all[as.character(d_all$exec_mode) == "CPU", , drop = FALSE]
    present_cpu_cpu_only <- unique(as.character(d_cpu$cpu_arch))
    if (length(intersect(cpu_levels, present_cpu_cpu_only)) >= 2L) {
      d <- d_cpu
      scope_txt <- "CPU-only runs"
    }
  }
  if (!nrow(d)) return(list(plot = NULL, data = NULL))

  present_cpu    <- cpu_levels[cpu_levels %in% unique(as.character(d$cpu_arch))]
  present_models <- model_levels[model_levels %in% unique(as.character(d$model))]
  present_quants <- quant_levels[quant_levels %in% unique(as.character(d$quant))]
  if (!length(present_cpu) || !length(present_models) || !length(present_quants))
    return(list(plot = NULL, data = NULL))

  d$cpu_arch <- factor(d$cpu_arch, levels = present_cpu)
  d$model    <- factor(d$model, levels = present_models)
  d$quant    <- factor(d$quant, levels = present_quants)

  ci_level <- suppressWarnings(as.numeric(ci_level))[1]
  if (!is.finite(ci_level) || ci_level <= 0 || ci_level >= 1)
    ci_level <- 0.95
  ci_tail_prob <- (1 + ci_level) / 2

  agg <- d |>
    dplyr::group_by(cpu_arch, model, quant) |>
    dplyr::summarise(
      n        = dplyr::n(),
      mean_val = mean(.data[[energy]], na.rm = TRUE),
      sd       = dplyr::if_else(n > 1L, stats::sd(.data[[energy]], na.rm = TRUE), NA_real_),
      se       = dplyr::if_else(n > 1L, sd / sqrt(n), NA_real_),
      tcrit    = dplyr::if_else(n > 1L, stats::qt(ci_tail_prob, pmax(n - 1L, 1L)), NA_real_),
      .groups  = "drop"
    ) |>
    dplyr::mutate(
      lower = mean_val - tcrit * se,
      upper = mean_val + tcrit * se
    )

  if (!isTRUE(log_y))
    agg$lower <- pmax(agg$lower, 0)
  if (isTRUE(log_y))
    agg$lower <- pmax(agg$lower, agg$mean_val * 1e-3)

  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.30
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)),
                    present_quants)
  else stats::setNames(0, present_quants)
  c_span    <- 0.06
  cpu_off   <- if (length(present_cpu) > 1L)
    stats::setNames(seq(-c_span, c_span, length.out = length(present_cpu)),
                    present_cpu)
  else stats::setNames(0, present_cpu)

  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)]) +
           unname(cpu_off[as.character(agg$cpu_arch)])

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  cpu_shapes <- c("Intel" = 21, "AMD" = 24)[present_cpu]

  title_txt <- sprintf(
    "CPU-generation Effects on %s by Model and Quantization%s",
    response_name,
    if (isTRUE(log_y)) " (log scale)" else ""
  )
  subtitle_txt <- sprintf(
    paste0("%s (Intel/AMD). Means across repetitions (n = %d runs); ",
           "error bars = %s%% CI. Colour = quantization, shape = CPU generation.%s"),
    scope_txt,
    nrow(d),
    format(round(ci_level * 100), trim = TRUE, scientific = FALSE),
    if (isTRUE(log_y)) sprintf(" %s on a log10 y-axis.", response_name) else ""
  )
  caption_txt <- "Within each model, markers are ordered by quantization and separated by CPU generation."

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean_val)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3
    ) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower, ymax = upper, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE
    ) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = cpu_arch),
      colour = "grey25", size = 2.6, stroke = 0.5
    ) +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(
        order = 1, nrow = 1, byrow = TRUE,
        override.aes = list(shape = 21, size = 3.2)
      )
    ) +
    ggplot2::scale_shape_manual(
      values = cpu_shapes, name = "CPU generation",
      guide = ggplot2::guide_legend(
        order = 2, nrow = 1, byrow = TRUE,
        override.aes = list(fill = "grey40", size = 3.2)
      )
    ) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))
    ) +
    ggplot2::labs(x = "Model", y = energy_label) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "top",
      legend.box = "horizontal",
      legend.direction = "horizontal",
      legend.justification = "center",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"
      ),
      axis.text.x   = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8))
    )

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

  annot <- list(
    title    = title_txt,
    subtitle = subtitle_txt,
    caption  = caption_txt
  )

  list(plot = p, data = agg, annot = annot)
}

## ---------------------------------------------------------------------------
## fig_energy_vs_throughput -- Total energy vs generation throughput, with CPU
## (top) and GPU (bottom) split into two stacked sub-panels (own axes each).
## Each point is one configuration mean (model x quant x exec_mode x hardware)
## across repetitions; colour = quantization, shape = execution mode. Thin 95%
## confidence intervals are drawn on both axes when a cell has repetitions.
## ---------------------------------------------------------------------------
fig_energy_vs_throughput <- function(metrics, energy = "total_energy_j",
                                     energy_label = "Total energy (J)",
                                     tput = "tokens_per_sec",
                                     tput_label = "Throughput [tok/s]",
                                     aggregate = TRUE,
                                     pareto = FALSE,
                                     seed = 20260717) {
  req <- c(energy, tput, "exec_mode", "quant", "model")
  if (length(setdiff(req, names(metrics))))
    return(list(plot = NULL, data = NULL))

  exec_levels  <- c("CPU", "GPU")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")

  d <- metrics[
    !is.na(metrics$exec_mode) & !is.na(metrics$quant) & !is.na(metrics$model) &
      as.character(metrics$exec_mode) %in% exec_levels &
      as.character(metrics$quant) %in% quant_levels &
      is.finite(metrics[[energy]]) & is.finite(metrics[[tput]]), , drop = FALSE]
  if (!nrow(d)) return(list(plot = NULL, data = NULL))

  present_quants <- quant_levels[quant_levels %in% unique(as.character(d$quant))]
  present_exec   <- exec_levels[exec_levels %in% unique(as.character(d$exec_mode))]

  d$quant     <- factor(d$quant, levels = present_quants)
  d$exec_mode <- factor(d$exec_mode, levels = present_exec)

  ## Configuration grouping: hardware is included when present so each point is
  ## a single (model, quant, exec_mode, hardware) cell.
  group_cols <- c("model", "quant", "exec_mode",
                  if ("hardware" %in% names(d)) "hardware")

  ci_half <- function(x) {
    x <- x[is.finite(x)]; n <- length(x)
    if (n > 1L) stats::qt(0.975, n - 1L) * stats::sd(x) / sqrt(n) else NA_real_
  }

  if (isTRUE(aggregate)) {
    plot_df <- d |>
      dplyr::group_by(dplyr::across(dplyr::all_of(group_cols))) |>
      dplyr::summarise(
        n        = dplyr::n(),
        energy_m = mean(.data[[energy]], na.rm = TRUE),
        energy_e = ci_half(.data[[energy]]),
        tput_m   = mean(.data[[tput]], na.rm = TRUE),
        tput_e   = ci_half(.data[[tput]]),
        .groups  = "drop"
      ) |>
      dplyr::mutate(
        energy_lo = energy_m - energy_e, energy_hi = energy_m + energy_e,
        tput_lo   = tput_m   - tput_e,   tput_hi   = tput_m   + tput_e
      )
  } else {
    ## Raw per-run scatter: one point per run, no averaging and no intervals.
    plot_df <- d
    plot_df$energy_m <- plot_df[[energy]]
    plot_df$tput_m   <- plot_df[[tput]]
  }

  ## Pareto frontier (minimise energy AND maximise throughput), computed per
  ## execution mode so each facet gets its own non-dominated front. A point is
  ## kept when no other point has both higher throughput and lower energy.
  front_df <- NULL
  if (isTRUE(pareto)) {
    pareto_front <- function(df) {
      o <- df[order(-df$tput_m, df$energy_m), , drop = FALSE]
      keep <- logical(nrow(o)); min_e <- Inf
      for (i in seq_len(nrow(o))) {
        if (is.finite(o$energy_m[i]) && o$energy_m[i] < min_e) {
          keep[i] <- TRUE; min_e <- o$energy_m[i]
        }
      }
      o <- o[keep, , drop = FALSE]
      o[order(o$tput_m), , drop = FALSE]
    }
    front_df <- do.call(rbind, lapply(
      split(plot_df, droplevels(plot_df$exec_mode)), pareto_front))
  }

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  exec_shapes  <- c("CPU" = 21, "GPU" = 24)[present_exec]

  ## Title / subtitle / caption -- kept OUT of the plot; emitted to the sidecar.
  title_txt <- "Energy vs Throughput (CPU top, GPU bottom)"
  subtitle_txt <- if (isTRUE(aggregate)) sprintf(
    paste0("Each point is a configuration mean (model x quant x exec x hardware; ",
           "n = %d runs); error bars = 95%% CI on both axes. Colour = ",
           "quantization, shape = execution mode; CPU (top) and GPU (bottom) ",
           "on separate axes."),
    nrow(d)
  ) else sprintf(
    paste0("Each point is a single run (n = %d runs); no averaging or intervals. ",
           "Colour = quantization, shape = execution mode; CPU (top) and GPU ",
           "(bottom) on separate axes."),
    nrow(d)
  )
  if (isTRUE(pareto))
    subtitle_txt <- paste(subtitle_txt,
      "The grey line marks the per-panel Pareto frontier (minimise energy, maximise throughput).")
  caption_txt <- "Execution mode is read from the marker shape (circle = CPU-only, triangle = GPU-only)."

  p <- ggplot2::ggplot(plot_df, ggplot2::aes(x = tput_m, y = energy_m)) +
    (if (isTRUE(aggregate)) ggplot2::geom_errorbar(
      ggplot2::aes(ymin = energy_lo, ymax = energy_hi, colour = quant),
      width = 0, linewidth = 0.4, na.rm = TRUE, show.legend = FALSE
    ) else NULL) +
    (if (isTRUE(aggregate)) ggplot2::geom_errorbar(
      ggplot2::aes(xmin = tput_lo, xmax = tput_hi, colour = quant),
      orientation = "y", width = 0, linewidth = 0.4, na.rm = TRUE, show.legend = FALSE
    ) else NULL) +
    (if (isTRUE(pareto)) ggplot2::geom_line(
      data = front_df, ggplot2::aes(x = tput_m, y = energy_m),
      colour = "grey40", linewidth = 0.7, na.rm = TRUE
    ) else NULL) +
    (if (isTRUE(pareto)) ggplot2::geom_point(
      data = front_df, ggplot2::aes(x = tput_m, y = energy_m),
      shape = 1, size = 4.6, stroke = 0.8, colour = "grey20", na.rm = TRUE
    ) else NULL) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = exec_mode),
      colour = "grey25", size = 2.8, stroke = 0.5
    ) +
    ggplot2::facet_wrap(~ exec_mode, ncol = 1, scales = "free") +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(order = 1, override.aes = list(shape = 21, size = 3.2))
    ) +
    ggplot2::scale_shape_manual(
      values = exec_shapes, name = "Execution mode",
      guide = ggplot2::guide_legend(order = 2, override.aes = list(fill = "grey40", size = 3.2))
    ) +
    ggplot2::scale_x_continuous(labels = scales::label_comma(),
                                expand = ggplot2::expansion(mult = c(0.03, 0.06))) +
    ggplot2::scale_y_continuous(labels = scales::label_comma(),
                                expand = ggplot2::expansion(mult = c(0.03, 0.08))) +
    ggplot2::labs(x = tput_label, y = energy_label) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "bottom",
      legend.box = "horizontal",
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(
        colour = "grey90", linewidth = 0.35
      ),
      strip.text       = ggplot2::element_blank(),
      strip.background = ggplot2::element_blank(),
      axis.title.x  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8))
    )

  annot <- list(
    title    = title_txt,
    subtitle = subtitle_txt,
    caption  = caption_txt
  )

  list(plot = p, data = plot_df, annot = annot)
}

## ---------------------------------------------------------------------------
## Pareto-optimal configurations table -- non-dominated points for
## "maximise throughput AND minimise total PSU energy" over configuration-level
## means (model x quant x exec_mode x gpu_arch). Sorted by throughput along the
## front. Returns a compact data.frame (NULL if the metrics are unavailable).
## ---------------------------------------------------------------------------
pareto_optimal_table <- function(metrics, energy = "total_energy_j",
                                 tput = "tokens_per_sec") {
  if (!all(c(energy, tput, "model", "quant", "exec_mode", "gpu_arch") %in%
           names(metrics)))
    return(NULL)
  d <- metrics[is.finite(metrics[[energy]]) & is.finite(metrics[[tput]]), ,
               drop = FALSE]
  if (!nrow(d)) return(NULL)
  keys <- c("model", "quant", "exec_mode", "gpu_arch")
  grp <- interaction(d[keys], drop = TRUE, sep = "\r")
  meanf <- function(x) { x <- x[is.finite(x)]; if (length(x)) mean(x) else NA_real_ }
  agg <- do.call(rbind, lapply(split(d, grp), function(p) data.frame(
    model              = as.character(p$model[1]),
    quant              = as.character(p$quant[1]),
    exec_mode          = as.character(p$exec_mode[1]),
    gpu_arch           = as.character(p$gpu_arch[1]),
    tokens_per_sec     = meanf(p[[tput]]),
    total_energy_j     = meanf(p[[energy]]),
    energy_per_token_j = if ("energy_per_token_j" %in% names(p))
      meanf(p$energy_per_token_j) else NA_real_,
    tokens_per_joule   = if ("tokens_per_joule" %in% names(p))
      meanf(p$tokens_per_joule) else NA_real_,
    n_reps             = sum(is.finite(p[[energy]])),
    stringsAsFactors = FALSE)))
  rownames(agg) <- NULL

  front <- pareto_frontier_maxx(agg, x = "tokens_per_sec", y = "total_energy_j")
  if (!nrow(front)) return(NULL)
  front <- front[order(front$tokens_per_sec), , drop = FALSE]
  for (c0 in c("tokens_per_sec", "total_energy_j", "energy_per_token_j",
               "tokens_per_joule"))
    front[[c0]] <- round(front[[c0]], 4)
  rownames(front) <- NULL
  front
}

## ---------------------------------------------------------------------------
## fig_gpu_generation_energy_quant -- Datacenter GPU comparison stacked in three
## panels (V100 top, A100 middle, H100 bottom). Within every panel: x = model,
## y = total PSU energy, one point per quantization (mean across repetitions,
## 95% CI whisker). GPU-only runs only. Lets the per-quantization energy spread
## be read within each generation while the stacked layout keeps the three
## generations aligned on a common model axis.
## ---------------------------------------------------------------------------
fig_gpu_generation_energy_quant <- function(metrics, energy = "total_energy_j",
                                            energy_label = "Total energy (J)") {
  req <- c(energy, "hardware", "model", "quant", "exec_mode")
  if (length(setdiff(req, names(metrics))))
    return(list(plot = NULL, data = NULL))

  gpu_levels   <- c("V100", "A100", "H100")
  model_levels <- c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                    "Gemma-2-9B", "Mixtral-8x7B")
  quant_levels <- c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0", "FP16")

  d <- metrics[
    !is.na(metrics$hardware) & !is.na(metrics$model) & !is.na(metrics$quant) &
      !is.na(metrics$exec_mode) &
      as.character(metrics$hardware) %in% gpu_levels &
      as.character(metrics$exec_mode) == "GPU-only" &
      as.character(metrics$model) %in% model_levels &
      as.character(metrics$quant) %in% quant_levels &
      is.finite(metrics[[energy]]), , drop = FALSE]
  if (!nrow(d)) return(list(plot = NULL, data = NULL))

  present_gpu    <- gpu_levels[gpu_levels %in% unique(as.character(d$hardware))]
  present_models <- model_levels[model_levels %in% unique(as.character(d$model))]
  present_quants <- quant_levels[quant_levels %in% unique(as.character(d$quant))]

  d$hardware <- factor(d$hardware, levels = present_gpu)
  d$model    <- factor(d$model,    levels = present_models)
  d$quant    <- factor(d$quant,    levels = present_quants)

  ## Mean + 95% CI across repetitions per (hardware, model, quant).
  agg <- d |>
    dplyr::group_by(hardware, model, quant) |>
    dplyr::summarise(
      n        = dplyr::n(),
      mean_val = mean(.data[[energy]], na.rm = TRUE),
      sd       = dplyr::if_else(n > 1L, stats::sd(.data[[energy]], na.rm = TRUE), NA_real_),
      se       = dplyr::if_else(n > 1L, sd / sqrt(n), NA_real_),
      tcrit    = dplyr::if_else(n > 1L, stats::qt(0.975, pmax(n - 1L, 1L)), NA_real_),
      .groups  = "drop"
    ) |>
    dplyr::mutate(
      lower = mean_val - tcrit * se,
      upper = mean_val + tcrit * se
    )

  ## x positions: model cluster -> quantization side-by-side offset.
  model_pos <- stats::setNames(seq_along(present_models), present_models)
  q_span    <- 0.30
  quant_off <- if (length(present_quants) > 1L)
    stats::setNames(seq(-q_span, q_span, length.out = length(present_quants)), present_quants)
  else stats::setNames(0, present_quants)

  agg$x <- unname(model_pos[as.character(agg$model)]) +
           unname(quant_off[as.character(agg$quant)])

  quant_colors <- c("Q2_K" = "#E64B35", "Q4_K_M" = "#EFAF00", "Q5_K_M" = "#4DAF4A",
                    "Q6_K" = "#377EB8", "Q8_0" = "#984EA3", "FP16" = "#8C564B")[present_quants]
  ## Per-generation marker glyphs: V100 circle, A100 triangle, H100 square.
  gpu_shapes <- c("V100" = 21, "A100" = 24, "H100" = 22)[present_gpu]

  title_txt <- "Datacenter GPU Generation Effect on Energy by Quantization (V100 / A100 / H100)"
  subtitle_txt <- sprintf(
    paste0("GPU-only runs; each point = mean total PSU energy across repetitions ",
           "(n = %d runs); error bars = 95%% CI. Colour = quantization, shape = GPU."),
    nrow(d)
  )
  caption_txt <- "Panels top-to-bottom: V100 (circle), A100 (triangle), H100 (square). Within each model, points are offset by quantization."

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = x, y = mean_val)) +
    ggplot2::geom_vline(
      xintercept = seq(1.5, length(present_models) - 0.5, by = 1),
      colour = "grey92", linewidth = 0.3
    ) +
    ggplot2::geom_errorbar(
      ggplot2::aes(ymin = lower, ymax = upper, colour = quant),
      width = 0.04, linewidth = 0.5, na.rm = TRUE, show.legend = FALSE
    ) +
    ggplot2::geom_point(
      ggplot2::aes(fill = quant, shape = hardware),
      colour = "grey25", size = 2.6, stroke = 0.5
    ) +
    ggplot2::facet_wrap(~hardware, ncol = 1, scales = "free_y") +
    ggplot2::scale_colour_manual(values = quant_colors, guide = "none") +
    ggplot2::scale_fill_manual(
      values = quant_colors, name = "Quantization",
      guide = ggplot2::guide_legend(order = 1, override.aes = list(shape = 21, size = 3.2))
    ) +
    ggplot2::scale_shape_manual(
      values = gpu_shapes, name = "GPU generation",
      guide = ggplot2::guide_legend(order = 2, override.aes = list(fill = "grey40", size = 3.2))
    ) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(present_models), labels = present_models,
      limits = c(0.4, length(present_models) + 0.6),
      expand = ggplot2::expansion(mult = c(0, 0))
    ) +
    ggplot2::scale_y_continuous(
      labels = scales::label_comma(),
      expand = ggplot2::expansion(mult = c(0.06, 0.10))
    ) +
    ggplot2::labs(x = "Model", y = energy_label) +
    theme_pub(base_size = 13) +
    ggplot2::theme(
      legend.position = "bottom",
      legend.box = "horizontal",
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = "grey86", linewidth = 0.45, linetype = "dashed"
      ),
      strip.text       = ggplot2::element_blank(),
      strip.background = ggplot2::element_blank(),
      axis.text.x   = ggplot2::element_text(size = 9.5, face = "bold", colour = "grey20"),
      axis.title.x  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(t = 10)),
      axis.title.y  = ggplot2::element_text(face = "bold", margin = ggplot2::margin(r = 8))
    )

  annot <- list(
    title    = title_txt,
    subtitle = subtitle_txt,
    caption  = caption_txt
  )

  list(plot = p, data = agg, annot = annot)
}
