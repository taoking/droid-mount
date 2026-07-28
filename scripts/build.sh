#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="DroidMount"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
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
if [[ "$BUILD_MODE" == "release" ]]; then
    swift build -c release --triple "$TRIPLE"
    SWIFT_BIN="$PROJECT_ROOT/.build/$TRIPLE/release/$APP_NAME"
else
    swift build --triple "$TRIPLE"
    SWIFT_BIN="$PROJECT_ROOT/.build/$TRIPLE/debug/$APP_NAME"
fi

if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "ERROR: Swift binary was not produced at $SWIFT_BIN" >&2
    exit 1
fi

HELPER_PATH="$("$PROJECT_ROOT/scripts/build_finder_mount.sh" "$TARGET_ARCH")"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/FinderMount"
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$HELPER_PATH" "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
chmod 755 "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

codesign -s - --force "$APP_BUNDLE/Contents/Resources/FinderMount/aft-mtp-mount"
codesign -s - --force --deep "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Build complete: $APP_BUNDLE"
