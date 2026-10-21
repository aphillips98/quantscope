#!/usr/bin/env bash
# Install Python dependencies for llm_benchmarks using uv,
# automatically detecting backend dependencies loaded via Lua modules.
set -euo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DEV=0
INSTALL_ALL=0
DRY_RUN=0
VENV_DIR=".venv"
PROFILE=""
EXTRA_MODULES=()

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Options:
  --dev         Include development and test dependencies (pytest, etc.)
    --all         Install all backend dependencies except llama-cpp-python
  --profile NAME  Install into .venv-NAME (one venv per hardware profile; used by slurm/submit.sh)
  --dry-run     Show detected backends and generated install command without executing
  -h, --help    Show this help message

Environment Detection:
  - Detects loaded Lua/Lmod modules via \$LOADEDMODULES / \$_LMFILES_
    - Detects llama-server in PATH; llama-cpp-python is never installed by this script
  - If a CUDA module is loaded (or nvcc is in PATH), enables CUDA support and transformers/vllm
EOF
}

while (($# > 0)); do
    case "$1" in
        --dev) INSTALL_DEV=1; shift ;;
        --all) INSTALL_ALL=1; shift ;;
        --profile) PROFILE="${2:?--profile requires a value}"; VENV_DIR=".venv-${PROFILE}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Error: %s is required but not found in PATH.\n' "$1" >&2
        exit 1
    }
}

if ! command -v uv >/dev/null 2>&1 && [[ -x "${HOME}/.local/bin/uv" ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
fi

require_command uv

LOADED="${LOADEDMODULES:-}"
printf 'Loaded environment modules: %s\n' "${LOADED:-none}"

# Base extras always installed
EXTRAS=("deepeval" "telemetry")

# 1. Detect CUDA
HAS_CUDA=0
CUDA_ARCH=""
case "$PROFILE" in
    a100) CUDA_ARCH=80 ;;
    h100) CUDA_ARCH=90 ;;
    gpu|v100) CUDA_ARCH=70 ;;
esac
if [[ -n "$CUDA_ARCH" || "$LOADED" =~ (cuda|CUDA) ]] || command -v nvcc >/dev/null 2>&1; then
    HAS_CUDA=1
    printf '==> Detected CUDA environment\n'
fi

# 2. Prefer the module-provided llama.cpp server
HAS_LLAMASERVER=0
if command -v llama-server >/dev/null 2>&1; then
    HAS_LLAMASERVER=1
    printf '==> Detected llama-server\n'
else
    printf 'Error: llama-server is required; aborting before creating a virtual environment.\n' >&2
    exit 1
fi

# 3. Detect transformers / vllm or install --all
if ((INSTALL_ALL)); then
    for extra in transformers vllm; do
        if [[ ! " ${EXTRAS[*]} " =~ " ${extra} " ]]; then
            EXTRAS+=("$extra")
        fi
    done
elif ((HAS_CUDA && !HAS_LLAMASERVER)); then
    if [[ ! " ${EXTRAS[*]} " =~ " transformers " ]]; then
        EXTRAS+=("transformers")
    fi
fi

if ((INSTALL_DEV)); then
    EXTRAS+=("dev")
fi

EXTRAS_JOINED="$(IFS=,; echo "${EXTRAS[*]}")"
printf 'Installing packages with extras: [%s]\n' "$EXTRAS_JOINED"
CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
export CMAKE_BUILD_PARALLEL_LEVEL

if ((DRY_RUN)); then
    printf '\n[Dry Run] Would execute:\n'
    printf '  uv venv --managed-python --python %s %s\n' "${PYTHON_VERSION:-3.12}" "$VENV_DIR"
    printf '  source %s/bin/activate\n' "$VENV_DIR"
    printf '  uv pip install -e ".[%s]"\n' "$EXTRAS_JOINED"
    exit 0
fi

# Create and activate venv
if [[ ! -d "$VENV_DIR" ]]; then
    printf 'Creating virtual environment in %s...\n' "$VENV_DIR"
    # Managed Python lives in $HOME (shared); /usr/bin/python3 differs between login and compute nodes.
    uv venv --managed-python --python "${PYTHON_VERSION:-3.12}" "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# Execute installation
uv pip install -e ".[${EXTRAS_JOINED}]"

printf '\nInstallation completed successfully in %s (extras: %s).\n' "$VENV_DIR" "$EXTRAS_JOINED"
