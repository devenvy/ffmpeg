#!/usr/bin/env bash
set -euo pipefail
# lcms2 (Little CMS 2) — ICC color-management engine (MIT core). Enables FFmpeg's
# ICC profile support (iccdetect/iccgen filters) and is a build dependency of
# libjxl and libplacebo. Meson build. SOURCED by scripts/build.sh (uses
# MESON_CROSS_FILE for cross targets). Not a standalone script.
#
# The fastfloat + threaded meson plugins are GPL-3.0 (upstream: "use only if GPL
# 3.0 is acceptable"); left at their default (off) so only the MIT core ships,
# keeping every cell — including the v2/LGPL lane — license-clean.

[[ "${BUILD_LCMS2}" == "1" ]] || { echo "Skipping lcms2 (not needed for ${RID})."; return 0; }

echo "Building lcms2 (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf lcms2
clone_dep lcms2 "${WORK_DIR}/lcms2"
cd lcms2 || exit 1
LCMS_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
           --buildtype=release
           -Djpeg=disabled -Dtiff=disabled -Dtests=disabled
           -Dutils=false -Dversionedlibs=false)
[[ -n "${MESON_CROSS_FILE:-}" ]] && LCMS_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${LCMS_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
CONFIGURE_FLAGS+=(--enable-lcms2)
echo "lcms2 (ICC profile support) enabled."
