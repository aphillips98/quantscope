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
EXTRA_MODULES=()

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Options:
  --dev         Include development and test dependencies (pytest, etc.)
  --all         Install all backend dependencies (llamacpp, transformers, vllm, deepeval, telemetry)
  --dry-run     Show detected backends and generated install command without executing
  -h, --help    Show this help message

Environment Detection:
  - Detects loaded Lua/Lmod modules via \$LOADEDMODULES / \$_LMFILES_
    - If a llamacpp module is loaded (or llama-server is in PATH), enables the llamacpp extra
        and builds a native library compatible with the installed Python binding
  - If a CUDA module is loaded (or nvcc is in PATH), enables CUDA support and transformers/vllm
EOF
}

while (($# > 0)); do
    case "$1" in
        --dev) INSTALL_DEV=1; shift ;;
        --all) INSTALL_ALL=1; shift ;;
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
if [[ "$LOADED" =~ (cuda|CUDA) ]] || command -v nvcc >/dev/null 2>&1; then
    HAS_CUDA=1
    printf '==> Detected CUDA environment\n'
fi

# 2. Detect llama.cpp prebuilt module / binaries
HAS_LLAMACPP=0
if [[ "$LOADED" =~ llamacpp ]] || command -v llama-server >/dev/null 2>&1 || [[ -n "${LLAMA_CPP_LIB:-}" ]]; then
    HAS_LLAMACPP=1
    EXTRAS+=("llamacpp")
    printf '==> Detected llama.cpp module / prebuilt binary\n'

    printf '   Rebuilding llama-cpp-python native library for the installed Python binding\n'
fi

# 3. Detect transformers / vllm or install --all
if ((INSTALL_ALL)); then
    for extra in llamacpp transformers vllm; do
        if [[ ! " ${EXTRAS[*]} " =~ " ${extra} " ]]; then
            EXTRAS+=("$extra")
        fi
    done
elif ((HAS_CUDA)); then
    if [[ ! " ${EXTRAS[*]} " =~ " transformers " ]]; then
        EXTRAS+=("transformers")
    fi
fi

if ((INSTALL_DEV)); then
    EXTRAS+=("dev")
fi

EXTRAS_JOINED="$(IFS=,; echo "${EXTRAS[*]}")"
printf 'Installing packages with extras: [%s]\n' "$EXTRAS_JOINED"

if ((DRY_RUN)); then
    printf '\n[Dry Run] Would execute:\n'
    printf '  uv venv .venv\n'
    printf '  source .venv/bin/activate\n'
    if ((HAS_LLAMACPP)); then
        printf '  uv pip install --reinstall-package llama-cpp-python --no-binary llama-cpp-python -e ".[%s]"\n' "$EXTRAS_JOINED"
    else
        printf '  uv pip install -e ".[%s]"\n' "$EXTRAS_JOINED"
    fi
    exit 0
fi

# Create and activate venv
if [[ ! -d ".venv" ]]; then
    printf 'Creating virtual environment in .venv...\n'
    uv venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

# Execute installation
if ((HAS_LLAMACPP)); then
    uv pip install --reinstall-package llama-cpp-python --no-binary llama-cpp-python -e ".[${EXTRAS_JOINED}]"
else
    uv pip install -e ".[${EXTRAS_JOINED}]"
fi

printf '\nInstallation completed successfully in .venv (extras: %s).\n' "$EXTRAS_JOINED"
