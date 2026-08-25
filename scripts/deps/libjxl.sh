#!/usr/bin/env bash
set -euo pipefail
# libjxl — JPEG XL reference codec (BSD-3). Enables FFmpeg's libjxl JPEG XL
# en/decoder. Consumes the brotli, highway, and lcms2 static libs built earlier via
# JPEGXL_FORCE_SYSTEM_* (no vendored submodules). C++ — the C++ runtime is added to
# EXTRA_LIBS for FFmpeg's static link, covering the whole libjxl→highway chain.
# SOURCED by scripts/build.sh. Not a standalone script.

[[ "${BUILD_LIBJXL}" == "1" ]] || { echo "Skipping libjxl (not needed for ${RID})."; return 0; }

# SJPEG + TRANSCODE_JPEG are OFF: they are the lossless JPEG->JXL recompression path
# (FFmpeg's libjxl codec doesn't use it) and SJPEG=ON pulls a third_party/sjpeg submodule
# that a shallow no-submodule clone doesn't have — turning them off keeps us submodule-free.
build_cmake_dep libjxl \
  -DBUILD_TESTING=OFF \
  -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
  -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
  -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_SKCMS=OFF \
  -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF \
  -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
  -DJPEGXL_FORCE_SYSTEM_LCMS2=ON

# libjxl + highway are C++; pkg-config declares no C++ runtime. Add it for FFmpeg's
# static --enable-libjxl link (libstdc++ GNU/mingw, libc++ Apple/NDK).
case "${PLATFORM:-linux}" in
  apple|android) EXTRA_LIBS="${EXTRA_LIBS:-} -lc++" ;;
  *)             EXTRA_LIBS="${EXTRA_LIBS:-} -lstdc++" ;;
esac
CONFIGURE_FLAGS+=(--enable-libjxl)
echo "libjxl (JPEG XL) enabled."
