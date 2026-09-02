#!/usr/bin/env bash
# Build, install, and expose tmux through an Lmod-compatible modulefile.
set -euo pipefail

PROGRAM_NAME="${0##*/}"
COMMAND="build"
VERSION="${TMUX_VERSION:-3.5a}"
PREFIX=""
MODULE_ROOT="${MODULE_ROOT:-${HOME}/.local/modules}"
SOURCE_ROOT="${SOURCE_ROOT:-${HOME}/.local/src}"
JOBS="${NPROC:-}"
ASSUME_YES=0
MODULES_TO_LOAD=()

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [command] [options]

Commands:
  build       Download, configure, build, install, and write a modulefile (default)
  continue    Continue an existing build without downloading or configuring
  module      Write or refresh the modulefile for an existing installation
  uninstall   Remove the selected installation and its modulefile
  clean       Remove the selected source and build directories
  help        Show this help

Options:
  --version VERSION       tmux release version (default: 3.5a)
  --prefix PATH           Installation prefix (default: ~/.local/programs/tmux/VERSION)
    --module-root PATH      Module root (default: ~/.local/modules)
  --source-root PATH      Download and source root (default: ~/.local/src)
  --jobs N                Parallel build jobs (default: nproc)
  --load-module NAME      Load an environment module before building; repeatable
  --yes                   Do not prompt before destructive commands
  -h, --help              Show this help

Examples:
  ${PROGRAM_NAME} build
  ${PROGRAM_NAME} build --version 3.5a --load-module gcc --load-module libevent --load-module ncurses
  ${PROGRAM_NAME} module --version 3.5a
  ${PROGRAM_NAME} uninstall --version 3.5a --yes
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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
            --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
            --prefix) PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
            --module-root) MODULE_ROOT="${2:?--module-root requires a value}"; shift 2 ;;
            --source-root) SOURCE_ROOT="${2:?--source-root requires a value}"; shift 2 ;;
            --jobs) JOBS="${2:?--jobs requires a value}"; shift 2 ;;
            --load-module) MODULES_TO_LOAD+=("${2:?--load-module requires a value}"); shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            -h|--help) COMMAND="help"; shift ;;
            *) die "Unknown option or command: $1" ;;
        esac
    done
}

set_paths() {
    [[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "Version contains unsupported characters: $VERSION"
    if [[ -z "$PREFIX" ]]; then
        PREFIX="${HOME}/.local/programs/tmux/${VERSION}"
    fi
    SOURCE_DIR="${SOURCE_ROOT}/tmux-${VERSION}"
    ARCHIVE="${SOURCE_ROOT}/tmux-${VERSION}.tar.gz"
    BUILD_DIR="${SOURCE_DIR}/build"
    MODULE_FILE="${MODULE_ROOT}/tmux/${VERSION}.lua"
}

set_default_jobs() {
    if [[ -z "$JOBS" ]]; then
        require_command nproc
        JOBS="$(nproc)"
    fi
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
}

validate_build_tools() {
    require_command "${CC:-cc}"
    require_command make
    require_command tar
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "Required downloader not found: install curl or wget"
    fi
}

download_source() {
    mkdir -p "$SOURCE_ROOT"
    if [[ ! -f "$ARCHIVE" ]]; then
        local url="https://github.com/tmux/tmux/releases/download/${VERSION}/tmux-${VERSION}.tar.gz"
        printf 'Downloading %s\n' "$url"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --retry 3 --output "$ARCHIVE" "$url"
        else
            wget --tries=3 --output-document="$ARCHIVE" "$url"
        fi
    fi

    if [[ ! -d "$SOURCE_DIR" ]]; then
        tar -xzf "$ARCHIVE" -C "$SOURCE_ROOT"
    fi
    [[ -x "$SOURCE_DIR/configure" ]] || die "tmux configure script not found in $SOURCE_DIR"
}

configure_build() {
    mkdir -p "$BUILD_DIR"
    (
        cd "$BUILD_DIR"
        "$SOURCE_DIR/configure" --prefix="$PREFIX"
    )
}

write_modulefile() {
    mkdir -p "$(dirname "$MODULE_FILE")"
    cat >"$MODULE_FILE" <<EOF
-- -*- lua -*-
help([[tmux ${VERSION} - terminal multiplexer (installed by hpc_area_setup)]])

whatis("Name         : tmux")
whatis("Version      : ${VERSION}")
whatis("Description  : Terminal multiplexer")

local root = "${PREFIX}"
prepend_path("PATH", pathJoin(root, "bin"))
prepend_path("MANPATH", pathJoin(root, "share", "man"))
EOF
    printf 'Wrote modulefile: %s\n' "$MODULE_FILE"
}

build() {
    load_requested_modules
    validate_build_tools
    set_default_jobs
    download_source
    configure_build
    make -C "$BUILD_DIR" -j"$JOBS"
    make -C "$BUILD_DIR" install
    write_modulefile
    printf '\nInstalled tmux %s in %s\n' "$VERSION" "$PREFIX"
    printf 'Load it with: module use %s && module load tmux/%s\n' "$MODULE_ROOT" "$VERSION"
}

continue_build() {
    load_requested_modules
    validate_build_tools
    set_default_jobs
    [[ -f "$BUILD_DIR/Makefile" ]] || die "No configured build found: $BUILD_DIR"
    make -C "$BUILD_DIR" -j"$JOBS"
    make -C "$BUILD_DIR" install
    write_modulefile
}

uninstall() {
    [[ -e "$PREFIX" || -e "$MODULE_FILE" ]] || die "Nothing installed for tmux $VERSION"
    confirm "Remove $PREFIX and $MODULE_FILE?"
    rm -rf "$PREFIX"
    rm -f "$MODULE_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname "$MODULE_FILE")" 2>/dev/null || true
}

clean() {
    [[ -e "$SOURCE_DIR" || -e "$ARCHIVE" ]] || die "No tmux source or archive found for $VERSION"
    confirm "Remove $SOURCE_DIR and $ARCHIVE?"
    rm -rf "$SOURCE_DIR" "$ARCHIVE"
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
