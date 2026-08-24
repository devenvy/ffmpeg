#!/usr/bin/env bash
set -euo pipefail
# soxr — high-quality audio resampling library (LGPL-2.1).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBSOXR}" == "1" ]] || { echo "Skipping soxr (not needed for ${RID})."; return 0; }

build_cmake_dep soxr \
  -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF

# FFmpeg links libsoxr via a hardcoded -lsoxr (it does not use soxr's pkg-config),
# so soxr's libm dependency (log/pow in its FFT code) must be added to FFmpeg's
# own link explicitly, or the --enable-libsoxr configure check fails to link.
EXTRA_LIBS="${EXTRA_LIBS:-} -lm"

CONFIGURE_FLAGS+=(--enable-libsoxr)
echo "libsoxr (high-quality resampling) enabled."
