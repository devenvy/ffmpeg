#!/usr/bin/env bash
set -euo pipefail
# OpenSSL — TLS/https backend for FFmpeg (Apache-2.0; GPL/LGPL-compatible, so no
# --enable-nonfree needed). Built only where the OS gives FFmpeg no usable TLS:
# Linux and Android. Windows uses SChannel and Apple uses SecureTransport, both
# OS-native and enabled directly in 02_configure. SOURCED by scripts/build.sh
# (shares its environment; appends --enable-openssl). Not a standalone script.

[[ "${BUILD_OPENSSL}" == "1" ]] || { echo "Skipping OpenSSL (native TLS backend on ${RID})."; return 0; }

echo "Building OpenSSL (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf openssl
clone_dep openssl "${WORK_DIR}/openssl"

# OpenSSL drives its own toolchain (Configure target + CROSS_COMPILE / NDK env),
# not autotools --host. Do the whole configure/build in a subshell so those env
# changes never leak into the deps built after this one.
(
  cd openssl || exit 1
  # Static libs, PIC (they link into FFmpeg's shared objects), no apps/tests/docs.
  OSSL_OPTS=(no-shared no-apps no-tests no-docs -fPIC
             --prefix="${DEPS_DIR}" --openssldir="${DEPS_DIR}/ssl" --libdir=lib)
  case "${RID}" in
    linux-x64|linux-musl-x64) OSSL_TARGET=linux-x86_64 ;;
    linux-arm64)              OSSL_TARGET=linux-aarch64 ;;
    linux-armhf)              OSSL_TARGET=linux-armv4; export CROSS_COMPILE=arm-linux-gnueabihf- ;;
    android-arm64)
      OSSL_TARGET=android-arm64
      # Let OpenSSL's android target pick the NDK clang via PATH; our exported
      # CC/AR/etc. (the aarch64 wrappers) would confuse its own detection.
      unset CC CXX AR RANLIB NM STRIP
      export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
      export PATH="${TOOLCHAIN}/bin:${PATH}"
      OSSL_OPTS+=("-D__ANDROID_API__=${API}")
      ;;
    *) echo "OpenSSL: unexpected RID ${RID}" >&2; exit 1 ;;
  esac
  ./Configure "${OSSL_TARGET}" "${OSSL_OPTS[@]}"
  make -j"$(${NPROC})"
  make install_sw   # libs + headers + pkg-config, no man pages
)

# OpenSSL 3.x is Apache-2.0, which requires FFmpeg's --enable-version3 to link
# under (L)GPL (it is incompatible with v2.1/v2). That flag is applied
# unconditionally in 04_select_license.sh — every build is (L)GPLv3 — so it is
# deliberately NOT added here.
CONFIGURE_FLAGS+=(--enable-openssl)
echo "OpenSSL (TLS/https) enabled."
