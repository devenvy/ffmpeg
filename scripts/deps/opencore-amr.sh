#!/usr/bin/env bash
set -euo pipefail
# opencore-amr — AMR-NB en/decode + AMR-WB decode (Apache-2.0 → version3-only).
# Enables FFmpeg's libopencore-amrnb + libopencore-amrwb. Autotools tarball from
# SourceForge (like libmp3lame). SOURCED by scripts/build.sh (shares env; appends
# --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBOPENCORE_AMR}" == "1" ]] || { echo "Skipping opencore-amr (not needed for ${RID})."; return 0; }

amr_ver="$(dep_version opencore-amr)"
echo "Building opencore-amr ${amr_ver} (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf "opencore-amr-${amr_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://downloads.sourceforge.net/opencore-amr/opencore-amr-${amr_ver}.tar.gz" -o opencore-amr.tar.gz
tar -xf opencore-amr.tar.gz
cd "opencore-amr-${amr_ver}" || exit 1

AMR_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic)
[ -n "${CROSS_HOST:-}" ] && AMR_ARGS+=(--host="${CROSS_HOST}")   # cross triple resolved in 02_configure
./configure "${AMR_ARGS[@]}"
make -j"$(${NPROC})"
make install
CONFIGURE_FLAGS+=(--enable-libopencore-amrnb --enable-libopencore-amrwb)
echo "libopencore-amrnb + libopencore-amrwb (AMR-NB/WB) enabled."
