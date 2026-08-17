#!/usr/bin/env bash
# SVT-AV1 — fast, production-grade AV1 encoder (BSD-3), from AOMedia.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBSVTAV1}" == "1" ]]; then
  SVT_EXTRA=()
  [[ "${RID}" == "win-x64" ]] && SVT_EXTRA+=(
    -DCMAKE_C_FLAGS="-static-libgcc -O2"
    -DCMAKE_CXX_FLAGS="-static-libgcc -static-libstdc++ -O2"
  )

  build_cmake_dep SVT-AV1 https://gitlab.com/AOMediaCodec/SVT-AV1.git v2.2.0 \
    -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF \
    ${SVT_EXTRA[@]+"${SVT_EXTRA[@]}"}
  CONFIGURE_FLAGS+=(--enable-libsvtav1)
  echo "SVT-AV1 (fast AV1 encoder) enabled."
else
  echo "Skipping SVT-AV1 (not needed for ${RID})."
fi
