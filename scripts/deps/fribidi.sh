#!/usr/bin/env bash
set -euo pipefail
# fribidi — Unicode bidirectional text algorithm (LGPL-2.1); a libass dependency.
# SOURCED by scripts/build.sh (uses MESON_CROSS_FILE for cross targets). No
# FFmpeg --enable flag of its own. Not a standalone script.

[[ "${BUILD_LIBASS}" == "1" ]] || return 0

echo "Building fribidi (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf fribidi
git clone --depth 1 --branch v1.0.16 https://github.com/fribidi/fribidi.git
cd fribidi || exit 1
FRIBIDI_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
              --buildtype=release -Dtests=false -Ddocs=false -Dbin=false)
[[ -n "${MESON_CROSS_FILE:-}" ]] && FRIBIDI_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${FRIBIDI_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
echo "fribidi built (libass dependency)."
