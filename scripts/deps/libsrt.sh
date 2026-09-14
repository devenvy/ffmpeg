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

# -DENABLE_ENCRYPTION=ON is a REQUEST. If find_package(MbedTLS)/GnuTLS resolves to nothing usable
# the crypto layer can end up out of the archive while the build still succeeds and the srt://
# protocol still works -- unencrypted. FFmpeg's -passphrase/-pbkeylen options are NO evidence
# either way: they live in FFmpeg's own libsrt wrapper and are present regardless. The honest
# marker is libsrt's HaiCrypt layer, which is compiled ONLY with ENABLE_ENCRYPTION=ON (verified
# present in the published linux-x64 artifact, which does have encryption).
if [[ "${SRT_ENCLIB:-off}" != "off" ]]; then
  # Locate the archive rather than hardcoding one name: build_cmake_dep installs into
  # ${DEPS_DIR}/lib, but the exact filename is SRT's to choose. A wrong guess here would fail a
  # perfectly good build, which is the failure mode this branch keeps having to correct.
  _srt_a="$(find "${DEPS_DIR}/lib" -maxdepth 1 -name 'libsrt*.a' -print -quit 2>/dev/null || true)"
  if [[ -z "${_srt_a}" ]]; then
    echo "ERROR: libsrt built but no libsrt*.a found under ${DEPS_DIR}/lib -" >&2
    echo "  cannot verify that encryption was compiled in." >&2
    ls -1 "${DEPS_DIR}/lib" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
  fi
  # grep -a, not strings(1): this runs in the BUILD environment, where binutils is not something
  # the package lists guarantee, and grep is. -a treats the archive as text so the match works on
  # a binary; POSIX grep and BusyBox grep both support it.
  if ! grep -aqi haicrypt "${_srt_a}"; then
    echo "ERROR: libsrt was configured with ENABLE_ENCRYPTION=ON and USE_ENCLIB=${SRT_ENCLIB}," >&2
    echo "  but its HaiCrypt layer is not in the archive - srt:// would transport in the clear." >&2
    echo "  Most likely ${SRT_ENCLIB} was not found at configure time." >&2
    exit 1
  fi
  echo "libsrt: encryption verified present (HaiCrypt, enclib=${SRT_ENCLIB})."
fi

# libsrt is C++; add the C++ runtime for FFmpeg's static-pkg-config link (libstdc++ on
# GNU/mingw, libc++ on Apple/NDK) — mirrors chromaprint. srt.pc's Libs.private also lists it,
# but adding it here keeps the ordering right for FFmpeg's configure link tests.
case "${PLATFORM:-linux}" in
  apple|android) EXTRA_LIBS="${EXTRA_LIBS:-} -lc++" ;;
  *)             EXTRA_LIBS="${EXTRA_LIBS:-} ${CXX_RT_LIB--lstdc++}" ;;
esac
CONFIGURE_FLAGS+=(--enable-libsrt)
echo "libsrt (SRT transport, enclib=${SRT_ENCLIB:-off}) enabled."
