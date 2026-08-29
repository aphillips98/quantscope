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
  as_root=()
elif command -v sudo >/dev/null 2>&1; then
  as_root=(sudo)
else
  echo "Administrator privileges are required to install R. Re-run with sudo." >&2
  exit 1
fi
apt=("${as_root[@]}" apt-get)

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

# --- Nsight Systems CLI ------------------------------------------------------
# etl/profiling_etl.py shells out to `nsys stats` to parse nsight/*.sqlite.
# Without it the nsight_*.csv tables come out empty.
if command -v nsys >/dev/null 2>&1; then
  echo "nsys already installed: $(command -v nsys)"
else
  echo "Installing NVIDIA Nsight Systems CLI (nsys)..."
  "${apt[@]}" install -y ca-certificates curl gnupg

  . /etc/os-release
  # Repo layout is developer.download.nvidia.com/devtools/repos/<id><ver>/<dpkg arch>/
  base="https://developer.download.nvidia.com/devtools/repos/${ID}${VERSION_ID//./}/$(dpkg --print-architecture)"

  if ! curl -fsSL -o /dev/null "${base}/Release"; then
    echo "WARNING: no NVIDIA devtools repo at ${base}." >&2
    echo "         Install Nsight Systems manually from" >&2
    echo "         https://developer.nvidia.com/nsight-systems/get-started" >&2
  else
    curl -fsSL "${base}/nvidia.pub" \
      | gpg --dearmor \
      | "${as_root[@]}" tee /usr/share/keyrings/nvidia-devtools.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nvidia-devtools.gpg] ${base}/ /" \
      | "${as_root[@]}" tee /etc/apt/sources.list.d/nvidia-devtools.list >/dev/null
    "${apt[@]}" update
    "${apt[@]}" install -y nsight-systems-cli
  fi
fi

if command -v nsys >/dev/null 2>&1; then
  echo "nsys: $(nsys --version | head -1)"
else
  echo "WARNING: nsys is still unavailable; Nsight tables will be skipped by the ETL." >&2
fi

echo "Installation complete. Run the analysis with: Rscript run_analysis.R"