#!/usr/bin/env bash
# AMF — AMD Advanced Media Framework headers (MIT) for AMD hardware
# H.264/H.265 encoding (Windows).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_AMF}" == "1" ]]; then
  echo "Installing AMF headers..."
  cd "${WORK_DIR}" || exit 1
  rm -rf AMF
  git clone --depth 1 https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git
  mkdir -p "${DEPS_DIR}/include/AMF"
  cp -r AMF/amf/public/include/* "${DEPS_DIR}/include/AMF/"
else
  echo "Skipping AMF headers (not needed for ${RID})."
fi
