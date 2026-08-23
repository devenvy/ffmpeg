#!/usr/bin/env bash
set -euo pipefail
# libpng — PNG image support (libpng license) for FreeType.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_FREETYPE}" == "1" ]]; then
  build_cmake_dep libpng \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  echo "libpng built (freetype dependency)."
else
  echo "Skipping libpng."
fi
