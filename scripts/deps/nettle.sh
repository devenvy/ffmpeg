#!/usr/bin/env bash
set -euo pipefail
# nettle — low-level crypto library (dual LGPLv3+/GPLv2+; GPLv2+ option keeps it
# v2-compatible). Provides libnettle + libhogweed (public-key, needs GMP). Dependency
# of GnuTLS; built ONLY for the v2 series (BUILD_GNUTLS). SOURCED by scripts/build.sh.
# Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

# Like GnuTLS, nettle's git tag has no pre-generated ./configure (GNU release tarballs
# are bootstrapped before upload; a raw git checkout is not) — stays a tarball fetch.
# Version comes from the ledger (via dep_version), not a hardcoded string.
nettle_ver="$(dep_version nettle)"
echo "Building nettle ${nettle_ver} (static, GnuTLS chain)..."
cd "${WORK_DIR}" || exit 1
rm -rf "nettle-${nettle_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://ftp.gnu.org/gnu/nettle/nettle-${nettle_ver}.tar.gz" -o nettle.tar.gz
tar -xf nettle.tar.gz
cd "nettle-${nettle_ver}" || exit 1
# Finds GMP (built just before) via the explicit include/lib paths. PIC comes from the
# exported CFLAGS (-fPIC on the manylinux builds; default elsewhere).
NETTLE_ARGS=(--prefix="${DEPS_DIR}" --libdir="${DEPS_DIR}/lib"
             --disable-shared --enable-static --disable-documentation
             --with-include-path="${DEPS_DIR}/include" --with-lib-path="${DEPS_DIR}/lib")
[ -n "${CROSS_HOST:-}" ] && NETTLE_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
# nettle's bundled getopt.c/getopt.h use K&R empty-paren prototypes (getopt()/getenv()).
# GCC 15 defaults to C23 where `()` == `(void)`, turning the real calls into hard errors
# ("too many arguments to function 'getenv'"). Pin the C standard to gnu17. Same GCC-15/C23
# issue as GMP; surfaced on Alpine (rolling GCC). Harmless on the older glibc/manylinux GCC.
CFLAGS="${CFLAGS:-} -std=gnu17" ./configure "${NETTLE_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "nettle built (GnuTLS dependency)."
