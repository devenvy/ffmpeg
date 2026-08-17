#!/usr/bin/env bash
# FreeType — font rasterization (FTL / BSD-like) for the drawtext filter.
# Builds libpng first as a dependency.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_FREETYPE}" == "1" ]]; then
  build_cmake_dep libpng https://github.com/pnggroup/libpng.git v1.6.43 \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  echo "libpng built (freetype dependency)."

  build_cmake_dep freetype https://gitlab.freedesktop.org/freetype/freetype.git VER-2-13-3 \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON
  CONFIGURE_FLAGS+=(--enable-libfreetype)
  echo "freetype (text rendering) enabled."
else
  echo "Skipping freetype."
fi
