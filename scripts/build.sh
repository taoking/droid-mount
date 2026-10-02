#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="DroidMount"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
ICON_SOURCE="$PROJECT_ROOT/Resources/DroidMount.icns"
BUILD_MODE="debug"
TARGET_ARCH="$(uname -m)"

usage() {
    echo "Usage: scripts/build.sh [debug|release] [--arch arm64|x86_64]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) BUILD_MODE="$1"; shift ;;
        --arch) TARGET_ARCH="${2:?missing architecture}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x86_64" ]]; then
    echo "ERROR: Unsupported architecture: $TARGET_ARCH" >&2
    exit 1
fi

for tool in swift cmake codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' was not found." >&2
        exit 1
    fi
done

TRIPLE="$TARGET_ARCH-apple-macosx"
SWIFT_BUILD_ARGS=(--triple "$TRIPLE")
if [[ "$BUILD_MODE" == "release" ]]; then
    SWIFT_BUILD_ARGS+=(-c release)
fi

swift build "${SWIFT_BUILD_ARGS[@]}"

# Ask SwiftPM where it put the product instead of assuming a layout. The output
# directory moved when the toolchain switched build systems, and a hardcoded path
# kept resolving to a leftover binary from the old layout - so the bundle silently
# shipped a stale build that still passed the executable check below.
SWIFT_BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
SWIFT_BIN="$SWIFT_BIN_DIR/$APP_NAME"

if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "ERROR: Swift binary was not produced at $SWIFT_BIN" >&2
    exit 1
fi

if [[ "$(lipo -archs "$SWIFT_BIN")" != *"$TARGET_ARCH"* ]]; then
    echo "ERROR: $SWIFT_BIN is not a $TARGET_ARCH binary (got $(lipo -archs "$SWIFT_BIN"))" >&2
    exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "ERROR: App icon was not found at $ICON_SOURCE" >&2
    exit 1
fi

HELPER_PATH="$("$PROJECT_ROOT/scripts/build_finder_mount.sh" "$TARGET_ARCH")"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/FinderMount"
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/DroidMount.icns"
cp "$HELPER_PATH" "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
chmod 755 "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

codesign -s - --force "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
codesign -s - --force --deep "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Build complete: $APP_BUNDLE"
