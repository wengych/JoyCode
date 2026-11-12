#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SOURCE_DIR/script-env.sh"
prepare_build_environment
swift test --disable-sandbox --package-path "$SOURCE_DIR" --scratch-path "$BUILD_DIR" \
  --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" "$@"
