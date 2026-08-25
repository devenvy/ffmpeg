#!/usr/bin/env bash
set -euo pipefail
# brotli — general-purpose compression (MIT). Build dependency of libjxl; not
# consumed by FFmpeg directly (no --enable-* flag). Installs libbrotli{common,enc,
# dec} + pkg-config into DEPS_DIR for libjxl's JPEGXL_FORCE_SYSTEM_BROTLI. SOURCED
# by scripts/build.sh. Not a standalone script.

[[ "${BUILD_BROTLI}" == "1" ]] || { echo "Skipping brotli (not needed for ${RID})."; return 0; }

build_cmake_dep brotli \
  -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUNDLED_MODE=OFF

echo "brotli (libjxl dependency) built."
