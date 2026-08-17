#!/usr/bin/env bash
# zimg — high-quality image scaling/colorspace/depth conversion (WTFPL/BSD-ish).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-* to
# CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBZIMG}" == "1" ]] || { echo "Skipping zimg (not needed for ${RID})."; return 0; }

echo "Building zimg (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf zimg
git clone --depth 1 --branch release-3.0.5 --recursive https://github.com/sekrit-twc/zimg.git
cd zimg || exit 1
./autogen.sh

ZIMG_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
case "${RID}" in
  win-x64)       ZIMG_ARGS+=(--host=x86_64-w64-mingw32) ;;
  linux-armhf)   ZIMG_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) ZIMG_ARGS+=(--host=aarch64-linux-android) ;;
  ios-arm64|ios-sim-arm64) ZIMG_ARGS+=(--host=aarch64-apple-darwin) ;;
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
