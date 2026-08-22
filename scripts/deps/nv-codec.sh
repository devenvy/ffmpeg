#!/usr/bin/env bash
set -euo pipefail
# nv-codec-headers — NVIDIA codec API headers (MIT) enabling the NVENC / NVDEC
# / CUVID hardware encoders and decoders.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_NVIDIA}" == "1" ]]; then
  echo "Building nv-codec-headers..."
  cd "${WORK_DIR}" || exit 1
  rm -rf nv-codec-headers
  git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git
  cd nv-codec-headers || exit 1
  make install PREFIX="${DEPS_DIR}"
else
  echo "Skipping nv-codec-headers (not needed for ${RID})."
fi
