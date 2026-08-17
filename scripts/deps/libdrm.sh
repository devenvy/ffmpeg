#!/usr/bin/env bash
# libdrm — Direct Rendering Manager userspace library (MIT). Built as a STATIC
# library on Linux and linked into FFmpeg (VAAPI needs it, and FFmpeg's
# --enable-libdrm), so the artifact carries no libdrm.so.2 runtime dependency —
# it starts on any distro without an install. SOURCED by scripts/build.sh; builds
# only the core (GPU-vendor helper libs disabled — the VA driver uses core DRM).
# Not a standalone script.

[[ "${BUILD_LIBDRM_SOURCE}" == "1" ]] || { echo "Skipping libdrm-from-source (not needed for ${RID})."; return 0; }

echo "Building libdrm (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf libdrm
git clone --depth 1 --branch libdrm-2.4.123 https://gitlab.freedesktop.org/mesa/drm.git libdrm
cd libdrm || exit 1
meson setup build --prefix="${DEPS_DIR}" --libdir=lib --default-library=static --buildtype=release \
  -Dtests=false -Dman-pages=disabled -Dvalgrind=disabled -Dcairo-tests=disabled \
  -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
  -Dvmwgfx=disabled -Dvc4=disabled -Detnaviv=disabled -Dfreedreno=disabled \
  -Domap=disabled -Dexynos=disabled -Dtegra=disabled
meson compile -C build -j "$(${NPROC})"
meson install -C build
echo "libdrm (static) built."
