#!/usr/bin/env bash
set -euo pipefail
# librist — Reliable Internet Stream Transport (BSD-2-Clause; all cells). Enables FFmpeg's
# rist:// protocol. librist CANNOT use OpenSSL — only mbedTLS or GnuTLS/nettle — which is the
# reason the v3 cells carry an external mbedTLS at all. Encryption backend per cell via
# RIST_CRYPTO (set in 04_select_license): mbedtls on v3, gnutls on gpl-2 Linux/Android, none
# on the nocrypto cells. Vendored lz4 + cJSON (builtin_*) keep it self-contained; the external
# mbedTLS we built is used (builtin_mbedtls=false). meson (uses MESON_CROSS_FILE for cross).
# SOURCED by scripts/build.sh (shares env; appends --enable-librist). Not a standalone script.

[[ "${BUILD_LIBRIST}" == "1" ]] || { echo "Skipping librist (not needed for ${RID})."; return 0; }

echo "Building librist (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf librist
clone_dep librist "${WORK_DIR}/librist"
cd librist || exit 1

# Vendored lz4 + cJSON (we don't ship those as system deps); external mbedTLS (builtin off).
RIST_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static --buildtype=release
           -Dbuilt_tools=false -Dtest=false
           -Dbuiltin_cjson=true -Dbuiltin_lz4=true -Dbuiltin_mbedtls=false)
case "${RIST_CRYPTO:-none}" in
  # cmake_prefix_path makes our pinned mbedTLS findable ON A NATIVE BUILD. It does nothing for a
  # cross build -- measured: meson's cmake dependency lookup cannot see our prefix cross via
  # -Dcmake_prefix_path, CMAKE_PREFIX_PATH, or [properties] cmake_prefix_path, though all three
  # work natively. Cross builds are covered instead by the -I/-L search paths 05_write_toolchain.sh
  # now writes into every cross file, which let librist's cc.find_library fallback succeed. Both
  # halves are needed; the guard after the build proves whichever one applied. librist resolves it with
  #     dependency('MbedTLS', method: 'cmake', modules: ['MbedTLS::mbedcrypto'])
  # -- a CMake package lookup, NOT pkg-config (a comment in mbedtls.sh said pkg-config; that is
  # wrong for this consumer). Nothing else points meson's CMake search at DEPS_DIR: the cross
  # files set pkg_config_libdir only, and a native build has no reason to look there either. So
  # the lookup missed, the cc.find_library('mbedcrypto') fallback missed too (no -L for DEPS_DIR),
  # and librist quietly compiled its own vendored copy instead -- which the guard after the build
  # now catches. Measured on win-arm64 v3 before this was added.
  mbedtls) RIST_ARGS+=(-Duse_mbedtls=true  -Duse_gnutls=false "-Dcmake_prefix_path=${DEPS_DIR}") ;;
  gnutls)  RIST_ARGS+=(-Duse_mbedtls=false -Duse_gnutls=true)  ;;
  *)       RIST_ARGS+=(-Duse_mbedtls=false -Duse_gnutls=false) ;;
esac
# On Windows, librist's rist_time.c calls clock_gettime, which the mingw-w64 toolchain provides in
# winpthreads (not as the static-inline librist assumes) — so link fails with undefined clock_gettime
# unless we opt into mingw pthreads. This makes librist link -lpthread (winpthreads); it lands in
# librist.pc, where 07_build_ffmpeg's .pc patch wraps it -Bstatic (no libwinpthread-1.dll runtime dep).
[[ "${PLATFORM:-}" == "windows" ]] && RIST_ARGS+=(-Dhave_mingw_pthreads=true)
[[ -n "${MESON_CROSS_FILE:-}" ]] && RIST_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${RIST_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
# -Dbuiltin_mbedtls=false is a REQUEST, and librist does not fail when it cannot be honoured.
# contrib/mbedtls/meson.build resolves the external library as
#     dependency('MbedTLS', method: 'cmake', modules: ['MbedTLS::mbedcrypto'])
# falling back to cc.find_library('mbedcrypto'), and if BOTH miss it simply sets
# builtin_mbedtls = true and compiles its own vendored copy from contrib/mbedtls/library/*.c.
#
# So the failure mode is not "rist:// in the clear" -- encryption still works. It is that the
# artifact would carry an UNPINNED, un-Renovate-tracked mbedTLS vendored inside librist instead
# of the version deps.json pins, silently diverging from the ledger that the whole dependency
# policy rests on.
#
# The vendored path is unambiguous in the build tree: it declares static_library('mbedcrypto'),
# so a libmbedcrypto.a under build/ means the external one was not found. Checked after compile,
# because that is when the library would exist. (An earlier version of this check queried meson's
# intro-dependencies.json, which cannot see the cc.find_library fallback at all.)
if [[ "${RIST_CRYPTO:-none}" == "mbedtls" ]]; then
  _rist_vendored="$(find build -name 'libmbedcrypto.a' -print -quit 2>/dev/null || true)"
  if [[ -n "${_rist_vendored}" ]]; then
    echo "ERROR: librist fell back to its VENDORED mbedTLS (${_rist_vendored})." >&2
    echo "  -Dbuiltin_mbedtls=false was set, so our pinned mbedTLS should have been found." >&2
    echo "  The artifact would ship an unpinned crypto library that deps.json does not track." >&2
    exit 1
  fi
  echo "librist: linked the external pinned mbedTLS (no vendored copy built)."
fi
meson install -C build
CONFIGURE_FLAGS+=(--enable-librist)
echo "librist (RIST transport, crypto=${RIST_CRYPTO:-none}) enabled."
