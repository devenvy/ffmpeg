#!/usr/bin/env bash
set -euo pipefail
# zimg — high-quality image scaling/colorspace/depth conversion (WTFPL/BSD-ish).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-* to
# CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBZIMG}" == "1" ]] || { echo "Skipping zimg (not needed for ${RID})."; return 0; }

echo "Building zimg (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf zimg
clone_dep zimg "${WORK_DIR}/zimg"
git -C "${WORK_DIR}/zimg" submodule update --init --recursive
cd zimg || exit 1
./autogen.sh

ZIMG_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
case "${RID}" in
  win-x64)       ZIMG_ARGS+=(--host=x86_64-w64-mingw32) ;;
    win-arm64)
      # zimg 3.0.6 has two mingw-on-ARM bugs, both reproduced by cross-building it locally:
      #  1. src/zimg/api/zimg.cpp uses std::exception_ptr without including <exception>. That
      #     compiles under libstdc++, which pulls it in transitively; llvm-mingw uses libc++,
      #     which does not, so every EX_END macro fails. Force the include.
      #  2. src/zimg/common/arm/cpuinfo_arm.cpp includes <Windows.h> with a capital W.
      #     mingw-w64 ships windows.h lowercase, which only works on a case-insensitive
      #     filesystem, so a Linux cross-build cannot find it. A one-line shim header on the
      #     include path fixes it while keeping zimg's NEON paths (--disable-simd would not).
      # Both are fixed in zimg main; drop this when the ledger pin moves past 3.0.6.
      ZIMG_COMPAT="${WORK_DIR}/zimg-compat"
      mkdir -p "${ZIMG_COMPAT}"
      printf '#pragma once\n#include <windows.h>\n' > "${ZIMG_COMPAT}/Windows.h"
      ZIMG_ARGS+=(--host=aarch64-w64-mingw32
                  CXXFLAGS="-O2 -include exception -I${ZIMG_COMPAT}")
      ;;
  linux-armhf)   ZIMG_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) ZIMG_ARGS+=(--host=aarch64-linux-android) ;;
  android-x64)   ZIMG_ARGS+=(--host=x86_64-linux-android) ;;
  ios-arm64|ios-sim-arm64|maccatalyst-arm64) ZIMG_ARGS+=(--host=aarch64-apple-darwin) ;;
  maccatalyst-x64)         ZIMG_ARGS+=(--host=x86_64-apple-darwin) ;;
esac
./configure "${ZIMG_ARGS[@]}"
make -j"$(${NPROC})"
make install

# zimg's installed pkg-config omits -lm from Libs.private, so FFmpeg's static
# link test fails (--as-needed drops libm despite log10f etc. being used). Add it.
# -i.bak (explicit backup suffix) is portable: BSD/macOS sed requires an argument
# after -i, GNU's bare `sed -i` does not — the attached-suffix form works on both.
sed -i.bak 's/^Libs.private:.*/Libs.private: -lstdc++ -lm/' "${DEPS_DIR}/lib/pkgconfig/zimg.pc"
rm -f "${DEPS_DIR}/lib/pkgconfig/zimg.pc.bak"

CONFIGURE_FLAGS+=(--enable-libzimg)
echo "libzimg (high-quality scaling) enabled."
