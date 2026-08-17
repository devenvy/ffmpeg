#!/usr/bin/env bash
# libwebp — WebP image encoder + decoder (BSD-3).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBWEBP}" == "1" ]]; then
  build_cmake_dep libwebp https://chromium.googlesource.com/webm/libwebp.git v1.4.0 \
    -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF
  CONFIGURE_FLAGS+=(--enable-libwebp)
  echo "libwebp (WebP image encoder) enabled."
else
  echo "Skipping libwebp."
fi
