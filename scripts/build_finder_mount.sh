#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_ARCH="${1:-$(uname -m)}"
FUSE_ROOT="${DROIDMOUNT_MACFUSE_ROOT:-/usr/local}"
AFT_SOURCE_DIR="${DROIDMOUNT_AFT_SOURCE_DIR:-$PROJECT_ROOT/../android-file-transfer-linux}"
BUILD_DIR="$PROJECT_ROOT/.build/aft-mtp-mount-$TARGET_ARCH-unix-makefiles"
PATCH_DIR="$PROJECT_ROOT/patches"
STAGE_DIR="$PROJECT_ROOT/.build/aft-src-$TARGET_ARCH"

if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x86_64" ]]; then
    echo "ERROR: unsupported Finder mount architecture: $TARGET_ARCH" >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake is required. Install it with: brew install cmake" >&2
    exit 1
fi

for tool in rsync patch; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' is required to stage the patched Android File Transfer source." >&2
        exit 1
    fi
done

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

# The Android File Transfer checkout stays pristine upstream. Stage a copy and apply
# our patches there, so rebuilds pick up upstream changes and never dirty the clone.
mkdir -p "$STAGE_DIR"
rsync -a --delete --exclude '.git' --exclude 'build' "$AFT_SOURCE_DIR/" "$STAGE_DIR/" >&2

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
for patch_file in "${PATCHES[@]}"; do
    echo "applying $(basename "$patch_file")" >&2
    patch -p1 -d "$STAGE_DIR" --no-backup-if-mismatch < "$patch_file" >&2
done

# CMake records its source directory in the cache; a cache left over from a build that
# pointed straight at the upstream clone would abort the configure step.
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]] \
    && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$STAGE_DIR" "$BUILD_DIR/CMakeCache.txt"; then
    echo "source directory changed; discarding stale CMake cache" >&2
    rm -rf "$BUILD_DIR"
fi

# rsync -a restores upstream modification times, so a file a dropped patch used to touch
# comes back older than its object file and make keeps linking the patched code. Start
# from a clean build directory whenever the patch set changes.
PATCH_STAMP="$(for patch_file in "${PATCHES[@]}"; do basename "$patch_file"; cat "$patch_file"; done | shasum -a 256 | cut -d' ' -f1)"
PATCH_STAMP_FILE="$BUILD_DIR/droidmount-patches.sha256"
if [[ -d "$BUILD_DIR" && "$(cat "$PATCH_STAMP_FILE" 2>/dev/null || true)" != "$PATCH_STAMP" ]]; then
    echo "patch set changed; discarding build directory" >&2
    rm -rf "${BUILD_DIR:?}"
fi

cmake -S "$STAGE_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DBUILD_FUSE=ON \
    -DBUILD_QT_UI=OFF \
    -DBUILD_PYTHON=OFF \
    -DBUILD_TAGLIB=OFF \
    -DBUILD_MTPZ=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$TARGET_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >&2
cmake --build "$BUILD_DIR" --target aft-mtp-mount --parallel >&2
echo "$PATCH_STAMP" > "$PATCH_STAMP_FILE"

HELPER_PATH="$BUILD_DIR/fuse/aft-mtp-mount"
if [[ ! -x "$HELPER_PATH" ]]; then
    echo "ERROR: Finder mount helper was not produced at $HELPER_PATH" >&2
    exit 1
fi

echo "$HELPER_PATH"
