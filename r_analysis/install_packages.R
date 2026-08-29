#!/usr/bin/env Rscript
# Install the CRAN packages required by the R statistical layer into a
# user-writable library under ~/.local/programs. Packages already available in
# any library path are skipped. Safe to re-run.

user_lib <- file.path(path.expand("~"), ".local", "programs", "R-libs-stats")
dir.create(user_lib, showWarnings = FALSE, recursive = TRUE)
.libPaths(c(user_lib, .libPaths()))

# Packages the redesigned DSE pipeline uses. Those with graceful base-R
# fallbacks are still listed so a full install gives the richest output.
required <- c(
  "yaml",         # config.yml parsing (config-driven pipeline)
  "jsonlite",     # JSON provenance + result sidecars
  "car",          # Levene test, type-II ANOVA
  "emmeans",      # estimated marginal means, Tukey HSD contrasts
  "multcomp",     # simultaneous CIs
  "effectsize",   # partial eta^2, omega^2
  "FSA",          # Dunn post-hoc (base-R fallback provided)
  "randomForest", # factor importance (Figure 5)
  "ggplot2", "dplyr", "tidyr", "tibble",  # data wrangling + plotting
  "scales",       # aesthetics / scales
  "xtable",       # optional LaTeX booktabs tables
  "nortest"       # optional extra normality tests
)

installed <- rownames(installed.packages())
missing <- setdiff(required, installed)

if (length(missing) == 0L) {
  cat("All required packages already installed.\n")
} else {
  cat("Installing:", paste(missing, collapse = ", "), "\n")
  repos <- getOption("repos")
  if (is.null(repos) || repos["CRAN"] == "@CRAN@") {
    repos <- c(CRAN = "https://cloud.r-project.org")
  }
  install.packages(missing, lib = user_lib, repos = repos,
                   dependencies = c("Depends", "Imports", "LinkingTo"))
}

# Report final availability
installed <- rownames(installed.packages())
still_missing <- setdiff(required, installed)
if (length(still_missing)) {
  stop(
    "Could not install required packages: ", paste(still_missing, collapse = ", "),
    "\nRun ./install_dependencies.sh on Ubuntu/Debian to install compatible binary dependencies."
  )
} else {
  cat("\nAll required packages are available.\n")
}
cat("Target library:", user_lib, "\n")
