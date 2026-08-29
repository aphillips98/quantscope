## functions/heatmaps.R --------------------------------------------------------
## Figure 2 -- Design Space Heatmap. Rows = Model, Columns = Quantization, cell =
## average Total Energy, faceted by GPU architecture. Every cell is annotated.
## ---------------------------------------------------------------------------

## Aggregate the design space to mean total energy per (model, quant, gpu_arch).
heatmap_summary <- function(df, value = "total_energy_j",
                            row = "model", col = "quant", facet = "gpu_arch") {
  keys <- c(row, col, facet)
  keys <- Filter(function(k) k %in% names(df), keys)
  d <- df[is.finite(df[[value]]), , drop = FALSE]
  grp <- interaction(d[keys], drop = TRUE, sep = "\r")
  agg <- do.call(rbind, lapply(split(d, grp), function(part) {
    out <- part[1, keys, drop = FALSE]
    out$mean_value <- mean(part[[value]], na.rm = TRUE)
    out$n <- sum(is.finite(part[[value]]))
    out
  }))
  rownames(agg) <- NULL
  agg
}

fig_design_heatmap <- function(df, value = "total_energy_j",
                               row = "model", col = "quant", facet = "gpu_arch") {
  ## Collapse across the faceting factor (folded into the title) so each
  ## row x col cell is a single tile/label rather than one stacked per arch.
  agg <- heatmap_summary(df, value, row, col, facet = NULL)
  if (is.null(agg) || !nrow(agg)) return(list(plot = NULL, data = agg))

  ## Compact "k" labels: 33300 -> "33.3k", 9600 -> "9.6k".
  agg$cell_label <- sprintf("%.1fk", agg$mean_value / 1000)

  ## Column order high->low bits (Q8_0 first); rows: smallest model at top.
  col_lv <- levels(droplevels(as.factor(agg[[col]])))   # config order (asc bits)
  row_lv <- levels(droplevels(as.factor(agg[[row]])))   # config order (asc size)
  x_lim  <- rev(col_lv)                                  # Q8_0 ... Q4_K_M
  y_lim  <- rev(row_lv)                                  # first level at bottom

  ## GPU architecture(s), folded into the title instead of faceting.
  arch <- if (facet %in% names(df)) {
    fv <- df[[facet]][is.finite(df[[value]])]
    paste(sort(unique(as.character(fv))), collapse = ", ")
  } else NULL
  ttl  <- if (!is.null(arch))
    sprintf("Design space heatmap (%s)", arch) else "Design space heatmap"

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = .data[[col]], y = .data[[row]],
                                         fill = mean_value)) +
    ggplot2::geom_tile() +
    ggplot2::geom_text(ggplot2::aes(label = cell_label),
                       colour = "black", size = 3.4) +
    ggplot2::scale_fill_viridis_c(option = "D", name = "Mean total energy (J)",
      labels = scales::label_number(accuracy = 1),
      guide  = ggplot2::guide_colourbar(title.position = "right",
        barheight = ggplot2::unit(15, "lines"),
        barwidth  = ggplot2::unit(0.8, "lines"))) +
    ggplot2::scale_x_discrete(limits = x_lim, expand = c(0, 0)) +
    ggplot2::scale_y_discrete(limits = y_lim, expand = c(0, 0)) +
    ggplot2::labs(title = ttl, x = "Quantization", y = "Model") +
    theme_pub() +
    ggplot2::theme(
      legend.position   = "right",
      legend.title      = ggplot2::element_text(angle = 90, hjust = 0.5),
      axis.text.x       = ggplot2::element_text(angle = 45, hjust = 1),
      panel.grid        = ggplot2::element_blank(),
      panel.border      = ggplot2::element_blank(),
      plot.title        = ggplot2::element_text(face = "plain", hjust = 0.5,
                                                size = 15),
      plot.subtitle     = ggplot2::element_blank())
  list(plot = p, data = agg)
}

## ---------------------------------------------------------------------------
## Energy-efficiency heatmap. Rows = Model, Columns = Quantization, cell = mean
## Tokens per Joule (higher = more energy-efficient). Cells with no throughput
## data (e.g. CPU-only runs without llama.cpp logs) are simply absent.
## ---------------------------------------------------------------------------
fig_efficiency_heatmap <- function(df, value = "tokens_per_joule",
                                   row = "model", col = "quant",
                                   facet = "gpu_arch") {
  ## Collapse across the faceting factor (folded into the title) so each
  ## row x col cell is a single tile/label rather than one stacked per arch.
  agg <- heatmap_summary(df, value, row, col, facet = NULL)
  if (is.null(agg) || !nrow(agg)) return(list(plot = NULL, data = agg))

  ## Three-significant-figure labels (values are small, ~0.002-0.19 tok/J).
  agg$cell_label <- formatC(agg$mean_value, format = "f", digits = 3)

  ## Column order high->low bits (Q8_0 first); rows: smallest model at top.
  col_lv <- levels(droplevels(as.factor(agg[[col]])))
  row_lv <- levels(droplevels(as.factor(agg[[row]])))
  x_lim  <- rev(col_lv)
  y_lim  <- rev(row_lv)

  arch <- if (facet %in% names(df)) {
    fv <- df[[facet]][is.finite(df[[value]])]
    paste(sort(unique(as.character(fv))), collapse = ", ")
  } else NULL
  ttl  <- if (!is.null(arch))
    sprintf("Energy efficiency heatmap (%s)", arch) else "Energy efficiency heatmap"

  ## Choose readable label colour: dark text on bright (high) cells, white on dark.
  rng <- range(agg$mean_value, na.rm = TRUE)
  agg$txt_col <- ifelse((agg$mean_value - rng[1]) /
                          max(diff(rng), .Machine$double.eps) > 0.55,
                        "black", "white")

  p <- ggplot2::ggplot(agg, ggplot2::aes(x = .data[[col]], y = .data[[row]],
                                         fill = mean_value)) +
    ggplot2::geom_tile() +
    ggplot2::geom_text(ggplot2::aes(label = cell_label, colour = txt_col),
                       size = 3.4, show.legend = FALSE) +
    ggplot2::scale_colour_identity() +
    ggplot2::scale_fill_viridis_c(option = "D", name = "Mean tokens per joule [tok/J]",
      labels = scales::label_number(accuracy = 0.001),
      guide  = ggplot2::guide_colourbar(title.position = "right",
        barheight = ggplot2::unit(15, "lines"),
        barwidth  = ggplot2::unit(0.8, "lines"))) +
    ggplot2::scale_x_discrete(limits = x_lim, expand = c(0, 0)) +
    ggplot2::scale_y_discrete(limits = y_lim, expand = c(0, 0)) +
    ggplot2::labs(title = ttl, x = "Quantization", y = "Model") +
    theme_pub() +
    ggplot2::theme(
      legend.position   = "right",
      legend.title      = ggplot2::element_text(angle = 90, hjust = 0.5),
      axis.text.x       = ggplot2::element_text(angle = 45, hjust = 1),
      panel.grid        = ggplot2::element_blank(),
      panel.border      = ggplot2::element_blank(),
      plot.title        = ggplot2::element_text(face = "plain", hjust = 0.5,
                                                size = 15),
      plot.subtitle     = ggplot2::element_blank())
  list(plot = p, data = agg)
}
