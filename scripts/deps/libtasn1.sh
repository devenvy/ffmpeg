#!/usr/bin/env bash
set -euo pipefail
# libtasn1 — ASN.1 parsing (LGPLv2.1+). Dependency of GnuTLS; built ONLY for the v2
# series (BUILD_GNUTLS). SOURCED by scripts/build.sh. Not a standalone script.

[[ "${BUILD_GNUTLS}" == "1" ]] || return 0

# Like GnuTLS/nettle, libtasn1's git tag has no pre-generated ./configure (GNU release
# tarballs are bootstrapped before upload; a raw git checkout is not) — stays a tarball
# fetch. Version comes from the ledger (via dep_version), not a hardcoded string.
tasn1_ver="$(dep_version libtasn1)"
echo "Building libtasn1 ${tasn1_ver} (static, GnuTLS chain)..."
cd "${WORK_DIR}" || exit 1
rm -rf "libtasn1-${tasn1_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://ftp.gnu.org/gnu/libtasn1/libtasn1-${tasn1_ver}.tar.gz" -o libtasn1.tar.gz
tar -xf libtasn1.tar.gz
cd "libtasn1-${tasn1_ver}" || exit 1
TASN1_ARGS=(--prefix="${DEPS_DIR}" --libdir="${DEPS_DIR}/lib"
            --disable-shared --enable-static --with-pic --disable-doc)
[ -n "${CROSS_HOST:-}" ] && TASN1_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${TASN1_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "libtasn1 built (GnuTLS dependency)."
