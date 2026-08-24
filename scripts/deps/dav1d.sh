#!/usr/bin/env bash
set -euo pipefail
# dav1d — fast AV1 video decoder (BSD-2-Clause), from VideoLAN.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

[[ "${BUILD_LIBDAV1D}" == "1" ]] || { echo "Skipping dav1d (not needed for ${RID})."; return 0; }

echo "Building dav1d (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf dav1d
clone_dep dav1d "${WORK_DIR}/dav1d"
cd dav1d || exit 1

DAV1D_ARGS=(
  --prefix="${DEPS_DIR}"
  --libdir=lib
  --default-library=static
  --buildtype=release
  -Denable_tools=false
  -Denable_tests=false
)
# Cross targets provide a Meson cross file (written in step 05); native builds don't.
[[ -n "${MESON_CROSS_FILE:-}" ]] && DAV1D_ARGS+=(--cross-file "${MESON_CROSS_FILE}")

meson setup build "${DAV1D_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build

CONFIGURE_FLAGS+=(--enable-libdav1d)
echo "dav1d (fast AV1 decode) enabled."
