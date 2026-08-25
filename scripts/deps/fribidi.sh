#!/usr/bin/env bash
set -euo pipefail
# fribidi — Unicode bidirectional text algorithm (LGPL-2.1); a libass dependency.
# SOURCED by scripts/build.sh (uses MESON_CROSS_FILE for cross targets). Also
# enables FFmpeg's --enable-libfribidi (drawtext bidirectional text). Not a
# standalone script.

[[ "${BUILD_LIBASS}" == "1" ]] || return 0

echo "Building fribidi (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf fribidi
clone_dep fribidi "${WORK_DIR}/fribidi"
cd fribidi || exit 1
FRIBIDI_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
              --buildtype=release -Dtests=false -Ddocs=false -Dbin=false)
[[ -n "${MESON_CROSS_FILE:-}" ]] && FRIBIDI_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${FRIBIDI_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
echo "fribidi built (libass dependency)."
CONFIGURE_FLAGS+=(--enable-libfribidi)
echo "libfribidi (drawtext bidirectional text) enabled."
