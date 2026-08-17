#!/usr/bin/env bash
# libvorbis — Vorbis audio encoder + decoder (BSD-3). Requires libogg.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBVORBIS}" == "1" ]] || { echo "Skipping libvorbis (not needed for ${RID})."; return 0; }

echo "Building libvorbis (static)..."
cd "${WORK_DIR}"
rm -rf vorbis
git clone --depth 1 --branch v1.3.7 https://github.com/xiph/vorbis.git
cd vorbis
./autogen.sh
VORBIS_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-ogg="${DEPS_DIR}" --with-pic)
case "${RID}" in
  win-x64)       VORBIS_ARGS+=(--host=x86_64-w64-mingw32) ;;
  linux-armhf)   VORBIS_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) VORBIS_ARGS+=(--host=aarch64-linux-android) ;;
esac
./configure "${VORBIS_ARGS[@]}"
make -j"$(${NPROC})"
make install
CONFIGURE_FLAGS+=(--enable-libvorbis)
echo "libvorbis (Vorbis audio) enabled."
