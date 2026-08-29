## functions/helpers.R ---------------------------------------------------------
## Cross-cutting utilities: configuration loading, package management with base-R
## fallbacks, factor handling, provenance stamping and reproducible output writers
## (CSV / RDS / JSON / PNG / PDF). Sourced first by run_analysis.R.
## ---------------------------------------------------------------------------

## Headless HPC nodes have no X11; route bitmap rendering through cairo.
if (isTRUE(capabilities("cairo"))) options(bitmapType = "cairo")

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || all(is.na(a))) b else a

## ---------------------------------------------------------------------------
## Library paths + package loading (graceful degradation)
## ---------------------------------------------------------------------------
.setup_libpaths <- function() {
  user_libs <- c(
    file.path(path.expand("~"), ".local", "programs", "R-libs-stats"),
    file.path(path.expand("~"), ".local", "programs", "R-libs", "4.5.0")
  )
  .libPaths(c(user_libs[dir.exists(user_libs)], .libPaths()))
}

has_pkg <- function(p) requireNamespace(p, quietly = TRUE)

## Attach the hard-required wrangling/plotting stack; record optional-package
## availability so downstream code can fall back to base R when they are absent.
load_dependencies <- function() {
  .setup_libpaths()
  suppressWarnings(suppressMessages({
    for (p in c("ggplot2", "dplyr", "tidyr", "tibble", "scales"))
      if (has_pkg(p)) library(p, character.only = TRUE)
  }))
  ## Resolve the common dplyr::select vs MASS::select clash up front.
  if (has_pkg("dplyr")) assign("select", dplyr::select, envir = .GlobalEnv)
  HAS <<- list(
    car          = has_pkg("car"),
    emmeans      = has_pkg("emmeans"),
    multcomp     = has_pkg("multcomp"),
    effectsize   = has_pkg("effectsize"),
    FSA          = has_pkg("FSA"),
    randomForest = has_pkg("randomForest"),
    yaml         = has_pkg("yaml"),
    jsonlite     = has_pkg("jsonlite"),
    patchwork    = has_pkg("patchwork"),
    ggrepel      = has_pkg("ggrepel"),
    nortest      = has_pkg("nortest")
  )
  invisible(HAS)
}

## ---------------------------------------------------------------------------
## Configuration
## ---------------------------------------------------------------------------
## Load config.yml into the global CFG environment. Falls back to an embedded
## default when the yaml package or the file itself is unavailable.
load_config <- function(config_path, project_root) {
  cfg <- if (has_pkg("yaml") && file.exists(config_path)) {
    yaml::read_yaml(config_path)
  } else {
    warning("yaml package or config.yml missing -- using built-in defaults")
    .default_config()
  }

  ## Resolve relative paths against the project root.
  abspath <- function(p) if (is.null(p)) NULL else
    if (grepl("^(/|[A-Za-z]:)", p)) p else file.path(project_root, p)
  for (k in names(cfg$paths)) cfg$paths[[k]] <- abspath(cfg$paths[[k]])

  cfg$project_root <- project_root
  cfg$run_date     <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  cfg$software_version <- cfg$reproducibility$software_version %||%
    paste0("R ", getRversion())
  CFG <<- cfg
  invisible(cfg)
}

.default_config <- function() {
  list(
    paths = list(input_dir = "data", results_dir = "results/numerical_data",
                 figures_dir = "results/figures", tables_dir = "results/tables",
                 reports_dir = "results"),
    reproducibility = list(seed = 20260707, pipeline_version = "2.0.0",
                           software_version = NULL),
    design = list(factors = c("hardware", "model", "quant"),
                  facet_factors = c("exec_mode", "gpu_arch", "cpu_arch"),
                  replicate_id = "run_id",
                  levels = list(
                    quant = c("Q2_K", "Q4_K_M", "Q5_K_M", "Q6_K", "Q8_0"),
                    model = c("Phi-3.5-mini-3.8B", "Mistral-7B", "Llama-3.1-8B",
                              "Gemma-2-9B", "Mixtral-8x7B"),
                    hardware = c("AMD", "Intel", "V100", "A100", "H100"),
                    exec_mode = c("CPU-only", "GPU-only", "CPU-GPU"),
                    gpu_arch = c("None", "V100", "A100", "H100")),
                  exclude_q2k = FALSE, min_replicates = 2),
    metadata_fields = c("model", "quant", "exec_mode", "cpu_arch", "gpu_arch",
                        "gpu_model", "prompt", "prompt_tokens", "generated_tokens",
                        "context_size", "batch_size", "n_threads",
                        "llamacpp_version", "cuda_version", "timestamp"),
    metrics = list(primary = "total_energy_j",
                   keep = c("total_energy_j", "energy_adj_j",
                            "total_energy_socket_j", "energy_adj_socket_j",
                            "exec_time_s", "avg_socket_power_w", "avg_psu_power_w",
                            "peak_socket_power_w", "peak_psu_power_w",
                            "tokens_per_sec", "energy_per_token_j",
                            "tokens_per_joule", "avg_cpu_freq_mhz",
                            "avg_cpu_util_pct", "avg_gpu_util_pct",
                            "avg_gpu_power_w", "gpu_mem_util_pct"),
                   labels = list()),
    energy = list(method = "trapezoid", system_rail = "psu",
                  recompute_from_samples = TRUE),
    stats = list(alpha = 0.05, anova_type = 2, normality_test = "shapiro",
                 homogeneity_test = "levene",
                 bootstrap = list(enabled = TRUE, n_resamples = 2000,
                                  conf_level = 0.95),
                 correlation = list(method = "spearman",
                                    hide_below_abs_r = 0.30, cluster = TRUE)),
    figures = list(formats = c("png", "pdf"), dpi = 300, save_data = TRUE,
                   width_in = 7.5, height_in = 5.0,
                   pareto_minimize = c("exec_time_s", "total_energy_j")),
    diagnostics = list(enabled = FALSE)
  )
}

## Human-readable label for a metric key.
lab <- function(v) {
  labs <- CFG$metrics$labels
  vapply(v, function(x) {
    if (!is.null(labs[[x]])) labs[[x]] else x
  }, character(1), USE.NAMES = FALSE)
}

## ---------------------------------------------------------------------------
## Output directories
## ---------------------------------------------------------------------------
init_dirs <- function() {
  for (d in c(CFG$paths$results_dir, CFG$paths$figures_dir,
              CFG$paths$tables_dir, CFG$paths$reports_dir))
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
  invisible(TRUE)
}

## ---------------------------------------------------------------------------
## Factor coercion
## ---------------------------------------------------------------------------
## Derive the unified `hardware` factor: the specific compute device that defines
## a design cell -- the GPU architecture for GPU runs, the CPU architecture
## otherwise. A repetition is one run of a given hardware x model x quant cell.
derive_hardware <- function(df) {
  if ("hardware" %in% names(df) ||
      !all(c("cpu_arch", "gpu_arch") %in% names(df)))
    return(df)
  is_gpu <- !is.na(df$gpu_arch) &
    !df$gpu_arch %in% c("None", "none", "", "Unknown", "NA")
  df$hardware <- ifelse(is_gpu, as.character(df$gpu_arch),
                        as.character(df$cpu_arch))
  df
}

## Coerce the design factors to ordered levels declared in the config, keeping
## only levels actually observed in the data.
coerce_factors <- function(df) {
  ## Normalise execution-mode labels: the raw data stores "CPU-only"/"GPU-only"
  ## but the canonical (config) levels are "CPU"/"GPU". Strip the "-only" suffix
  ## so every downstream table, figure and legend shows "CPU" / "GPU".
  if ("exec_mode" %in% names(df))
    df$exec_mode <- sub("-only$", "", as.character(df$exec_mode))
  lv <- CFG$design$levels
  set_factor <- function(col) {
    if (!col %in% names(df)) return(df[[col]])
    want <- lv[[col]]
    if (is.null(want)) return(factor(df[[col]]))
    present <- want[want %in% unique(df[[col]])]
    extra   <- setdiff(unique(df[[col]]), present)
    factor(df[[col]], levels = c(present, extra))
  }
  for (col in c("hardware", "exec_mode", "model", "quant", "gpu_arch", "cpu_arch"))
    if (col %in% names(df)) df[[col]] <- set_factor(col)
  df
}

## ---------------------------------------------------------------------------
## Provenance
## ---------------------------------------------------------------------------
## Build the provenance record stamped on every figure and report. `n` is the
## sample size, `reps` the number of repetitions relevant to the output.
provenance <- function(n = NA_integer_, reps = NA_integer_, extra = list()) {
  c(list(
    software_version = CFG$software_version,
    pipeline_version = CFG$reproducibility$pipeline_version %||% NA,
    date             = CFG$run_date,
    sample_size      = n,
    repetitions      = reps,
    seed             = CFG$reproducibility$seed %||% NA
  ), extra)
}

## Compact one-line caption used as a figure footer.
provenance_caption <- function(prov) {
  sprintf("%s | %s | n=%s, reps=%s | seed=%s",
          prov$software_version, prov$date,
          prov$sample_size %||% "NA", prov$repetitions %||% "NA",
          prov$seed %||% "NA")
}

## ---------------------------------------------------------------------------
## Reproducible writers
## ---------------------------------------------------------------------------
write_json <- function(obj, path) {
  if (has_pkg("jsonlite")) {
    jsonlite::write_json(obj, path, pretty = TRUE, auto_unbox = TRUE, na = "null")
  } else {
    ## Minimal fallback: flat key/value dump.
    con <- file(path, "w"); on.exit(close(con))
    writeLines(paste0("{\n",
      paste(sprintf('  "%s": "%s"', names(unlist(obj)), unlist(obj)),
            collapse = ",\n"), "\n}"), con)
  }
  invisible(path)
}

## Evaluate `expr` while muffling car's cosmetic printHypothesis warning, which
## fires whenever coefficient/level names contain '-' or other arithmetic-like
## characters (e.g. "Llama-3.1-8B"). Only that specific warning is suppressed.
mute_hypothesis_warning <- function(expr) {
  withCallingHandlers(expr, warning = function(w) {
    if (grepl("printHypothesis|arithmetic operators", conditionMessage(w)))
      invokeRestart("muffleWarning")
  })
}

## Write a results table as CSV (+ RDS + JSON) into results_dir.
write_result <- function(df, name) {
  if (is.null(df) || !nrow(df)) {
    message(sprintf("  [skip] %s: no rows", name)); return(invisible(NULL))
  }
  base <- file.path(CFG$paths$results_dir, name)
  utils::write.csv(df, paste0(base, ".csv"), row.names = FALSE)
  saveRDS(df, paste0(base, ".rds"))
  write_json(df, paste0(base, ".json"))
  invisible(base)
}

## Save a figure to every configured raster/vector format, plus its underlying
## data (.csv) written into the `csv_files/` subdirectory of figures_dir.
save_fig <- function(plot, name, data = NULL, prov = provenance(),
                     width = CFG$figures$width_in, height = CFG$figures$height_in,
                     dpi = CFG$figures$dpi %||% 300, caption = FALSE) {
  base <- file.path(CFG$paths$figures_dir, name)
  ## Move the title/subtitle out of the figure into a markdown sidecar so the
  ## saved plot keeps only its axes and legends. The extracted text is captured
  ## after the plot is built, preserving any values interpolated at runtime.
  if (inherits(plot, "ggplot")) {
    ttl <- plot$labels$title
    sub <- plot$labels$subtitle
    cap <- plot$labels$caption
    if (!is.null(ttl) || !is.null(sub) || !is.null(cap)) {
      md <- c(if (!is.null(ttl)) paste0("# ", ttl),
              if (!is.null(sub)) c("", sub),
              if (!is.null(cap)) c("", cap))
      writeLines(md, paste0(base, ".md"))
    }
    plot <- plot + ggplot2::labs(title = NULL, subtitle = NULL, caption = NULL)
  }
  ## Stamp provenance as a caption if the object is a ggplot.
  if (isTRUE(caption) && inherits(plot, "ggplot")) {
    plot <- plot + ggplot2::labs(caption = provenance_caption(prov)) +
      ggplot2::theme(plot.caption = ggplot2::element_text(
        size = 7, colour = "grey40", hjust = 1))
  }
  for (fmt in (CFG$figures$formats %||% c("png", "pdf"))) {
    dev <- if (identical(fmt, "pdf")) grDevices::cairo_pdf else NULL
    suppressMessages(ggplot2::ggsave(
      filename = paste0(base, ".", fmt), plot = plot,
      width = width, height = height, units = "in", dpi = dpi,
      device = dev, bg = "white"))
  }
  ## IEEE-format vector copy: identical content and shape as above, only
  ## re-rendered at IEEE two-column width with consistent 9-10 pt typography.
  ## Saved as a vector PDF into the `ieee_format/` subdirectory. Nothing about
  ## the geometry, colours or layout changes -- only the font family/sizes and
  ## the physical width (height kept proportional to preserve the aspect ratio).
  ie <- CFG$figures$ieee
  if (isTRUE(ie$enabled) && inherits(plot, "ggplot")) {
    ieee_dir <- file.path(CFG$paths$figures_dir, ie$subdir %||% "ieee_format")
    if (!dir.exists(ieee_dir)) dir.create(ieee_dir, recursive = TRUE)
    ## Descriptive name (figure-number prefix stripped) also used to look up the
    ## per-figure single-column list and for the output filename.
    ieee_name <- sub("^figure[0-9]+[a-z]*_", "", name)
    ## Width: every figure is single-column (3.5 in) by DEFAULT; only figures
    ## explicitly listed in `ieee$double_column` are rendered at the two-column
    ## (full) width. Only the physical width changes -- content, shape and layout
    ## are untouched.
    double_names <- ie$double_column %||% character(0)
    is_double    <- length(double_names) > 0 &&
      (name %in% double_names || ieee_name %in% double_names)
    is_single    <- !is_double
    ieee_w    <- if (is_single) (ie$single_width_in %||% 3.5)
                 else            (ie$width_in %||% 7.16)
    ieee_base <- ie$font_size %||% ie$base_size %||% 9
    ieee_fam  <- ie$font_type %||% ie$family %||% "sans"
    ## Map friendly font names to R's device families ("Times"/"Times New Roman"
    ## -> serif; "Arial"/"Helvetica" -> sans) so font_type can be set naturally.
    if (grepl("^times", ieee_fam, ignore.case = TRUE))               ieee_fam <- "serif"
    else if (grepl("^(arial|helvetica)", ieee_fam, ignore.case = TRUE)) ieee_fam <- "sans"
    ## Height keeps the SAME physical value it would have at the two-column
    ## width, so a single-column figure is only narrower -- not shorter. Scaling
    ## the height with the reduced width instead would squash the panels and clip
    ## the legend (the "disproportionate" look). The aspect of the double-column
    ## reference is preserved; single-column just crops the width.
    ref_w  <- ie$width_in %||% 7.16
    ieee_h <- ref_w * (height / width)
    ## Adjust ONLY typography: font family + sizes. Every other element field
    ## (face, colour, margins) inherits from the existing theme, so content and
    ## layout are untouched; elements with an explicit size keep it.
    ieee_plot <- plot + ggplot2::theme(
      text          = ggplot2::element_text(family = ieee_fam, size = ieee_base),
      axis.title    = ggplot2::element_text(size = ieee_base),
      axis.text     = ggplot2::element_text(size = ieee_base - 1),
      axis.title.x = ggplot2::element_text(margin = ggplot2::margin(t = 1)),
      axis.title.y = ggplot2::element_text(margin = ggplot2::margin(r = 1)),
      legend.title  = ggplot2::element_text(size = ieee_base),
      legend.text   = ggplot2::element_text(size = ieee_base - 1),
      strip.text    = ggplot2::element_text(size = ieee_base),
      plot.title    = ggplot2::element_text(size = ieee_base + 1),
      plot.subtitle = ggplot2::element_text(size = ieee_base - 1),
      plot.caption  = ggplot2::element_text(size = ieee_base - 2)
    )

    ## Shrink only the point markers (squares / triangles / circles). Scales the
    ## fixed size of every GeomPoint layer; nothing else about the layers or the
    ## data changes.
    ## `point_stroke` (if set) thins (or thickens) the marker border. For the
    ## fillable shapes (21-25) the outline width is the `stroke` aesthetic, so we
    ## just set a fixed thin value on every GeomPoint layer; fill/colour/shape
    ## are left untouched.
    pt_scale  <- ie$point_scale %||% 1
    pt_stroke <- ie$point_stroke
    if (!identical(pt_scale, 1) ||
        (is.numeric(pt_stroke) && length(pt_stroke) == 1L)) {
      for (li in seq_along(ieee_plot$layers)) {
        ly <- ieee_plot$layers[[li]]
        if (!inherits(ly$geom, "GeomPoint")) next
        if (!identical(pt_scale, 1) && !is.null(ly$aes_params$size))
          ieee_plot$layers[[li]]$aes_params$size <- ly$aes_params$size * pt_scale
        if (is.numeric(pt_stroke) && length(pt_stroke) == 1L)
          ieee_plot$layers[[li]]$aes_params$stroke <- pt_stroke
      }
    }
    ## Legend key markers (circles / triangles / squares) for EVERY IEEE figure.
    ## Their shape, fill and colour are untouched -- only the `size` in each
    ## guide's override.aes is changed. When `legend_point_size` is set every
    ## legend marker is forced to that single absolute size (so all IEEE figures
    ## share the same legend point size); otherwise the markers are merely scaled
    ## by `legend_point_scale`. Guides may live either on the plot ($guides) or
    ## on individual scales (guide = guide_legend(...)), so cover both.
    lp_size   <- ie$legend_point_size
    lp_scale  <- ie$legend_point_scale %||% 0.6
    lp_stroke <- ie$point_stroke   # match the thin marker border in the legend
    ## On single-column figures the two-column legend row is too wide and gets
    ## clipped, so wrap each legend onto `sc_nrow` rows. The legends are laid out
    ## horizontally, so wrapping is controlled with `nrow` (ggplot ignores `ncol`
    ## for horizontal legends). Only the key layout reflows -- contents/order stay.
    sc_nrow <- ie$single_legend_nrow %||% 2
    ## Figures listed in `ieee$single_row_legend` keep their legend(s) on ONE
    ## horizontal row (no wrapping), overriding `single_legend_nrow` for them.
    srl_names     <- ie$single_row_legend %||% character(0)
    is_single_row <- length(srl_names) > 0 &&
      (name %in% srl_names || ieee_name %in% srl_names)
    ## Figures listed in `ieee$two_row_legend` wrap their wide legend onto TWO
    ## rows (a middle ground between the default 3 and a single row).
    trl_names   <- ie$two_row_legend %||% character(0)
    is_two_row  <- length(trl_names) > 0 &&
      (name %in% trl_names || ieee_name %in% trl_names)
    sc_wrap <- if (is_single_row) 1L else if (is_two_row) 2L else sc_nrow
    set_key <- function(g) {
      ## ggplot2 >= 4.0: guides are ggproto objects; their settings live in the
      ## `$params` list (override.aes, nrow, ...). ggplot2 <= 3.x: guides are
      ## plain lists holding the same fields directly. Handle both.
      if (inherits(g, "Guide")) {
        p <- g$params
        if (is.list(p) && is.list(p$override.aes) && is.numeric(p$override.aes$size)) {
          if (is.numeric(lp_size) && length(lp_size) == 1L)
            p$override.aes$size <- lp_size
          else
            p$override.aes$size <- p$override.aes$size * lp_scale
          if (is.numeric(lp_stroke) && length(lp_stroke) == 1L)
            p$override.aes$stroke <- lp_stroke
          if (is_single) p$nrow <- sc_wrap   # wrap wide legend onto multiple rows
          g$params <- p
        }
        return(g)
      }
      if (is.list(g) && is.list(g$override.aes) &&
          is.numeric(g$override.aes$size)) {
        if (is.numeric(lp_size) && length(lp_size) == 1L)
          g$override.aes$size <- lp_size
        else
          g$override.aes$size <- g$override.aes$size * lp_scale
        if (is.numeric(lp_stroke) && length(lp_stroke) == 1L)
          g$override.aes$stroke <- lp_stroke
        if (is_single) g$nrow <- sc_wrap   # wrap wide legend onto multiple rows
      }
      g
    }
    if ((is.numeric(lp_size) && length(lp_size) == 1L) ||
        !identical(lp_scale, 1) ||
        (is.numeric(lp_stroke) && length(lp_stroke) == 1L)) {
      if (is.list(ieee_plot$guides))
        ieee_plot$guides <- lapply(ieee_plot$guides, set_key)
      for (si in seq_along(ieee_plot$scales$scales))
        ieee_plot$scales$scales[[si]]$guide <-
          set_key(ieee_plot$scales$scales[[si]]$guide)
    }
    ieee_plot <- ieee_plot + ggplot2::theme(
      legend.spacing.y   = grid::unit(1, "pt"),
      legend.margin      = ggplot2::margin(t = 0, b = 0),
      legend.box.spacing = grid::unit(4, "pt")
    )
    ## Single-column figures: squeeze the legend as tight as possible and pin it
    ## to the left margin so the narrow width is used efficiently. Only the
    ## spacing/alignment is changed -- the legend keys, glyphs and labels are the
    ## same. Shrinks the key (glyph) box, the gap between keys and the glyph-to-
    ## label gap, and left-justifies the whole legend.
    if (is_single) {
      ieee_plot <- ieee_plot + ggplot2::theme(
        legend.justification = "left",
        legend.key.size      = grid::unit(0.55, "lines"),
        legend.key.spacing.x = grid::unit(1, "pt"),
        legend.key.spacing.y = grid::unit(1, "pt"),
        legend.text          = ggplot2::element_text(
          size = ieee_base - 1,
          margin = ggplot2::margin(l = 0, r = 2, unit = "pt")),
        legend.title         = ggplot2::element_text(
          size = ieee_base,
          margin = ggplot2::margin(r = 2, unit = "pt"))
      )
    }
    ## Figures that carry a "Quantization" legend plus a second categorical
    ## legend ("Execution mode", "GPU generation" or "Cache level"): stack the
    ## two legends on their own rows (Quantization first, the second one below).
    ## Only the legend arrangement changes -- the legends' contents, keys and the
    ## plot itself are left as-is. Single-column figures pin the rows to the left
    ## margin; wider (double-column) figures keep them centred.
    legend_names <- c(
      vapply(ieee_plot$scales$scales, function(s) {
        nm <- tryCatch(s$name, error = function(e) NULL)
        if (is.character(nm) && length(nm) == 1L) nm else NA_character_
      }, character(1)),
      unlist(ieee_plot$labels, use.names = FALSE)
    )
    secondary_legends <- c("Execution mode", "GPU generation", "Cache level")
    ## Figures listed in `ieee$inside_legend` move their legend(s) INSIDE the
    ## panel (e.g. the empty top-right corner of a scatter/pareto) instead of
    ## the stacked bottom arrangement. Position/justification are configurable.
    inside_names <- ie$inside_legend %||% character(0)
    is_inside    <- length(inside_names) > 0 &&
      (name %in% inside_names || ieee_name %in% inside_names)
    force_single_row_top <-
      grepl("^(figure2[lmno]_)?gpu_energy_by_model_quant_(linear|log)(?:_ci50)?$", name) ||
      grepl("^gpu_energy_by_model_quant_(linear|log)(?:_ci50)?$", ieee_name)

    if (!is_inside &&
        "Quantization" %in% legend_names &&
        any(secondary_legends %in% legend_names)) {
      ieee_plot <- ieee_plot + ggplot2::theme(
        legend.position      = "top",
        legend.box           = "horizontal",
        legend.title = element_blank(),        
        ## Cross-axis (vertical) alignment of the side-by-side legends: centre
        ## each legend block so a short legend (e.g. Execution mode = CPU/GPU)
        ## sits vertically centred against a taller one (e.g. Model).
        legend.box.just      = "top",
        legend.justification  = if (is_single) "center" else "center",
        ## ggplot2 >= 3.5 places bottom legends with a position-specific
        ## justification; `legend.justification` alone leaves the box centred,
        ## so pin the whole legend box to the left edge explicitly here.
        legend.justification.bottom = if (is_single) "center" else "center",
        ## Pull the two side-by-side legends together so the whole box hugs the
        ## left margin instead of stretching across the full panel width.
        legend.spacing.x     = if (is_single) grid::unit(15, "pt")
                               else            grid::unit(11, "pt"),
        legend.direction     = if (force_single_row_top) "horizontal" else "vertical",
        legend.margin          = ggplot2::margin(1, 1, 1, 1)
      ) 
    }
    ## Inside-panel legend: stack the legends vertically in a corner of the plot
    ## area (default top-right) over a light background box so they stay legible
    ## on top of the data. Only the legend placement changes.
    if (is_inside) {
      in_pos  <- ie$inside_legend_pos %||% c(0.99, 0.99)
      in_just <- ie$inside_legend_just %||% c("right", "top")
      ieee_plot <- ieee_plot + ggplot2::theme(
        legend.position        = "inside",
        legend.position.inside = c(in_pos[[1]], in_pos[[2]]),
        legend.justification.inside = c(in_just[[1]], in_just[[2]]),
        legend.box             = "horizontal",
        legend.box.just        = "left",
        legend.direction       = "horizontal",
        legend.margin          = ggplot2::margin(1, 1, 1, 1),
        legend.background      = ggplot2::element_rect(
          fill = "white", colour = "grey70", linewidth = 0.1)
      )
    }
    ## Figures listed in `ieee$top_legend` move their legend to the TOP of the
    ## plot (overriding the theme's default bottom placement). Only the legend
    ## position changes; contents and keys stay as-is.
    top_names   <- ie$top_legend %||% character(0)
    is_top      <- length(top_names) > 0 &&
      (name %in% top_names || ieee_name %in% top_names)
    if (is_top && !is_inside) {
      ieee_plot <- ieee_plot + ggplot2::theme(legend.position = "top",
        legend.box           = "horizontal",
        legend.box.just      = "top",
        legend.justification  = "center",
        legend.justification.bottom = "center",
        legend.title = element_blank()
      )
    }
    ## Drop the redundant facet strip labels (execution mode, cache level or GPU
    ## generation) on figures where that same information is already shown by a
    ## legend. Figures that rely on the strip labels alone (no matching legend)
    ## keep them. Only the strip labels are hidden; the panels are untouched.
    fc <- ieee_plot$facet
    facet_var_names <- if (!is.null(fc) && !is.null(fc$params))
      unique(c(names(fc$params$facets), names(fc$params$rows),
               names(fc$params$cols))) else character(0)
    facet_legend_map <- list(
      exec_mode = "Execution mode",
      level     = "Cache level",
      hardware  = "GPU generation",
      gpu_arch  = "GPU generation"
    )
    drop_strip <- any(vapply(names(facet_legend_map), function(fv)
      fv %in% facet_var_names && facet_legend_map[[fv]] %in% legend_names,
      logical(1)))
    if (drop_strip) {
      ieee_plot <- ieee_plot + ggplot2::theme(
        strip.text       = ggplot2::element_blank(),
        strip.background = ggplot2::element_blank()
      )
    }
    ## Shorten quantization tick/legend labels to Q<num> (Q2_K -> Q2, Q4_K_M ->
    ## Q4, ...) and cache-level legend labels to L<num> ("L1 data (L1d)" -> L1,
    ## "L2 (from L1d misses)" -> L2, ...). Only DISCRETE scales are touched, so
    ## numeric axes keep their formatting and other labels (models, exec modes)
    ## are left unchanged. When the figure actually shows quantization or cache
    ## levels, the abbreviation is recorded in a markdown sidecar next to the PDF.
    q_short <- function(v) {
      v <- as.character(v)
      ifelse(grepl("^Q[0-9]+_", v), sub("_.*$", "", v), v)
    }
    l_short <- function(v) {
      v <- as.character(v)
      ifelse(grepl("^L[0-9]", v), sub("^(L[0-9]+).*$", "\\1", v), v)
    }
    short_lab <- function(v) l_short(q_short(v))
    make_qlab <- function(prev) {
      force(prev)
      function(x) {
        v <- if (inherits(prev, "waiver") || is.null(prev)) as.character(x)
             else if (is.function(prev)) as.character(prev(x))
             else as.character(prev)
        short_lab(v)
      }
    }
    quant_levels <- CFG$design$levels$quant %||% character(0)
    shows_quant  <- ("Quantization" %in% legend_names)
    shows_cache  <- ("Cache level" %in% legend_names)
    ## Capture the FULL cache-level legend labels (e.g. "L1 data (L1d)") for the
    ## mapping note BEFORE any relabelling. Untrained scales expose no limits, so
    ## read them from the built guide data instead.
    cache_full   <- character(0)
    for (aes in c("shape", "fill", "colour", "color")) {
      gd <- tryCatch(ggplot2::get_guide_data(ieee_plot, aes),
                     error = function(e) NULL)
      if (is.data.frame(gd) && ".label" %in% names(gd)) {
        hit <- as.character(gd$.label)
        hit <- hit[grepl("^L[0-9]", hit)]
        if (length(hit)) cache_full <- union(cache_full, hit)
      }
    }
    if (length(cache_full)) shows_cache <- TRUE
    has_x_scale  <- FALSE
    for (si in seq_along(ieee_plot$scales$scales)) {
      sc <- ieee_plot$scales$scales[[si]]
      is_x <- "x" %in% sc$aesthetics
      if (inherits(sc, "ScaleDiscrete")) {
        if (is_x) has_x_scale <- TRUE
        lims <- tryCatch(sc$get_limits(), error = function(e) NULL)
        if (length(lims) && any(grepl("^Q[0-9]+_", as.character(lims))))
          shows_quant <- TRUE
        if (length(lims) && any(grepl("^L[0-9]", as.character(lims))))
          shows_cache <- TRUE
        sc$labels <- make_qlab(sc$labels)
      } else if (is.character(sc$labels) &&
                 any(grepl("^Q[0-9]+_", sc$labels))) {
        ## Continuous scale carrying a STATIC quant label vector (e.g.
        ## scale_x_continuous(labels = c("Q2_K", ...))): shorten it in place.
        if (is_x) has_x_scale <- TRUE
        shows_quant <- TRUE
        sc$labels <- q_short(sc$labels)
      } else if (is_x) {
        has_x_scale <- TRUE
      }
    }
    ## The x-axis may use the DEFAULT discrete scale (added only at build time,
    ## so not present in $scales above). Inspect the built x labels: if they are
    ## quant levels and no explicit x scale exists, attach one that shortens them.
    xl <- tryCatch(suppressWarnings(suppressMessages({
      b <- ggplot2::ggplot_build(ieee_plot)
      unlist(lapply(b$layout$panel_params, function(pp)
        if (!is.null(pp$x) && is.function(pp$x$get_labels))
          pp$x$get_labels() else NULL))
    })), error = function(e) NULL)
    x_is_quant <- length(xl) > 0 &&
      any(grepl("^Q[0-9]+(_|$)", as.character(xl)))
    if (x_is_quant) {
      shows_quant <- TRUE
      if (!has_x_scale)
        ieee_plot <- suppressMessages(
          ieee_plot + ggplot2::scale_x_discrete(labels = q_short))
    }
    note <- character(0)
    if (isTRUE(shows_quant) && length(quant_levels)) {
      qmap <- paste(sprintf("%s = %s", q_short(quant_levels), quant_levels),
                    collapse = ", ")
      note <- c(note,
        "**Quantization labels:** shortened to Q<num> on this IEEE figure.",
        "",
        paste0("Mapping: ", qmap, "."))
    }
    if (isTRUE(shows_cache) && length(cache_full)) {
      cmap <- paste(sprintf("%s = %s", l_short(cache_full), cache_full),
                    collapse = ", ")
      if (length(note)) note <- c(note, "")
      note <- c(note,
        "**Cache level labels:** shortened to L<num> on this IEEE figure.",
        "",
        paste0("Mapping: ", cmap, "."))
    }
    ## Combine the figure's "outside" markdown sidecar(s) from the main figures
    ## dir (title/subtitle/caption -- either `<base>_legend.md` written by the
    ## figure scripts, or `<base>.md` extracted from the plot labels) with the
    ## "inside" label-mapping note into ONE self-contained sidecar next to the
    ## IEEE PDF, replacing any previous mapping-only file.
    outside_md <- character(0)
    for (f in c(paste0(base, "_legend.md"), paste0(base, ".md"))) {
      if (file.exists(f)) {
        if (length(outside_md)) outside_md <- c(outside_md, "")
        outside_md <- c(outside_md, readLines(f, warn = FALSE))
      }
    }
    ieee_md <- outside_md
    if (length(note)) {
      if (length(ieee_md)) ieee_md <- c(ieee_md, "")
      ieee_md <- c(ieee_md, note)
    }
    if (length(ieee_md))
      writeLines(ieee_md, file.path(ieee_dir, paste0(ieee_name, ".md")))
    ## Long categorical x tick labels (e.g. model names) do not fit horizontally
    ## on the narrow single-column width. By DEFAULT they are wrapped onto a few
    ## short lines (no rotation); set `single_xlabel_wrap: false` to rotate them
    ## instead (`single_xlabel_angle`). `single_xlabel_wrap_width` sets the target
    ## characters per line. Wrapping breaks preferentially at hyphens/underscores
    ## /spaces so tokens like "Phi-3.5-mini-3.8B" split cleanly.
    x_wrap  <- ie$single_xlabel_wrap %||% TRUE
    wrap_w  <- ie$single_xlabel_wrap_width %||% 9
    wrap_lab <- function(v, width) {
      vapply(as.character(v), function(s) {
        if (is.na(s) || nchar(s) <= width) return(s)
        toks <- regmatches(s, gregexpr("[^-_ ]+[-_ ]?", s))[[1]]
        if (!length(toks)) return(s)
        lines <- character(0); cur <- ""
        for (t in toks) {
          if (nchar(cur) > 0 && nchar(cur) + nchar(t) > width) {
            lines <- c(lines, cur); cur <- t
          } else cur <- paste0(cur, t)
        }
        if (nchar(cur)) lines <- c(lines, cur)
        paste(sub("[ ]+$", "", lines), collapse = "\n")
      }, character(1), USE.NAMES = FALSE)
    }
    make_wrap <- function(prev, width) {
      force(prev); force(width)
      function(x) {
        v <- if (inherits(prev, "waiver") || is.null(prev)) as.character(x)
             else if (is.function(prev)) as.character(prev(x))
             else as.character(prev)
        wrap_lab(v, width)
      }
    }
    cur_x   <- ieee_plot$theme$axis.text.x
    cur_ang <- if (!is.null(cur_x) && !is.null(cur_x$angle)) cur_x$angle else 0
    cur_hj  <- if (!is.null(cur_x) && !is.null(cur_x$hjust)) cur_x$hjust else NULL
    if (is_single && cur_ang == 0) {
      xlabs <- tryCatch(suppressWarnings(suppressMessages({
        b <- ggplot2::ggplot_build(ieee_plot)
        unlist(lapply(b$layout$panel_params, function(pp)
          if (!is.null(pp$x) && is.function(pp$x$get_labels))
            pp$x$get_labels() else NULL))
      })), error = function(e) NULL)
      maxlen <- if (length(xlabs))
        suppressWarnings(max(nchar(as.character(xlabs)), na.rm = TRUE)) else 0
      if (is.finite(maxlen) &&
          maxlen > (ie$single_xlabel_maxchar %||% 6)) {
        if (isTRUE(x_wrap)) {
          ## Wrap the x labels onto multiple short lines; keep them horizontal.
          applied <- FALSE
          for (si in seq_along(ieee_plot$scales$scales)) {
            sc <- ieee_plot$scales$scales[[si]]
            if (!("x" %in% sc$aesthetics)) next
            if (inherits(sc, "ScaleDiscrete")) {
              sc$labels <- make_wrap(sc$labels, wrap_w); applied <- TRUE
            } else if (is.character(sc$labels)) {
              sc$labels <- wrap_lab(sc$labels, wrap_w); applied <- TRUE
            }
          }
          if (!applied)
            ieee_plot <- suppressMessages(ieee_plot +
              ggplot2::scale_x_discrete(labels = function(x) wrap_lab(x, wrap_w)))
        } else {
          ## Rotate instead of wrapping (opt-in).
          cur_ang <- ie$single_xlabel_angle %||% 30
          cur_hj  <- 1
        }
      }
    }
    ieee_plot <- ieee_plot + ggplot2::theme(
      axis.text.x = ggplot2::element_text(
        size = ieee_base - 1, angle = cur_ang, hjust = cur_hj),
      axis.text.y = ggplot2::element_text(size = ieee_base - 1)
    )
    ## Make EVERY axis title bold. Some figures set a non-bold axis.title.x/.y
    ## (or only a size), and that more-specific child wins over the IEEE parent
    ## element, so set the children explicitly here. Each title's existing margin
    ## is preserved and titles intentionally hidden (element_blank) stay hidden.
    mk_axis_title <- function(el) {
      if (inherits(el, "element_blank")) return(el)
      mg <- if (!is.null(el) && !is.null(el$margin)) el$margin else NULL
      ggplot2::element_text(face = "bold", size = ieee_base, margin = mg)
    }
    ieee_plot <- ieee_plot + ggplot2::theme(
      axis.title.x = mk_axis_title(ieee_plot$theme$axis.title.x),
      axis.title.y = mk_axis_title(ieee_plot$theme$axis.title.y)
    )
    ## IEEE filenames drop the leading "figure<num>" prefix, keeping only the
    ## descriptive name (e.g. figure1c_energy_vs_throughput_split ->
    ## energy_vs_throughput_split). `ieee_name` was computed above.
    suppressMessages(ggplot2::ggsave(
      filename = file.path(ieee_dir, paste0(ieee_name, ".pdf")), plot = ieee_plot,
      width = ieee_w, height = ieee_h, units = "in",
      dpi = ie$dpi %||% 600, device = grDevices::cairo_pdf, bg = "white"))
  }
  if (isTRUE(CFG$figures$save_data)) {
    if (!is.null(data)) {
      csv_dir <- file.path(CFG$paths$figures_dir, "csv_files")
      if (!dir.exists(csv_dir)) dir.create(csv_dir, recursive = TRUE)
      utils::write.csv(data, file.path(csv_dir, paste0(name, ".csv")),
                       row.names = FALSE)
    } else {
      warning(sprintf("save_fig('%s'): no data supplied -- CSV not written.",
                      name), call. = FALSE)
    }
  }
  message(sprintf("  [fig] %s", name))
  invisible(base)
}

## ---------------------------------------------------------------------------
## Publication theme + palettes
## ---------------------------------------------------------------------------
theme_pub <- function(base_size = 12) {
  ggplot2::theme_bw(base_size = base_size) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      legend.position  = "bottom",
      strip.background  = ggplot2::element_rect(fill = "grey92", colour = NA),
      plot.title        = ggplot2::element_text(face = "bold"),
      plot.subtitle     = ggplot2::element_text(colour = "grey30"))
}
scale_fill_pub <- function(...) ggplot2::scale_fill_viridis_d(...)
scale_col_pub  <- function(...) ggplot2::scale_colour_viridis_d(...)
