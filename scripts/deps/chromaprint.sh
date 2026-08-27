#!/usr/bin/env bash
set -euo pipefail
# chromaprint — audio fingerprinting library (LGPL-2.1). Enables FFmpeg's chromaprint
# muxer. Consumes the kissfft static lib built just before (FFT_LIB=kissfft — the
# avfft/avtx backends would need FFmpeg's own libs, which is circular). C++ — the C++
# runtime is added to EXTRA_LIBS for FFmpeg's static link. FFmpeg finds it via a plain
# -lchromaprint (no pkg-config needed).
# SOURCED by scripts/build.sh (shares env; appends --enable-* to CONFIGURE_FLAGS).
# Not a standalone script.

[[ "${BUILD_CHROMAPRINT}" == "1" ]] || { echo "Skipping chromaprint (not needed for ${RID})."; return 0; }

# FFT_LIB=kissfft: use the external kissfft built earlier (located via find_package,
# with DEPS_DIR on the cmake prefix path from build_cmake_dep). TOOLS/TESTS off.
build_cmake_dep chromaprint \
  -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft

# chromaprint is C++; pkg-config isn't used (FFmpeg links a plain -lchromaprint), so its
# C++ runtime must be added for FFmpeg's static --enable-chromaprint link (libstdc++ on
# GNU/mingw, libc++ on Apple/NDK).
case "${PLATFORM:-linux}" in
  apple|android) EXTRA_LIBS="${EXTRA_LIBS:-} -lc++" ;;
  *)             EXTRA_LIBS="${EXTRA_LIBS:-} -lstdc++" ;;
esac
CONFIGURE_FLAGS+=(--enable-chromaprint)
echo "chromaprint (audio fingerprinting) enabled."
