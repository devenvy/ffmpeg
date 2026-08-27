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
  mbedtls) RIST_ARGS+=(-Duse_mbedtls=true  -Duse_gnutls=false) ;;
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
meson install -C build
CONFIGURE_FLAGS+=(--enable-librist)
echo "librist (RIST transport, crypto=${RIST_CRYPTO:-none}) enabled."
