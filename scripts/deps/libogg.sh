#!/usr/bin/env bash
# libogg — Ogg bitstream container (BSD-3); a build dependency of libvorbis.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBVORBIS}" == "1" ]] || return 0

echo "Building libogg (static)..."
cd "${WORK_DIR}"
rm -rf ogg
git clone --depth 1 --branch v1.3.5 https://github.com/xiph/ogg.git
cd ogg
./autogen.sh
OGG_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
case "${RID}" in
  win-x64)       OGG_ARGS+=(--host=x86_64-w64-mingw32) ;;
  linux-armhf)   OGG_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) OGG_ARGS+=(--host=aarch64-linux-android) ;;
  ios-arm64|ios-sim-arm64) OGG_ARGS+=(--host=aarch64-apple-darwin) ;;
esac
./configure "${OGG_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "libogg built (libvorbis dependency)."
