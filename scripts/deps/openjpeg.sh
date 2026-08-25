#!/usr/bin/env bash
set -euo pipefail
# openjpeg — JPEG 2000 codec (BSD-2). Enables FFmpeg's external libopenjpeg
# JPEG 2000 en/decoder. SOURCED by scripts/build.sh (shares env; appends
# --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBOPENJPEG}" == "1" ]] || { echo "Skipping openjpeg (not needed for ${RID})."; return 0; }

# Core libopenjp2 only: -DBUILD_CODEC=OFF drops the CLI tools (which pull png/tiff).
build_cmake_dep openjpeg \
  -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF

CONFIGURE_FLAGS+=(--enable-libopenjpeg)
echo "libopenjpeg (JPEG 2000) enabled."
