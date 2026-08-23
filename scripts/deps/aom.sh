#!/usr/bin/env bash
set -euo pipefail
# libaom — AV1 reference encoder + decoder (BSD-2-Clause-Patent), from
# AOMedia.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBAOM}" == "1" ]]; then
  AOM_EXTRA=()
  [[ "${RID}" == "linux-armhf" ]] && AOM_EXTRA+=(-DAOM_TARGET_CPU=arm)

  build_cmake_dep aom \
    -DENABLE_EXAMPLES=OFF -DENABLE_TOOLS=OFF -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF \
    ${AOM_EXTRA[@]+"${AOM_EXTRA[@]}"}
  CONFIGURE_FLAGS+=(--enable-libaom)
  echo "libaom (AV1 encoder/decoder) enabled."
else
  echo "Skipping libaom."
fi
