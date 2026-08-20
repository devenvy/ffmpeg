#!/usr/bin/env bash
set -euo pipefail

# Parameterized FFmpeg build script
#
# Build parameters (environment variables):
#   FFMPEG_VERSION         - FFmpeg version (default: first line of versions.txt)
#   BUILD_RID              - Runtime identifier (required):
#                            linux-x64, linux-arm64, linux-armhf, linux-musl-x64,
#                            win-x64, osx-x64, osx-arm64, android-arm64,
#                            ios-arm64, ios-sim-arm64
#   BUILD_LICENSE          - License family: gpl or lgpl (default: lgpl)
#   BUILD_LICENSE_VERSION  - License series: 3 (default) or 2 (GPLv2 / LGPLv2.1)
#   SKIP_DEPS              - true to skip host toolchain/package installation
#
# The per-RID toolchain (cross-gcc, mingw-w64, the iOS SDK, the Android NDK) is expected in the
# environment like any build tool — not a build parameter. The Android NDK is auto-detected from
# the SDK; if it can't be found the build errors out, same as a missing compiler.

############################################
# Step 1: Inputs & Paths
#
# Resolve the build inputs — FFmpeg version (first line of versions.txt),
# target RID, and license (lgpl/gpl) — and lay out the working and output
# directories used by the rest of the script.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_VERSION="${FFMPEG_VERSION:-$(grep -vE '^[[:space:]]*(#|$)' "${ROOT_DIR}/versions.txt" | head -1 | tr -d '[:space:]')}"
RID="${BUILD_RID:?BUILD_RID is required}"
LICENSE="${BUILD_LICENSE:-lgpl}"

WORK_DIR="${ROOT_DIR}/.build/${RID}"
SRC_DIR="${WORK_DIR}/src"
PREFIX_DIR="${WORK_DIR}/install"
OUT_DIR="${ROOT_DIR}/artifacts/${RID}/native"

echo "============================================="
echo "FFmpeg ${FFMPEG_VERSION} build"
echo "  RID:     ${RID}"
echo "  License: ${LICENSE}"
echo "============================================="

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

# Shared helpers (cmake wrapper, build_cmake_dep) used by the build steps.
. "${ROOT_DIR}/scripts/lib.sh"

############################################
# Build
#
# The whole build, one step per line. Each steps/NN_*.sh is SOURCED (runs in
# this shell, sharing the environment configured above) and does one part of
# the build; the details live in that step's file. Comment out a line to skip
# that step when debugging.
############################################
S="${ROOT_DIR}/scripts/steps"
. "${S}/02_configure.sh"          # per-RID toolchain, hwaccel flags, BUILD_* switches
. "${S}/03_install_packages.sh"   # install host build packages (apt/apk/brew)
. "${S}/04_select_license.sh"     # apply gpl/lgpl flag; lean iOS-simulator trims
. "${S}/05_write_toolchain.sh"    # deps dir + cross-compilation toolchain files
. "${S}/06_build_libraries.sh"    # build third-party libraries (sources deps/*)
. "${S}/07_build_ffmpeg.sh"       # download, configure, and build FFmpeg
. "${S}/08_stage_artifacts.sh"    # stage per-platform artifacts, fix library paths
. "${S}/09_verify_build.sh"       # static verification gate
. "${S}/10_write_legal.sh"        # legal/ (licenses + source offer) + build-info
