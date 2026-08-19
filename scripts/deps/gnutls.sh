#!/usr/bin/env bash
set -euo pipefail
# GnuTLS — TLS/https backend (LGPLv2.1+) for the v2 license series, replacing OpenSSL
# (Apache-2.0, which requires --enable-version3 and so can't ship under GPLv2/LGPLv2.1).
# Needs the GnuTLS chain built just before it: GMP + nettle/hogweed + libtasn1. Built
# ONLY where FFmpeg has no OS-native TLS (Linux/Android) AND the series is v2
# (BUILD_GNUTLS). Windows/Apple keep SChannel/SecureTransport. SOURCED by
# scripts/build.sh (appends --enable-gnutls). Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

GNUTLS_VER=3.8.6
echo "Building GnuTLS ${GNUTLS_VER} (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf "gnutls-${GNUTLS_VER}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${GNUTLS_VER}.tar.xz" -o gnutls.tar.xz
tar -xf gnutls.tar.xz
cd "gnutls-${GNUTLS_VER}" || exit 1
# nettle/hogweed/libtasn1 are found via pkg-config (PKG_CONFIG_PATH=${DEPS_DIR}/lib/
# pkgconfig, set in 05). GMP has no .pc, so point at it explicitly. The many --without-*
# flags drop optional deps we don't ship (p11-kit, idn, tpm, zlib/brotli/zstd) and the
# --with-included-* use GnuTLS's bundled unistring; libtasn1 is our static build.
GNUTLS_ARGS=(--prefix="${DEPS_DIR}" --libdir="${DEPS_DIR}/lib"
             --disable-shared --enable-static
             --with-included-unistring --with-included-libtasn1=no --without-p11-kit
             --disable-doc --disable-tests --disable-tools --disable-cxx --disable-nls
             --without-idn --without-tpm --without-tpm2 --without-zlib --without-brotli --without-zstd)
[ -n "${CROSS_HOST:-}" ] && GNUTLS_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
# GnuTLS's random.c uses a hidden __thread variable. Even with -fPIC (exported globally
# for static deps), GCC emits the LOCAL-EXEC TLS model for it (R_ARM_TLS_LE32 on armhf,
# R_AARCH64_TLSLE_* on arm64) — which the linker refuses inside a shared object ("relocation
# not permitted in shared object"). This .a is linked into FFmpeg's shared libav*.so, so
# force the general-dynamic TLS model, valid in a shared library on every arch. (x86-64
# happens to tolerate local-exec here; 32-bit ARM does not — surfaced by linux-armhf.)
# -std=gnu17 for the same GCC-15/C23 reason as GMP/nettle: GnuTLS bundles a same-vintage
# gnulib snapshot with K&R prototypes that C23 rejects. (validated building with the flag.)
GNUTLS_CFLAGS="${CFLAGS:-} -std=gnu17 -ftls-model=global-dynamic"
CFLAGS="${GNUTLS_CFLAGS}" \
GMP_CFLAGS="-I${DEPS_DIR}/include" GMP_LIBS="-L${DEPS_DIR}/lib -lgmp" \
  ./configure "${GNUTLS_ARGS[@]}"
# Build and install ONLY the library (gl = its bundled gnulib, then lib = libgnutls), NOT
# src/. --disable-tools stops the command-line programs from linking, but GnuTLS still
# compiles src/gl (the TOOLS' gnulib: parse-datetime/nstrftime), which calls glibc-only
# time helpers (mktime_z, tzalloc, localtime_rz) that Bionic lacks — a hard error on Android.
# FFmpeg only needs libgnutls + gnutls.pc + headers, all produced by lib/, so skip src
# entirely. (Also faster; verified end-to-end that lib-only installs gnutls.pc + headers.)
make -C gl -j"$(${NPROC})"
make -C lib -j"$(${NPROC})"
make -C lib install
CONFIGURE_FLAGS+=(--enable-gnutls)
echo "GnuTLS (TLS/https) enabled."
