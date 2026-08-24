#!/usr/bin/env bash
set -euo pipefail
# libxml2 — XML parser (MIT). Enables FFmpeg's DASH demuxer + IMF.
# SOURCED by scripts/build.sh (shares env; appends --enable-* to CONFIGURE_FLAGS).
# Not a standalone script.

[[ "${BUILD_LIBXML2}" == "1" ]] || { echo "Skipping libxml2 (not needed for ${RID})."; return 0; }

# Minimal static build: no python/icu/lzma; keep zlib (already built) for DASH.
build_cmake_dep libxml2 \
  -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_ZLIB=ON -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_MODULES=OFF
CONFIGURE_FLAGS+=(--enable-libxml2)
echo "libxml2 (DASH/IMF demuxing) enabled."
