#!/usr/bin/env bash
set -euo pipefail
# libsrt — Secure Reliable Transport (MPL-2.0; dynamic-linked → fine on every cell). Enables
# FFmpeg's srt:// protocol. Encryption backend is chosen per license cell via SRT_ENCLIB
# (set in 04_select_license): mbedtls on v3, gnutls on gpl-2 Linux/Android, off on the
# nocrypto cells (lgpl-2 everywhere + gpl-2 Win/Apple). C++ → its runtime is appended to
# EXTRA_LIBS for FFmpeg's link. cmake (build_cmake_dep). FFmpeg finds it via pkg-config `srt`.
# SOURCED by scripts/build.sh (shares env; appends --enable-libsrt). Not a standalone script.

[[ "${BUILD_LIBSRT}" == "1" ]] || { echo "Skipping libsrt (not needed for ${RID})."; return 0; }

# Static lib, no apps/tests. Encryption per the crypto map; nocrypto cells configure cleanly
# with ENABLE_ENCRYPTION=OFF (SRT still transports, just without AES).
SRT_ARGS=(-DENABLE_APPS=OFF -DENABLE_SHARED=OFF -DENABLE_STATIC=ON)
case "${SRT_ENCLIB:-off}" in
  mbedtls|gnutls) SRT_ARGS+=(-DENABLE_ENCRYPTION=ON -DUSE_ENCLIB="${SRT_ENCLIB}") ;;
  *)              SRT_ARGS+=(-DENABLE_ENCRYPTION=OFF) ;;
esac
# On the Android NDK toolchain, find_library only searches CMAKE_FIND_ROOT_PATH (pointed at the
# NDK sysroot), so SRT's find_package(MbedTLS) can't see our mbedTLS in DEPS_DIR. Add DEPS_DIR to
# the root path — the NDK toolchain appends its own sysroot, so both are searched. (Other RIDs set
# CMAKE_FIND_ROOT_PATH=DEPS_DIR in their toolchain file already; only the NDK's overrides it.)
[[ "${PLATFORM:-}" == "android" && "${SRT_ENCLIB:-off}" == "mbedtls" ]] && SRT_ARGS+=(-DCMAKE_FIND_ROOT_PATH="${DEPS_DIR}")
build_cmake_dep srt "${SRT_ARGS[@]}"

# libsrt is C++; add the C++ runtime for FFmpeg's static-pkg-config link (libstdc++ on
# GNU/mingw, libc++ on Apple/NDK) — mirrors chromaprint. srt.pc's Libs.private also lists it,
# but adding it here keeps the ordering right for FFmpeg's configure link tests.
case "${PLATFORM:-linux}" in
  apple|android) EXTRA_LIBS="${EXTRA_LIBS:-} -lc++" ;;
  *)             EXTRA_LIBS="${EXTRA_LIBS:-} -lstdc++" ;;
esac
CONFIGURE_FLAGS+=(--enable-libsrt)
echo "libsrt (SRT transport, enclib=${SRT_ENCLIB:-off}) enabled."
