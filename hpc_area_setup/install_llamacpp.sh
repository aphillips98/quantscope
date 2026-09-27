#!/usr/bin/env bash
# Build, install, and expose llama.cpp through an Lmod-compatible modulefile.
set -euo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    --config NAME|PATH      Load configs/NAME.conf or the specified config file
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
    ${PROGRAM_NAME} --config EPYC_node
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

parse_boolean() {
    local key="$1"
    local value="${2,,}"
    case "$value" in
        1|true|yes|on) BOOLEAN_VALUE=1 ;;
        0|false|no|off) BOOLEAN_VALUE=0 ;;
        *) die "Config key '$key' must be true or false: $2" ;;
    esac
}

resolve_config() {
    local requested="$1"
    if [[ -f "$requested" ]]; then
        CONFIG_FILE="$requested"
    elif [[ -f "${SCRIPT_DIR}/configs/${requested}" ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/configs/${requested}"
    elif [[ -f "${SCRIPT_DIR}/configs/${requested}.conf" ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/configs/${requested}.conf"
    else
        die "Config not found: $requested"
    fi
}

load_config() {
    local config_path="$1"
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=(.*)$ ]] || \
            die "Invalid config line in $config_path: $line"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == "~/"* ]]; then
            value="${HOME}/${value:2}"
        fi

        case "$key" in
            command) COMMAND="$value" ;;
            profile) PROFILE="$value" ;;
            prefix) PREFIX="$value" ;;
            module_root) MODULE_ROOT="$value" ;;
            source_dir) SOURCE_DIR="$value" ;;
            version) VERSION="$value" ;;
            ref) REF="$value" ;;
            jobs) JOBS="$value" ;;
            build_type)
                [[ "$value" == "Release" || "$value" == "Debug" ]] || \
                    die "Config key 'build_type' must be Release or Debug: $value"
                BUILD_TYPE="$value"
                ;;
            cuda)
                parse_boolean "$key" "$value"
                CUDA="$BOOLEAN_VALUE"
                ;;
            native)
                parse_boolean "$key" "$value"
                NATIVE="$BOOLEAN_VALUE"
                ;;
            cuda_architectures) CUDA_ARCHITECTURES="$value" ;;
            assume_yes)
                parse_boolean "$key" "$value"
                ASSUME_YES="$BOOLEAN_VALUE"
                ;;
            load_module)
                [[ -n "$value" ]] || die "Config key 'load_module' may not be empty"
                MODULES_TO_LOAD+=("$value")
                ;;
            *) die "Unknown config key in $config_path: $key" ;;
        esac
    done <"$config_path"

    case "$COMMAND" in
        build|continue|module|uninstall|clean|help) ;;
        *) die "Unsupported command in $config_path: $COMMAND" ;;
    esac
}

preload_config() {
    local config_name=""
    while (($# > 0)); do
        case "$1" in
            --config)
                [[ -z "$config_name" ]] || die "--config may only be specified once"
                config_name="${2:?--config requires a value}"
                shift 2
                ;;
            *) shift ;;
        esac
    done

    if [[ -n "$config_name" ]]; then
        resolve_config "$config_name"
        load_config "$CONFIG_FILE"
    fi
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
    while (($# > 0)); do
        case "$1" in
            build|continue|module|uninstall|clean|help) COMMAND="$1"; shift ;;
            --config) shift 2 ;;
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
whatis("Git ref      : ${REF}")

family("llamacpp")

local base = "${PREFIX}"
setenv("LLAMACPP_HOME", base)
setenv("LLAMACPP_REF", "${REF}")
if isDir(pathJoin(base, "lib64")) then
    setenv("LLAMA_CPP_LIB", pathJoin(base, "lib64", "libllama.so"))
    prepend_path("PKG_CONFIG_PATH", pathJoin(base, "lib64", "pkgconfig"))
else
    setenv("LLAMA_CPP_LIB", pathJoin(base, "lib", "libllama.so"))
    prepend_path("PKG_CONFIG_PATH", pathJoin(base, "lib", "pkgconfig"))
end

prepend_path("PATH", pathJoin(base, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("CMAKE_PREFIX_PATH", base)
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
        -DBUILD_SHARED_LIBS=ON
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
        git init "$SOURCE_DIR"
        git -C "$SOURCE_DIR" remote add origin https://github.com/ggml-org/llama.cpp.git
    fi

    git -C "$SOURCE_DIR" fetch --depth 1 origin "$REF"
    git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
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

preload_config "$@"
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
