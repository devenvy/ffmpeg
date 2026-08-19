#!/usr/bin/env bash
set -euo pipefail
# GMP — GNU Multiple Precision arithmetic (dual LGPLv3+/GPLv2+; we use the GPLv2+
# option so it is compatible with the v2 license series). Dependency of nettle/GnuTLS,
# so built ONLY for the v2 series (BUILD_GNUTLS), where OpenSSL (Apache-2.0) can't be
# used. SOURCED by scripts/build.sh (shares its environment). Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

GMP_VER=6.3.0
echo "Building GMP ${GMP_VER} (static, GnuTLS chain)..."
cd "${WORK_DIR}" || exit 1
rm -rf "gmp-${GMP_VER}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" -o gmp.tar.xz
tar -xf gmp.tar.xz
cd "gmp-${GMP_VER}" || exit 1
GMP_ARGS=(--prefix="${DEPS_DIR}" --libdir="${DEPS_DIR}/lib"
          --disable-shared --enable-static --with-pic --enable-cxx=no)
[ -n "${CROSS_HOST:-}" ] && GMP_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${GMP_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "GMP built (GnuTLS dependency)."
