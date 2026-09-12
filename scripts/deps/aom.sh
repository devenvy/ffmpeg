#!/usr/bin/env bash
set -euo pipefail
# libaom — AV1 reference encoder + decoder (BSD-2-Clause-Patent), from
# AOMedia.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBAOM}" == "1" ]]; then
  AOM_EXTRA=()
  [[ "${RID}" == "linux-armhf" ]] && AOM_EXTRA+=(-DAOM_TARGET_CPU=arm)

  # ENABLE_APPS gates aomenc/aomdec and is SEPARATE from ENABLE_EXAMPLES -- aom's
  # CMakeLists builds apps/aomenc.c under its own if(ENABLE_APPS). We consume only
  # libaom, never the CLI tools, and building them broke musl on v3.15.0:
  #   aomenc.c:765: error: implicit declaration of function 'fseeko'
  # musl does not declare fseeko/ftello without the large-file feature macros that
  # glibc supplies more loosely. Turning the apps off fixes it at the root and skips
  # work whose output we discard anyway.
  build_cmake_dep aom \
    -DENABLE_APPS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TOOLS=OFF -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF \
    ${AOM_EXTRA[@]+"${AOM_EXTRA[@]}"}
  CONFIGURE_FLAGS+=(--enable-libaom)
  echo "libaom (AV1 encoder/decoder) enabled."
else
  echo "Skipping libaom."
fi
