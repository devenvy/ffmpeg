#!/usr/bin/env bash
set -euo pipefail
# nettle — low-level crypto library (dual LGPLv3+/GPLv2+; GPLv2+ option keeps it
# v2-compatible). Provides libnettle + libhogweed (public-key, needs GMP). Dependency
# of GnuTLS; built ONLY for the v2 series (BUILD_GNUTLS). SOURCED by scripts/build.sh.
# Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

NETTLE_VER=3.10
echo "Building nettle ${NETTLE_VER} (static, GnuTLS chain)..."
cd "${WORK_DIR}" || exit 1
rm -rf "nettle-${NETTLE_VER}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VER}.tar.gz" -o nettle.tar.gz
tar -xf nettle.tar.gz
cd "nettle-${NETTLE_VER}" || exit 1
# Finds GMP (built just before) via the explicit include/lib paths. PIC comes from the
# exported CFLAGS (-fPIC on the manylinux builds; default elsewhere).
NETTLE_ARGS=(--prefix="${DEPS_DIR}" --libdir="${DEPS_DIR}/lib"
             --disable-shared --enable-static --disable-documentation
             --with-include-path="${DEPS_DIR}/include" --with-lib-path="${DEPS_DIR}/lib")
[ -n "${CROSS_HOST:-}" ] && NETTLE_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${NETTLE_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "nettle built (GnuTLS dependency)."
