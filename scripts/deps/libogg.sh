#!/usr/bin/env bash
set -euo pipefail
# libogg — Ogg bitstream container (BSD-3); a build dependency of libvorbis.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBVORBIS}" == "1" ]] || return 0

echo "Building libogg (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf ogg
clone_dep libogg "${WORK_DIR}/ogg"
cd ogg || exit 1
./autogen.sh
OGG_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
[ -n "${CROSS_HOST:-}" ] && OGG_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${OGG_ARGS[@]}"
make -j"$(${NPROC})"
make install
echo "libogg built (libvorbis dependency)."
