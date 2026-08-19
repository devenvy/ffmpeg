#!/usr/bin/env bash
set -euo pipefail
# soxr — high-quality audio resampling library (LGPL-2.1).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBSOXR}" == "1" ]] || { echo "Skipping soxr (not needed for ${RID})."; return 0; }

build_cmake_dep soxr https://github.com/dofuuz/soxr.git 0.1.3 \
  -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF
CONFIGURE_FLAGS+=(--enable-libsoxr)
echo "libsoxr (high-quality resampling) enabled."
