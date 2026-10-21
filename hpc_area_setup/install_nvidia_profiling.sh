#!/usr/bin/env bash
# Build, install, and expose nvidia-profiling through an Lmod-compatible modulefile.
set -euo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="build"
PROFILE="${HPC_PROFILE:-${SLURM_JOB_PARTITION:-default}}"
PREFIX=""
MODULE_ROOT="${MODULE_ROOT:-${HOME}/.local/modules}"
SOURCE_DIR="${SOURCE_DIR:-${HOME}/.local/src/nvidia-profiling}"
VERSION="${VERSION:-1}"
REF="${NVIDIA_PROFILING_REF:-nvml-cupti-prof-kernel}"
REPO_URL="${NVIDIA_PROFILING_REPO:-https://github.com/gabrielwolfw/nvidia-profiling.git}"
JOBS="${NPROC:-}"
BUILD_TYPE="Release"
ASSUME_YES=0
MODULES_TO_LOAD=()
CUDA_ROOT=""
CUPTI_ROOT="${CUPTI_ROOT:-}"
CUPTI_LIBDIR=""
NVML_LIBDIR="${NVML_LIBDIR:-}"
CONFIG_FILE=""

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [command] [options]

Commands:
  build       Clone/update, configure, build, install, and write a modulefile (default)
  module      Write or refresh the modulefile for an existing installation
  uninstall   Remove the selected installation and its modulefile
  clean       Remove the selected source tree
  help        Show this help

Options:
    --config NAME|PATH    Load configs/nvidia-profiling/NAME.conf or the given config file
  --profile NAME          Hardware profile (default: HPC_PROFILE, SLURM_JOB_PARTITION, or default)
  --prefix PATH           Installation prefix; overrides the profile convention
  --module-root PATH      Modulefile root (default: ~/.local/modules)
  --source-dir PATH       Source checkout (default: ~/.local/src/nvidia-profiling)
  --version VERSION       Modulefile version (default: 1)
    --branch BRANCH         Repository branch to build (default: nvml-cupti-prof-kernel)
    --ref REF               Git ref to build; alias-compatible with --branch
  --repo URL              Git URL to clone (default: https://github.com/gabrielwolfw/nvidia-profiling.git)
  --cuda-root PATH        CUDA toolkit root (default: auto-detected from nvcc or /usr/local/cuda)
    --cupti-root PATH       CUPTI root (default: CUDA_ROOT/extras/CUPTI)
    --nvml-libdir PATH      Directory containing libnvidia-ml (default: system library paths)
  --jobs N                Parallel build jobs (default: nproc)
  --load-module NAME      Load an environment module before building; repeatable
  --yes                   Do not prompt before destructive commands
  --debug                 Use a Debug build
  -h, --help              Show this help

Examples:
    ${PROGRAM_NAME} --config H100_node
    ${PROGRAM_NAME} build --profile H100 --cuda-root /usr/local/cuda
    ${PROGRAM_NAME} build --profile A100 --load-module cuda/12.8
    ${PROGRAM_NAME} module --profile H100
    ${PROGRAM_NAME} uninstall --profile H100 --yes
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
    elif [[ -f "${SCRIPT_DIR}/configs/nvidia-profiling/${requested}" ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/configs/nvidia-profiling/${requested}"
    elif [[ -f "${SCRIPT_DIR}/configs/nvidia-profiling/${requested}.conf" ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/configs/nvidia-profiling/${requested}.conf"
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
        [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=(.*)$ ]] || die "Invalid config line in $config_path: $line"
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
            ref|branch) REF="$value" ;;
            repo) REPO_URL="$value" ;;
            jobs) JOBS="$value" ;;
            build_type)
                [[ "$value" == "Release" || "$value" == "Debug" ]] || die "Config key 'build_type' must be Release or Debug: $value"
                BUILD_TYPE="$value"
                ;;
            assume_yes)
                parse_boolean "$key" "$value"
                ASSUME_YES="$BOOLEAN_VALUE"
                ;;
            load_module)
                [[ -n "$value" ]] || die "Config key 'load_module' may not be empty"
                MODULES_TO_LOAD+=("$value")
                ;;
            cuda_root) CUDA_ROOT="$value" ;;
            cupti_root) CUPTI_ROOT="$value" ;;
            nvml_libdir) NVML_LIBDIR="$value" ;;
            *) die "Unknown config key in $config_path: $key" ;;
        esac
    done <"$config_path"

    case "$COMMAND" in
        build|module|uninstall|clean|help) ;;
        *) die "Unsupported command in $config_path: $COMMAND" ;;
    esac
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            build|module|uninstall|clean|help) COMMAND="$1"; shift ;;
            --config)
                [[ $# -ge 2 ]] || die "--config requires a value"
                resolve_config "$2"
                load_config "$CONFIG_FILE"
                shift 2
                ;;
            --profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
            --prefix) PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
            --module-root) MODULE_ROOT="${2:?--module-root requires a value}"; shift 2 ;;
            --source-dir) SOURCE_DIR="${2:?--source-dir requires a value}"; shift 2 ;;
            --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
            --branch) REF="${2:?--branch requires a value}"; shift 2 ;;
            --ref) REF="${2:?--ref requires a value}"; shift 2 ;;
            --repo) REPO_URL="${2:?--repo requires a value}"; shift 2 ;;
            --cuda-root) CUDA_ROOT="${2:?--cuda-root requires a value}"; shift 2 ;;
            --cupti-root) CUPTI_ROOT="${2:?--cupti-root requires a value}"; shift 2 ;;
            --nvml-libdir) NVML_LIBDIR="${2:?--nvml-libdir requires a value}"; shift 2 ;;
            --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
            --load-module) MODULES_TO_LOAD+=("${2:?--load-module requires a value}"); shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --debug) BUILD_TYPE="Debug"; shift ;;
            -h|--help) COMMAND="help"; shift ;;
            *) die "Unknown option or command: $1" ;;
        esac
    done
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

set_default_jobs() {
    if [[ -z "$JOBS" ]]; then
        require_command nproc
        JOBS="$(nproc)"
    fi
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
}

set_paths() {
    validate_profile
    if [[ -z "$PREFIX" ]]; then
        PREFIX="${HOME}/.local/programs/${PROFILE}/nvidia-profiling"
    fi
    BUILD_DIR="${SOURCE_DIR}/build-${PROFILE}"
    MODULE_FILE="${MODULE_ROOT}/${PROFILE}/nvidia-profiling/${VERSION}.lua"
}

detect_cuda_root() {
    if [[ -n "$CUDA_ROOT" ]]; then
        return
    fi
    if command -v nvcc >/dev/null 2>&1; then
        CUDA_ROOT="$(dirname "$(dirname "$(command -v nvcc)")")"
        return
    fi
    if [[ -d "/usr/local/cuda" ]]; then
        CUDA_ROOT="/usr/local/cuda"
        return
    fi
    die "Unable to locate CUDA toolkit. Set --cuda-root or load a cuda module first."
}

detect_cupti_paths() {
    if [[ -z "$CUPTI_ROOT" ]]; then
        if [[ -d "$CUDA_ROOT/extras/CUPTI" ]]; then
            CUPTI_ROOT="$CUDA_ROOT/extras/CUPTI"
        elif [[ -d "$CUDA_ROOT/targets/x86_64-linux/extras/CUPTI" ]]; then
            CUPTI_ROOT="$CUDA_ROOT/targets/x86_64-linux/extras/CUPTI"
        else
            die "Unable to locate CUPTI under $CUDA_ROOT; set --cupti-root"
        fi
    fi

    [[ -f "$CUPTI_ROOT/include/cupti.h" ]] || die "CUPTI headers not found: $CUPTI_ROOT/include/cupti.h"
    if [[ -d "$CUPTI_ROOT/lib64" ]]; then
        CUPTI_LIBDIR="$CUPTI_ROOT/lib64"
    elif [[ -d "$CUPTI_ROOT/lib" ]]; then
        CUPTI_LIBDIR="$CUPTI_ROOT/lib"
    else
        die "CUPTI library directory not found under $CUPTI_ROOT (expected lib64 or lib)"
    fi
    [[ -e "$CUPTI_LIBDIR/libcupti.so" || -e "$CUPTI_LIBDIR/libcupti.a" ]] || \
        die "CUPTI library not found under $CUPTI_LIBDIR"

    export CPATH="$CUPTI_ROOT/include${CPATH:+:$CPATH}"
    export LIBRARY_PATH="$CUPTI_LIBDIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export LD_LIBRARY_PATH="$CUPTI_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

detect_nvml_library() {
    local search_path directory library_path nvml_link_dir
    if [[ -z "$NVML_LIBDIR" ]]; then
        search_path="${LD_LIBRARY_PATH:-}:${LIBRARY_PATH:-}:$CUDA_ROOT/lib64:/usr/lib64:/usr/lib/x86_64-linux-gnu:/lib64:/lib/x86_64-linux-gnu"
        local -a search_directories=()
        IFS=: read -r -a search_directories <<<"$search_path"
        for directory in "${search_directories[@]}"; do
            [[ -n "$directory" ]] || continue
            if [[ -e "$directory/libnvidia-ml.so" || -e "$directory/libnvidia-ml.so.1" ]]; then
                NVML_LIBDIR="$directory"
                break
            fi
        done
    fi

    if [[ -z "$NVML_LIBDIR" ]] && command -v ldconfig >/dev/null 2>&1; then
        library_path="$(ldconfig -p 2>/dev/null | awk '$1 == "libnvidia-ml.so.1" { print $NF; exit }')"
        if [[ -n "$library_path" ]]; then
            NVML_LIBDIR="${library_path%/*}"
        fi
    fi

    [[ -n "$NVML_LIBDIR" ]] || die "Unable to locate libnvidia-ml; set --nvml-libdir to its directory"
    if [[ -e "$NVML_LIBDIR/libnvidia-ml.so" ]]; then
        export LIBRARY_PATH="$NVML_LIBDIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    elif [[ -e "$NVML_LIBDIR/libnvidia-ml.so.1" ]]; then
        nvml_link_dir="${BUILD_DIR}-nvml-link"
        mkdir -p "$nvml_link_dir"
        ln -sfn "$NVML_LIBDIR/libnvidia-ml.so.1" "$nvml_link_dir/libnvidia-ml.so"
        export LIBRARY_PATH="$nvml_link_dir:$NVML_LIBDIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    else
        die "libnvidia-ml.so or libnvidia-ml.so.1 not found in $NVML_LIBDIR"
    fi
}

validate_build_tools() {
    require_command git
    require_command meson
    require_command ninja
    require_command c++
    detect_cuda_root
    [[ -x "$CUDA_ROOT/bin/nvcc" ]] || die "nvcc not found or not executable: $CUDA_ROOT/bin/nvcc"
    detect_cupti_paths
    detect_nvml_library
}

git_checkout_or_clone() {
    mkdir -p "$(dirname "$SOURCE_DIR")"
    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        [[ ! -e "$SOURCE_DIR" ]] || die "Source directory exists but is not a Git checkout: $SOURCE_DIR; remove it or pass --source-dir"
        git clone --branch "$REF" --single-branch "$REPO_URL" "$SOURCE_DIR"
    else
        git -C "$SOURCE_DIR" fetch --all --tags --prune >/dev/null 2>&1 || true
        if git -C "$SOURCE_DIR" rev-parse --verify "$REF" >/dev/null 2>&1; then
            git -C "$SOURCE_DIR" checkout "$REF" >/dev/null 2>&1 || true
            git -C "$SOURCE_DIR" pull --ff-only origin "$REF" >/dev/null 2>&1 || true
        else
            git -C "$SOURCE_DIR" checkout -B "$REF" "origin/$REF" >/dev/null 2>&1 || true
        fi
    fi

    [[ -f "$SOURCE_DIR/meson.build" ]] || die "Expected Meson project file not found: $SOURCE_DIR/meson.build (check repository URL and branch)"
}

write_modulefile() {
    mkdir -p "$(dirname "$MODULE_FILE")"
    cat >"$MODULE_FILE" <<EOF
-- -*- lua -*-
local name = "nvidia-profiling"
local version = "${VERSION}"
whatis("Name         : " .. name)
whatis("Version      : " .. version)
whatis("Description  : NVIDIA GPU profiling tools (CUPTI/NVML/PM sampling)")
whatis("Profile      : ${PROFILE}")
whatis("Ref          : ${REF}")
whatis("Repository   : ${REPO_URL}")
prepend_path("PATH", "${PREFIX}/bin")
prepend_path("PATH", "${PREFIX}/sbin")
prepend_path("LD_LIBRARY_PATH", "${PREFIX}/lib/nvidia-process-metrics")
EOF
    if [[ -n "$CUDA_ROOT" ]]; then
        printf 'prepend_path("LD_LIBRARY_PATH", "%s/lib64")\n' "$CUDA_ROOT" >>"$MODULE_FILE"
    fi
    if [[ -n "$CUPTI_LIBDIR" ]]; then
        printf 'prepend_path("LD_LIBRARY_PATH", "%s")\n' "$CUPTI_LIBDIR" >>"$MODULE_FILE"
    fi
    if [[ -n "$NVML_LIBDIR" ]]; then
        printf 'prepend_path("LD_LIBRARY_PATH", "%s")\n' "$NVML_LIBDIR" >>"$MODULE_FILE"
    fi
}

build_install() {
    git_checkout_or_clone
    detect_cuda_root
    detect_cupti_paths
    detect_nvml_library
    if [[ -f "$BUILD_DIR/meson-private/coredata.dat" ]]; then
        meson setup --reconfigure "$BUILD_DIR" "$SOURCE_DIR" \
            --prefix="$PREFIX" \
            --libdir=lib \
            --buildtype="${BUILD_TYPE,,}" \
            -Dbuild_cuda_components=true \
            -Dnvidia_toolkit_root="$CUDA_ROOT"
    else
        meson setup "$BUILD_DIR" "$SOURCE_DIR" \
            --prefix="$PREFIX" \
            --libdir=lib \
            --buildtype="${BUILD_TYPE,,}" \
            -Dbuild_cuda_components=true \
            -Dnvidia_toolkit_root="$CUDA_ROOT"
    fi

    meson compile -C "$BUILD_DIR" --jobs "$JOBS"
    meson install -C "$BUILD_DIR"
    write_modulefile
}

clean_source() {
    if [[ -d "$SOURCE_DIR" ]]; then
        confirm "Remove source tree at $SOURCE_DIR?"
        rm -rf "$SOURCE_DIR"
    else
        printf 'Source tree not found: %s\n' "$SOURCE_DIR"
    fi
}

uninstall_target() {
    if [[ -d "$PREFIX" ]]; then
        confirm "Remove installation at $PREFIX?"
        rm -rf "$PREFIX"
    fi
    if [[ -f "$MODULE_FILE" ]]; then
        confirm "Remove modulefile at $MODULE_FILE?"
        rm -f "$MODULE_FILE"
    fi
}

parse_args "$@"

case "$COMMAND" in
    help)
        usage
        ;;
    build)
        load_requested_modules
        set_default_jobs
        set_paths
        validate_build_tools
        build_install
        printf '\nInstalled under: %s\n' "$PREFIX"
        printf 'Module file: %s\n' "$MODULE_FILE"
        ;;
    module)
        set_paths
        write_modulefile
        printf 'Module file refreshed: %s\n' "$MODULE_FILE"
        ;;
    clean)
        set_paths
        clean_source
        ;;
    uninstall)
        set_paths
        uninstall_target
        ;;
    *)
        usage
        exit 1
        ;;
 esac
