#!/usr/bin/env bash
set -euo pipefail
# vo-amrwbenc — AMR-WB encoder (Apache-2.0 → version3-only). Enables FFmpeg's
# libvo-amrwbenc. Autotools tarball from SourceForge (like libmp3lame/opencore-amr).
# SOURCED by scripts/build.sh (shares env; appends --enable-* to CONFIGURE_FLAGS).
# Not a standalone script.

[[ "${BUILD_LIBVOAMRWBENC}" == "1" ]] || { echo "Skipping vo-amrwbenc (not needed for ${RID})."; return 0; }

voamr_ver="$(dep_version vo-amrwbenc)"
echo "Building vo-amrwbenc ${voamr_ver} (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf "vo-amrwbenc-${voamr_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://downloads.sourceforge.net/opencore-amr/vo-amrwbenc-${voamr_ver}.tar.gz" -o vo-amrwbenc.tar.gz
tar -xf vo-amrwbenc.tar.gz
cd "vo-amrwbenc-${voamr_ver}" || exit 1

VOAMR_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
[ -n "${CROSS_HOST:-}" ] && VOAMR_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${VOAMR_ARGS[@]}"
make -j"$(${NPROC})"
make install
CONFIGURE_FLAGS+=(--enable-libvo-amrwbenc)
echo "libvo-amrwbenc (AMR-WB encode) enabled."
