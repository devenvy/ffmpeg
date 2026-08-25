#!/usr/bin/env bash
set -euo pipefail
# libplacebo — GPU-accelerated video processing (HDR tone-mapping, high-quality
# scaling, colorspace conversion) built on Vulkan (LGPL-2.1+). Enables FFmpeg's
# libplacebo filter. Needs the Vulkan stack (headers/loader, built earlier) and a
# SPIR-V compiler (shaderc, built just before this). Vulkan-gated: BUILD_LIBPLACEBO
# tracks BUILD_VULKAN (set in 04_select_license), so it builds only in the v3 Vulkan
# cells and is dropped from the v2 / App-Store cells. SOURCED by scripts/build.sh
# (uses MESON_CROSS_FILE for cross targets). Not a standalone script.

[[ "${BUILD_LIBPLACEBO}" == "1" ]] || return 0

echo "Building libplacebo (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf libplacebo
clone_dep libplacebo "${WORK_DIR}/libplacebo"
cd libplacebo || exit 1
# libplacebo generates code at build time from vendored submodules: glad (Vulkan
# loader), jinja + markupsafe (templating). Fetch just those (skip demos/nuklear).
git submodule update --init --depth 1 3rdparty/glad 3rdparty/jinja 3rdparty/markupsafe
PL_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
         --buildtype=release
         -Dvulkan=enabled -Dshaderc=enabled -Dglslang=disabled -Dopengl=disabled
         -Ddemos=false -Dtests=false -Dlcms=disabled -Dd3d11=disabled)
[[ -n "${MESON_CROSS_FILE:-}" ]] && PL_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${PL_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
CONFIGURE_FLAGS+=(--enable-libplacebo)
echo "libplacebo (GPU HDR tone-map + scaling) enabled."
