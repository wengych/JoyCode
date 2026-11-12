#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SOURCE_DIR/script-env.sh"
prepare_build_environment
case "$APP_DIR" in
    *.app) ;;
    *) printf 'JOYCODE_APP_DIR must end in .app: %s\n' "$APP_DIR" >&2; exit 1 ;;
esac
swift build --disable-sandbox --package-path "$SOURCE_DIR" --scratch-path "$BUILD_DIR" \
  --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" -c release -debug-info-format none
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_DIR/Resources/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_DIR/Resources/Info.plist")"
# Use the committed icon unchanged. Regenerate explicitly with make-icon.sh after
# editing its master image; a clone does not depend on checkout file timestamps.
if [ ! -f "$ICON_OUTPUT" ]; then
    bash "$SOURCE_DIR/make-icon.sh"
fi
STAGING_DIR="$(mktemp -d "$BUILD_ROOT/app-staging.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/JoyCode.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BUILD_DIR/release/$EXECUTABLE" "$STAGING_APP/Contents/MacOS/$EXECUTABLE"
cp "$SOURCE_DIR/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$ICON_OUTPUT" "$STAGING_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"
# Replace only the selected generated bundle after a successful build/signature.
# The default is this repository's dist/, not the previously installed workspace app.
mkdir -p "$(dirname -- "$APP_DIR")"
rm -rf -- "$APP_DIR"
mv "$STAGING_APP" "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
