#!/usr/bin/env bash
set -euo pipefail
# GnuTLS — TLS/https backend (LGPLv2.1+) for the v2 license series, replacing OpenSSL
# (Apache-2.0, which requires --enable-version3 and so can't ship under GPLv2/LGPLv2.1).
# Needs the GnuTLS chain built just before it: GMP + nettle/hogweed + libtasn1. Built
# ONLY where FFmpeg has no OS-native TLS (Linux/Android) AND the series is v2
# (BUILD_GNUTLS). Windows/Apple keep SChannel/SecureTransport. SOURCED by
# scripts/build.sh (appends --enable-gnutls). Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

# GnuTLS's git tag has no pre-generated ./configure (release tarballs are autoreconf'd/
# gnulib-bootstrapped before upload; a raw git checkout is not) — bootstrapping from git
# needs network access to fetch gnulib and is a materially different, more fragile build
# than the vetted release tarball, so this stays a tarball fetch. Version comes from the
# ledger (via dep_version), not a hardcoded string.
gnutls_ver="$(dep_version gnutls)"
echo "Building GnuTLS ${gnutls_ver} (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf "gnutls-${gnutls_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${gnutls_ver}.tar.xz" -o gnutls.tar.xz
tar -xf gnutls.tar.xz
cd "gnutls-${gnutls_ver}" || exit 1
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
# -std=gnu17: GnuTLS bundles a same-vintage gnulib snapshot with K&R prototypes that GCC 15's
# C23 default rejects (same reason as GMP/nettle). The TLS side of random.c — its file-static
# _Thread_local compiled to local-exec (R_ARM_TLS_LE32 / R_X86_64_TPOFF32), which can't link
# into FFmpeg's shared libav*.so — is fixed by the -fPIC export in platform/linux.sh (armhf +
# musl previously lacked it); with -fPIC that TLS var uses a shared-object-safe model, so no
# per-dep TLS-model flag is needed here (verified on armhf gcc-13 and musl gcc-15).
GNUTLS_CFLAGS="${CFLAGS:-} -std=gnu17"
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
