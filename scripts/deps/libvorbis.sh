#!/usr/bin/env bash
# libvorbis — Vorbis audio encoder + decoder (BSD-3). Requires libogg.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBVORBIS}" == "1" ]] || { echo "Skipping libvorbis (not needed for ${RID})."; return 0; }

echo "Building libvorbis (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf vorbis
git clone --depth 1 --branch v1.3.7 https://github.com/xiph/vorbis.git
cd vorbis || exit 1
./autogen.sh
VORBIS_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-ogg="${DEPS_DIR}" --with-pic)
case "${RID}" in
  win-x64)       VORBIS_ARGS+=(--host=x86_64-w64-mingw32) ;;
  linux-armhf)   VORBIS_ARGS+=(--host=arm-linux-gnueabihf) ;;
  android-arm64) VORBIS_ARGS+=(--host=aarch64-linux-android) ;;
  ios-arm64|ios-sim-arm64) VORBIS_ARGS+=(--host=aarch64-apple-darwin) ;;
esac
./configure "${VORBIS_ARGS[@]}"
# Build and install the LIBRARIES ONLY (same idiom as kvazaar.sh). libvorbis's
# configure injects -force_cpusubtype_ALL into CFLAGS on Darwin — an obsolete flag
# that modern (Xcode 26+) ld rejects at LINK time — so building any of libvorbis's
# example/analysis executables breaks the macOS/iOS builds. The .a archives never
# invoke ld (they are ar'd), so we build just the three .la targets and install them
# + headers + pkg-config, skipping every executable. Also faster on all platforms.
# (A recursive `SUBDIRS=` override can't be used: make propagates it into the
# sub-makes, which then try to enter subdirs that don't exist there and fail.)
make -j"$(${NPROC})" -C lib libvorbis.la libvorbisenc.la libvorbisfile.la
make -C lib install-libLTLIBRARIES
make -C include install
make install-pkgconfigDATA
CONFIGURE_FLAGS+=(--enable-libvorbis)
echo "libvorbis (Vorbis audio) enabled."
