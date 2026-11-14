#!/usr/bin/env bash
# Build IINA RAW from public sources and install it.
#
# What this script does, in order:
#   1. Checks the build tools.
#   2. Clones iina/deps-buildscripts at a pinned commit, applies build/patches/deps-buildscripts.patch
#      (JOBS from the environment) and copies build/patches/ffmpeg-9.0.2-tico_raw.patch into
#      its patches/ffmpeg/ folder (the deps build applies it to FFmpeg 9.0.2).
#   3. Builds the libraries (FFmpeg 9.0.2 with tico_raw, mpv, libplacebo and more) for arm64:
#      ./build.sh arm64, ./fix-install-names.sh arm64, ./copy-headers.sh.
#   4. Clones https://github.com/alperkaganavci/iina (branch iina-raw), puts the libraries in
#      deps/lib and the headers in deps/include.
#   5. Builds the app with xcodebuild, ad-hoc signed.
#   6. Installs it with tools/install_iina_raw.sh.
#
# Usage:  build/build-iina-raw.sh
#
# Environment (all optional):
#   WORK          working folder for the clones and build output (default: build/work in this repo)
#   JOBS          parallel jobs for the library build (default: 4). More jobs need more memory.
#   REBUILD_DEPS  1 = build the libraries again, even when a finished build exists. Use this after
#                 you change a patch.
#   NO_INSTALL    1 = build only; do not install into /Applications.
#   CLIP          path of a Nikon ZR .R3D clip. When set, the script checks after the library
#                 build that FFmpeg opens it with the tico_raw decoder (tests/test_deps_build.py).
#
# Needs: macOS on Apple Silicon, Xcode (with the command line tools), git, and these Homebrew
# packages:  brew install meson ninja pkg-config automake nasm libtool cmake
# The build downloads source code and Swift packages, so it needs network access. A full run takes
# tens of minutes the first time.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/build/work}"
JOBS="${JOBS:-4}"
REBUILD_DEPS="${REBUILD_DEPS:-0}"
NO_INSTALL="${NO_INSTALL:-0}"

DEPS_URL="https://github.com/iina/deps-buildscripts"
DEPS_COMMIT="ee35579ded3ea95d839d85c2686d96dc505ee344"
IINA_URL="https://github.com/alperkaganavci/iina"
IINA_BRANCH="iina-raw"

DEPS="$WORK/deps-buildscripts"
IINA="$WORK/iina"
DERIVED="$WORK/iina-derived"
APP="$DERIVED/Build/Products/Release/IINA RAW.app"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "build-iina-raw: $*" >&2; exit 1; }

# ---- 1. checks -----------------------------------------------------------------------------

step "Checking the build tools"
[ "$(uname -s)" = "Darwin" ] || die "this build needs macOS"
[ "$(uname -m)" = "arm64" ] || die "this build needs an Apple Silicon Mac (arm64)"
missing=()
for tool in git meson ninja pkg-config aclocal glibtoolize nasm cmake perl python3 xcodebuild xcrun; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing tools: ${missing[*]}" >&2
    echo "Install Xcode, then run: brew install meson ninja pkg-config automake nasm libtool cmake" >&2
    exit 1
fi
case "$JOBS" in
    ''|*[!0-9]*) die "JOBS must be a number, got '$JOBS'" ;;
esac
mkdir -p "$WORK"
echo "working folder: $WORK"
echo "jobs: $JOBS"

# ---- 2. deps-buildscripts with our patches ------------------------------------------------

step "Preparing iina/deps-buildscripts at $DEPS_COMMIT"
if [ ! -d "$DEPS/.git" ]; then
    git clone --quiet "$DEPS_URL" "$DEPS"
fi
git -C "$DEPS" fetch --quiet origin
git -C "$DEPS" checkout --quiet --detach "$DEPS_COMMIT"

# The patch changes one line in buildscripts/common.sh. Apply it once.
if git -C "$DEPS" apply --reverse --check "$REPO/build/patches/deps-buildscripts.patch" 2>/dev/null; then
    echo "deps-buildscripts.patch is already applied"
else
    git -C "$DEPS" apply "$REPO/build/patches/deps-buildscripts.patch"
    echo "applied deps-buildscripts.patch"
fi

# The deps build applies every *.patch of patches/<package>/ to the package source.
mkdir -p "$DEPS/patches/ffmpeg"
cp "$REPO/build/patches/ffmpeg-9.0.2-tico_raw.patch" "$DEPS/patches/ffmpeg/0001-ticoraw.patch"
echo "copied ffmpeg-9.0.2-tico_raw.patch to patches/ffmpeg/0001-ticoraw.patch"

# ---- 3. libraries ---------------------------------------------------------------------------

LIBMPV="$DEPS/output/arm64/libmpv.2.dylib"
if [ -f "$LIBMPV" ] && [ "$REBUILD_DEPS" != "1" ]; then
    step "Libraries already built (set REBUILD_DEPS=1 to build them again)"
else
    step "Building the libraries (this takes a long time)"
    (
        cd "$DEPS"
        JOBS="$JOBS" ./build.sh arm64
        ./fix-install-names.sh arm64
        ./copy-headers.sh
    )
fi
[ -f "$LIBMPV" ] || die "the library build did not make $LIBMPV"

if [ -n "${CLIP:-}" ]; then
    step "Checking that FFmpeg opens the clip with tico_raw"
    IINA_DEPS="$DEPS" python3 "$REPO/tests/test_deps_build.py"
fi

# ---- 4. IINA fork -----------------------------------------------------------------------------

step "Preparing $IINA_URL (branch $IINA_BRANCH)"
if [ ! -d "$IINA/.git" ]; then
    git clone --quiet --branch "$IINA_BRANCH" --single-branch "$IINA_URL" "$IINA"
else
    git -C "$IINA" fetch --quiet origin "$IINA_BRANCH"
    git -C "$IINA" checkout --quiet "$IINA_BRANCH"
    git -C "$IINA" merge --quiet --ff-only "origin/$IINA_BRANCH"
fi

mkdir -p "$IINA/deps/lib" "$IINA/deps/include"
cp "$DEPS"/output/arm64/*.dylib "$IINA/deps/lib/"
cp -R "$DEPS/output/include/." "$IINA/deps/include/"
echo "copied $(find "$IINA/deps/lib" -name '*.dylib' | wc -l | tr -d ' ') libraries and the headers"

# ---- 5. app -----------------------------------------------------------------------------------

step "Building IINA RAW (Release, arm64, ad-hoc signed)"
(
    cd "$IINA"
    xcodebuild -project iina.xcodeproj -scheme iina -configuration Release -arch arm64 \
        -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build \
        >"$WORK/xcodebuild.log" 2>&1 || {
        tail -n 30 "$WORK/xcodebuild.log" >&2
        die "xcodebuild failed; the full log is $WORK/xcodebuild.log"
    }
)
[ -d "$APP" ] || die "the build did not make $APP (log: $WORK/xcodebuild.log)"
echo "built: $APP"

# ---- 6. install -------------------------------------------------------------------------------

if [ "$NO_INSTALL" = "1" ]; then
    step "NO_INSTALL=1: not installing. Install later with: tools/install_iina_raw.sh \"$APP\""
else
    step "Installing into /Applications"
    "$REPO/tools/install_iina_raw.sh" "$APP"
fi
