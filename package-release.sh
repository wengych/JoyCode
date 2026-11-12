#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SOURCE_DIR/script-env.sh"
prepare_build_environment

# Always build from this checkout. No signing identity, keychain or private key is needed.
bash "$SOURCE_DIR/build.sh"
codesign --verify --deep --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIR/Contents/Info.plist")"
case "$VERSION" in
    ''|*[!0-9A-Za-z._-]*) printf 'Invalid bundle version for release filename.\n' >&2; exit 1 ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9A-Za-z._-]*) printf 'Invalid build number for release filename.\n' >&2; exit 1 ;;
esac
ARCHITECTURES="$(xcrun lipo -archs "$APP_DIR/Contents/MacOS/$EXECUTABLE")"
case "$ARCHITECTURES" in
    arm64|x86_64) RELEASE_ARCH="$ARCHITECTURES" ;;
    'arm64 x86_64'|'x86_64 arm64') RELEASE_ARCH=universal ;;
    *) printf 'Unsupported release architectures: %s\n' "$ARCHITECTURES" >&2; exit 1 ;;
esac

ARCHIVE_NAME="JoyCode-$VERSION-build$BUILD_NUMBER-macos-$RELEASE_ARCH.zip"
mkdir -p "$DIST_DIR"
RELEASE_STAGING_DIR="$(mktemp -d "$BUILD_ROOT/release-staging.XXXXXX")"
trap 'rm -rf -- "$RELEASE_STAGING_DIR"' EXIT
# Do not copy local extended attributes or resource-fork metadata into the release.
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$RELEASE_STAGING_DIR/$ARCHIVE_NAME"
mv -f "$RELEASE_STAGING_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME"
(
    cd -- "$DIST_DIR"
    shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
printf 'Release: %s\nChecksums: %s\n' "$DIST_DIR/$ARCHIVE_NAME" "$DIST_DIR/SHA256SUMS"
