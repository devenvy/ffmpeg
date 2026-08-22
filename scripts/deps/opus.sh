#!/usr/bin/env bash
set -euo pipefail
# libopus — Opus audio encoder + decoder (BSD-3).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBOPUS}" == "1" ]]; then
  build_cmake_dep opus https://github.com/xiph/opus.git v1.5.2 \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  CONFIGURE_FLAGS+=(--enable-libopus)
  echo "libopus (Opus audio encoder) enabled."
else
  echo "Skipping libopus."
fi
