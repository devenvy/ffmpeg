#!/usr/bin/env bash
set -euo pipefail
# harfbuzz — text shaping engine (MIT); a libass dependency. Uses freetype
# (built earlier). SOURCED by scripts/build.sh (uses MESON_CROSS_FILE for cross
# targets). No FFmpeg --enable flag of its own. Not a standalone script.

[[ "${BUILD_LIBASS}" == "1" ]] || return 0

echo "Building harfbuzz (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf harfbuzz
clone_dep harfbuzz "${WORK_DIR}/harfbuzz"
cd harfbuzz || exit 1
HB_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
         --buildtype=release
         -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
         -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled
         -Dcairo=disabled -Dicu=disabled -Dchafa=disabled)
[[ -n "${MESON_CROSS_FILE:-}" ]] && HB_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${HB_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
echo "harfbuzz built (libass dependency)."
