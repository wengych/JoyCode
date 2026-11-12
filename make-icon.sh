#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SOURCE_DIR/script-env.sh"
prepare_build_environment
mkdir -p "$ICONSET_DIR" "$(dirname -- "$ICON_OUTPUT")"
for dimension in 16 32 128 256 512; do
    sips -z "$dimension" "$dimension" "$SOURCE_DIR/Resources/AppIcon-master.png" \
      --out "$ICONSET_DIR/icon_${dimension}x${dimension}.png" >/dev/null
    retina_dimension=$((dimension * 2))
    sips -z "$retina_dimension" "$retina_dimension" "$SOURCE_DIR/Resources/AppIcon-master.png" \
      --out "$ICONSET_DIR/icon_${dimension}x${dimension}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
printf 'Generated icon: %s\n' "$ICON_OUTPUT"
