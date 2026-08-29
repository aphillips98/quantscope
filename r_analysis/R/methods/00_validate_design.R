## 00_validate_design.R --------------------------------------------------------
## Verify the experimental design before any statistics run: required columns are
## present, factor levels match the configured design, and every non-empty design
## cell has enough repetitions. Writes a design-validation report and returns a
## summary used by the report stage.
## ---------------------------------------------------------------------------

validate_design <- function() {
  wide <- file.path(CFG$paths$input_dir, "runs_wide.csv")
  if (!file.exists(wide))
    stop("runs_wide.csv not found in ", CFG$paths$input_dir,
         " -- run the Python ETL (etl/build_dataset.py) first.")
  df <- utils::read.csv(wide, stringsAsFactors = FALSE, check.names = TRUE)
  df <- derive_hardware(df)

  factors <- CFG$design$factors
  rep_id  <- CFG$design$replicate_id
  min_rep <- CFG$design$min_replicates %||% 2

  ## --- required columns ---------------------------------------------------
  required <- c(factors, rep_id, "energy_psu_j", "exec_time_s")
  missing_cols <- setdiff(required, names(df))
  if (length(missing_cols))
    warning("missing expected columns: ", paste(missing_cols, collapse = ", "))

  ## --- factor level coverage ---------------------------------------------
  level_report <- do.call(rbind, lapply(factors, function(f) {
    observed <- if (f %in% names(df)) sort(unique(df[[f]])) else character(0)
    expected <- CFG$design$levels[[f]] %||% observed
    data.frame(factor = f,
               expected_levels = paste(expected, collapse = "|"),
               observed_levels = paste(observed, collapse = "|"),
               n_observed = length(observed),
               unexpected = paste(setdiff(observed, expected), collapse = "|"),
               stringsAsFactors = FALSE)
  }))

  ## --- replication per design cell ---------------------------------------
  present_factors <- Filter(function(f) f %in% names(df), factors)
  cell <- interaction(df[present_factors], drop = TRUE, sep = " x ")
  cell_counts <- as.data.frame(table(cell), stringsAsFactors = FALSE)
  names(cell_counts) <- c("cell", "n_runs")
  cell_counts$balanced <- cell_counts$n_runs >= min_rep
  cell_counts <- cell_counts[order(cell_counts$n_runs), , drop = FALSE]

  n_cells <- nrow(cell_counts)
  n_under <- sum(!cell_counts$balanced)
  balanced <- n_under == 0 &&
    length(unique(cell_counts$n_runs)) == 1

  summary <- list(
    n_runs = nrow(df),
    n_cells = n_cells,
    min_reps = if (n_cells) min(cell_counts$n_runs) else NA,
    max_reps = if (n_cells) max(cell_counts$n_runs) else NA,
    under_replicated_cells = n_under,
    fully_balanced = balanced,
    missing_columns = missing_cols
  )

  write_result(level_report, "design_factor_levels")
  write_result(cell_counts, "design_cell_replication")

  message(sprintf("[00] design: %d runs, %d cells, reps %s-%s, %d under-replicated (< %d), balanced=%s",
                  summary$n_runs, summary$n_cells, summary$min_reps,
                  summary$max_reps, n_under, min_rep, balanced))
  list(summary = summary, levels = level_report, cells = cell_counts)
}
