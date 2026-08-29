#!/usr/bin/env bash
# Bootstrap R itself and the CRAN packages needed by this analysis project.
# Usage: ./install_dependencies.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Unsupported package manager. Install R (including Rscript) manually, then run:" >&2
  echo "  Rscript '$root/install_packages.R'" >&2
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  apt=(apt-get)
elif command -v sudo >/dev/null 2>&1; then
  apt=(sudo apt-get)
else
  echo "Administrator privileges are required to install R. Re-run with sudo." >&2
  exit 1
fi

echo "Installing R and system libraries required to build CRAN packages..."
"${apt[@]}" update
"${apt[@]}" install -y \
  r-base \
  r-base-dev \
  build-essential \
  libcurl4-openssl-dev \
  libfontconfig1-dev \
  libharfbuzz-dev \
  libfribidi-dev \
  libssl-dev \
  libxml2-dev \
  r-cran-car \
  r-cran-effectsize \
  r-cran-emmeans \
  r-cran-ggplot2 \
  r-cran-jsonlite \
  r-cran-multcomp \
  r-cran-nloptr \
  r-cran-nortest \
  r-cran-randomforest \
  r-cran-scales \
  r-cran-tibble \
  r-cran-tidyr \
  r-cran-xtable \
  r-cran-yaml

echo "Installing R package dependencies..."
Rscript "$root/install_packages.R"

echo "Installation complete. Run the analysis with: Rscript run_analysis.R"