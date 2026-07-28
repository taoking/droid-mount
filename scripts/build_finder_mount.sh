#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_ARCH="${1:-$(uname -m)}"
FUSE_ROOT="${DROIDMOUNT_MACFUSE_ROOT:-/usr/local}"
AFT_SOURCE_DIR="${DROIDMOUNT_AFT_SOURCE_DIR:-$PROJECT_ROOT/../android-file-transfer-linux}"
BUILD_DIR="$PROJECT_ROOT/.build/aft-mtp-mount-$TARGET_ARCH-unix-makefiles"

if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x86_64" ]]; then
    echo "ERROR: unsupported Finder mount architecture: $TARGET_ARCH" >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake is required. Install it with: brew install cmake" >&2
    exit 1
fi

if [[ ! -d "$AFT_SOURCE_DIR" ]]; then
    echo "ERROR: Android File Transfer source was not found at $AFT_SOURCE_DIR" >&2
    echo "Clone whoozle/android-file-transfer-linux beside this repository or set DROIDMOUNT_AFT_SOURCE_DIR." >&2
    exit 1
fi

if [[ ! -f "$FUSE_ROOT/include/fuse3/fuse.h" || ! -f "$FUSE_ROOT/lib/libfuse3.4.dylib" ]]; then
    echo "ERROR: macFUSE development files were not found under $FUSE_ROOT" >&2
    echo "Install and approve macFUSE, then rebuild." >&2
    exit 1
fi

export PKG_CONFIG_PATH="$FUSE_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cmake -S "$AFT_SOURCE_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DBUILD_FUSE=ON \
    -DBUILD_QT_UI=OFF \
    -DBUILD_PYTHON=OFF \
    -DBUILD_TAGLIB=OFF \
    -DBUILD_MTPZ=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >&2
cmake --build "$BUILD_DIR" --target aft-mtp-mount --parallel >&2

HELPER_PATH="$BUILD_DIR/fuse/aft-mtp-mount"
if [[ ! -x "$HELPER_PATH" ]]; then
    echo "ERROR: Finder mount helper was not produced at $HELPER_PATH" >&2
    exit 1
fi

echo "$HELPER_PATH"
