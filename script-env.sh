#!/bin/bash
# Shared by build/test/package scripts. Relative overrides are repository-relative.
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

repo_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$SOURCE_DIR" "$1" ;;
    esac
}

BUILD_ROOT="$(repo_path "${JOYCODE_BUILD_ROOT:-.build-work}")"
BUILD_DIR="$(repo_path "${JOYCODE_BUILD_DIR:-$BUILD_ROOT/swift}")"
MODULE_DIR="$(repo_path "${JOYCODE_MODULE_CACHE_DIR:-$BUILD_ROOT/module-cache}")"
BUILD_TMP_DIR="$(repo_path "${JOYCODE_TMP_DIR:-$BUILD_ROOT/tmp}")"
DIST_DIR="$(repo_path "${JOYCODE_DIST_DIR:-dist}")"
APP_DIR="$(repo_path "${JOYCODE_APP_DIR:-$DIST_DIR/JoyCode.app}")"
ICONSET_DIR="$(repo_path "${JOYCODE_ICONSET_DIR:-$BUILD_ROOT/AppIcon.iconset}")"
ICON_OUTPUT="$(repo_path "${JOYCODE_ICON_OUTPUT:-Resources/AppIcon.icns}")"

prepare_build_environment() {
    if [ "$(uname -s)" != Darwin ]; then
        printf 'JoyCode requires macOS and an installed Xcode/Swift toolchain.\n' >&2
        return 1
    fi
    mkdir -p "$BUILD_ROOT" "$BUILD_DIR" "$MODULE_DIR" "$BUILD_TMP_DIR"
    export CLANG_MODULE_CACHE_PATH="$MODULE_DIR"
    export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_DIR"
    export TMPDIR="$BUILD_TMP_DIR/"
}
