#!/usr/bin/env bash
set -euo pipefail
# zlib — DEFLATE compression (Zlib license); used by PNG, HTTP gzip, Matroska
# and more.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_ZLIB}" == "1" ]]; then
  echo "Building zlib (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf zlib
  git clone --depth 1 --branch v1.3.1 https://github.com/madler/zlib.git
  cd zlib || exit 1

  case "${RID}" in
    linux-armhf)
      CC=arm-linux-gnueabihf-gcc CHOST=arm-linux-gnueabihf \
        ./configure --prefix="${DEPS_DIR}" --static
      ;;
    win-x64)
      CC="${CROSS_PREFIX}-gcc" AR="${CROSS_PREFIX}-ar" RANLIB="${CROSS_PREFIX}-ranlib" \
        CHOST="${CROSS_PREFIX}" \
        ./configure --prefix="${DEPS_DIR}" --static
      ;;
    android-arm64|ios-arm64|ios-sim-arm64)
      CFLAGS="${EXTRA_CFLAGS:-}" ./configure --prefix="${DEPS_DIR}" --static
      ;;
    *)
      ./configure --prefix="${DEPS_DIR}" --static
      ;;
  esac

  make -j"$(${NPROC})"
  make install
  CONFIGURE_FLAGS+=(--enable-zlib)
  echo "zlib enabled."
else
  echo "Skipping zlib."
fi
