#!/usr/bin/env bash
# libmp3lame (LAME) — MP3 audio encoder (LGPL-2.0). SOURCED by scripts/build.sh
# (shares its environment; appends its --enable-* to CONFIGURE_FLAGS where
# applicable). Not a standalone script.

[[ "${BUILD_LIBMP3LAME}" == "1" ]] || { echo "Skipping libmp3lame (not needed for ${RID})."; return 0; }

echo "Building libmp3lame (static)..."
cd "${WORK_DIR}"
rm -rf lame-3.100
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" -o lame.tar.gz
tar -xf lame.tar.gz
cd lame-3.100
# LAME 3.100 exports lame_init_old in its symbol file but no longer defines it,
# which breaks the link on strict toolchains. Drop it.
sed -i '/lame_init_old/d' include/libmp3lame.sym

LAME_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --disable-frontend --enable-nasm --with-pic)
case "${RID}" in
  win-x64)       LAME_ARGS+=(--host=x86_64-w64-mingw32) ;;
  linux-armhf)   LAME_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) LAME_ARGS+=(--host=aarch64-linux-android) ;;
esac
./configure "${LAME_ARGS[@]}"
make -j"$(${NPROC})"
make install
CONFIGURE_FLAGS+=(--enable-libmp3lame)
echo "libmp3lame (MP3 encode) enabled."
