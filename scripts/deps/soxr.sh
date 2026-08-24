#!/usr/bin/env bash
set -euo pipefail
# soxr — high-quality audio resampling library (LGPL-2.1).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBSOXR}" == "1" ]] || { echo "Skipping soxr (not needed for ${RID})."; return 0; }

build_cmake_dep soxr \
  -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF

# soxr links libm; make sure FFmpeg's static configure test for -lsoxr sees it.
# (If the resampler check still fails in a local build despite this, fall back
# to adding -lm to FFmpeg's --extra-libs in 07_build_ffmpeg.sh, gated on
# BUILD_LIBSOXR, instead of/alongside this .pc fix.)
SOXR_PC="${DEPS_DIR}/lib/pkgconfig/soxr.pc"
if [[ -f "${SOXR_PC}" ]] && ! grep -q 'Libs.private:.*-lm' "${SOXR_PC}"; then
  printf 'Libs.private: -lm\n' >> "${SOXR_PC}"
fi

CONFIGURE_FLAGS+=(--enable-libsoxr)
echo "libsoxr (high-quality resampling) enabled."
