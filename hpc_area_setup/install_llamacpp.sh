#!/usr/bin/env bash
# Build, install, and expose llama.cpp through an Lmod-compatible modulefile.
set -euo pipefail

PROGRAM_NAME="${0##*/}"
COMMAND="build"
PROFILE="${HPC_PROFILE:-${SLURM_JOB_PARTITION:-default}}"
PREFIX=""
MODULE_ROOT="${MODULE_ROOT:-${HOME}/.local/modules}"
SOURCE_DIR="${SOURCE_DIR:-${HOME}/.local/src/llama.cpp}"
VERSION="1"
REF="${LLAMACPP_REF:-master}"
JOBS="${NPROC:-}"
BUILD_TYPE="Release"
CUDA=0
NATIVE=0
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-}"
ASSUME_YES=0
MODULES_TO_LOAD=()

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [command] [options]

Commands:
  build       Clone/update, configure, build, install, and write a modulefile (default)
  continue    Continue an existing CMake build without reconfiguring
  module      Write or refresh the modulefile for an existing installation
  uninstall   Remove the selected installation and its modulefile
  clean       Remove the selected source tree
  help        Show this help

Options:
  --profile NAME          Hardware or scheduler profile (default: HPC_PROFILE,
                          SLURM_JOB_PARTITION, or "default")
  --prefix PATH           Installation prefix; overrides the profile convention
  --module-root PATH      Modulefile root (default: ~/.local/modules)
  --source-dir PATH       llama.cpp checkout (default: ~/.local/src/llama.cpp)
  --version VERSION       Modulefile version (default: 1)
  --ref REF               llama.cpp Git ref (default: master)
  --cuda                  Enable CUDA backend
  --cuda-architectures X  CMake CUDA architectures, e.g. "80;90"
  --native                Enable host-specific CPU optimizations
  --jobs N                Parallel build jobs (default: nproc)
  --load-module NAME      Load an environment module before building; repeatable
  --yes                   Do not prompt before destructive commands
  --debug                 Use a Debug build
  -h, --help              Show this help

Examples:
  ${PROGRAM_NAME} build --profile CPU
  ${PROGRAM_NAME} build --profile H100 --cuda --cuda-architectures 90 --load-module cuda/12.8
  ${PROGRAM_NAME} build --profile EPYC --native
  ${PROGRAM_NAME} module --profile DGX --cuda
  ${PROGRAM_NAME} uninstall --profile GPU --cuda --yes
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_profile() {
    [[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Profile may only contain letters, numbers, dots, underscores, and hyphens: $PROFILE"
}

load_requested_modules() {
    ((${#MODULES_TO_LOAD[@]} == 0)) && return
    type module >/dev/null 2>&1 || die "'module' is unavailable; initialize Lmod or Environment Modules before using --load-module"
    local module_name
    for module_name in "${MODULES_TO_LOAD[@]}"; do
        module load "$module_name"
    done
}

confirm() {
    ((ASSUME_YES)) && return
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]] || exit 0
}

parse_args() {
    if (($# > 0)); then
        case "$1" in
            build|continue|module|uninstall|clean|help)
                COMMAND="$1"
                shift
                ;;
        esac
    fi

    while (($# > 0)); do
        case "$1" in
            --profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
            --prefix) PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
            --module-root) MODULE_ROOT="${2:?--module-root requires a value}"; shift 2 ;;
            --source-dir) SOURCE_DIR="${2:?--source-dir requires a value}"; shift 2 ;;
            --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
            --ref) REF="${2:?--ref requires a value}"; shift 2 ;;
            --cuda) CUDA=1; shift ;;
            --cuda-architectures) CUDA_ARCHITECTURES="${2:?--cuda-architectures requires a value}"; shift 2 ;;
            --native) NATIVE=1; shift ;;
            --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
            --load-module) MODULES_TO_LOAD+=("${2:?--load-module requires a value}"); shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --debug) BUILD_TYPE="Debug"; shift ;;
            -h|--help) COMMAND="help"; shift ;;
            *) die "Unknown option or command: $1" ;;
        esac
    done
}

package_name() {
    if ((CUDA)); then
        printf 'llamacpp_cuda'
    else
        printf 'llamacpp'
    fi
}

set_paths() {
    validate_profile
    local package
    package="$(package_name)"
    if [[ -z "$PREFIX" ]]; then
        PREFIX="${HOME}/.local/programs/${PROFILE}/${package}"
    fi
    BUILD_DIR="${SOURCE_DIR}/build-${package}"
    MODULE_FILE="${MODULE_ROOT}/${PROFILE}/${package}/${VERSION}.lua"
}

set_default_jobs() {
    if [[ -z "$JOBS" ]]; then
        require_command nproc
        JOBS="$(nproc)"
    fi
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
}

validate_build_tools() {
    require_command git
    require_command cmake
    require_command "${CC:-cc}"
    require_command "${CXX:-c++}"
    if ((CUDA)); then
        require_command nvcc
    fi
}

write_modulefile() {
    mkdir -p "$(dirname "$MODULE_FILE")"
    cat >"$MODULE_FILE" <<EOF
-- -*- lua -*-
local name = "$(package_name)"
local version = "${VERSION}"
whatis("Name         : " .. name)
whatis("Version      : " .. version)
whatis("Description  : llama.cpp installed by hpc_area_setup")

family("llamacpp")

local base = "${PREFIX}"
prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("MANPATH", pathJoin(base, "share", "man"))
EOF
    printf 'Wrote modulefile: %s\n' "$MODULE_FILE"
}

configure_build() {
    local -a cmake_args=(
        -S "$SOURCE_DIR"
        -B "$BUILD_DIR"
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_INSTALL_LIBDIR=lib64
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
        -DLLAMA_BUILD_TESTS=OFF
        -DLLAMA_BUILD_EXAMPLES=ON
        -DLLAMA_BUILD_SERVER=ON
        -DGGML_NATIVE="$([[ $NATIVE -eq 1 ]] && printf ON || printf OFF)"
    )

    if ((CUDA)); then
        cmake_args+=(-DGGML_CUDA=ON)
        [[ -n "$CUDA_ARCHITECTURES" ]] && cmake_args+=(-DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES")
    fi

    cmake "${cmake_args[@]}"
}

prepare_source() {
    mkdir -p "$(dirname "$SOURCE_DIR")"
    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        [[ ! -e "$SOURCE_DIR" ]] || die "Source path exists but is not a Git checkout: $SOURCE_DIR"
        git clone --branch "$REF" --depth 1 https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR"
    else
        git -C "$SOURCE_DIR" fetch --tags origin
        git -C "$SOURCE_DIR" checkout "$REF"
        git -C "$SOURCE_DIR" pull --ff-only origin "$REF" || true
    fi
}

build() {
    load_requested_modules
    validate_build_tools
    set_default_jobs
    prepare_source
    configure_build
    cmake --build "$BUILD_DIR" --parallel "$JOBS"
    cmake --install "$BUILD_DIR"
    write_modulefile
    printf '\nInstalled %s in %s\n' "$(package_name)" "$PREFIX"
    printf 'Load it with: module use %s && module load %s/%s/%s\n' "$MODULE_ROOT" "$PROFILE" "$(package_name)" "$VERSION"
}

continue_build() {
    load_requested_modules
    validate_build_tools
    set_default_jobs
    [[ -d "$BUILD_DIR" ]] || die "No build directory found: $BUILD_DIR"
    cmake --build "$BUILD_DIR" --parallel "$JOBS"
    cmake --install "$BUILD_DIR"
    write_modulefile
}

uninstall() {
    [[ -e "$PREFIX" || -e "$MODULE_FILE" ]] || die "Nothing installed for profile '$PROFILE'"
    confirm "Remove $PREFIX and $MODULE_FILE?"
    rm -rf "$PREFIX"
    rm -f "$MODULE_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname "$MODULE_FILE")" 2>/dev/null || true
}

clean() {
    [[ -e "$SOURCE_DIR" ]] || die "No source directory found: $SOURCE_DIR"
    confirm "Remove source directory $SOURCE_DIR?"
    rm -rf "$SOURCE_DIR"
}

parse_args "$@"
[[ "$COMMAND" == "help" ]] && { usage; exit 0; }
set_paths

case "$COMMAND" in
    build) build ;;
    continue) continue_build ;;
    module) write_modulefile ;;
    uninstall) uninstall ;;
    clean) clean ;;
    *) die "Unsupported command: $COMMAND" ;;
esac
