#!/usr/bin/env bash
# libva — VA-API dispatch library (MIT). Built STATIC with the DRM backend only
# (no X11/GLX/Wayland) and linked into FFmpeg, so the artifact carries no libva.so
# runtime dependency; the static dispatcher dlopens the system VA driver
# (iHD/i965/radeonsi) at runtime — so VAAPI works when a driver is installed, and
# nothing is required just to start ffmpeg. Needs libdrm (built just before this).
# SOURCED by scripts/build.sh. Not a standalone script.

[[ "${BUILD_LIBVA_SOURCE}" == "1" ]] || { echo "Skipping libva-from-source (not needed for ${RID})."; return 0; }

echo "Building libva (static, DRM backend only)..."
cd "${WORK_DIR}"
rm -rf libva
git clone --depth 1 --branch 2.22.0 https://github.com/intel/libva.git
cd libva
# libva's meson uses shared_library() explicitly, which ignores --default-library.
# Rewrite to library() so --default-library=static yields static archives (library()
# still accepts the version:/soversion: kwargs, unlike static_library()).
sed -i 's/\bshared_library(/library(/g' va/meson.build
meson setup build --prefix="${DEPS_DIR}" --libdir=lib --default-library=static --buildtype=release \
  -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no -Ddisable_drm=false
meson compile -C build -j "$(${NPROC})"
meson install -C build
# Static libva dlopens the VA driver at runtime, so its consumers need -ldl; libva-drm
# also pulls in libva + libdrm. Make sure pkg-config --static exposes these for FFmpeg.
for pc in libva libva-drm; do
  f="${DEPS_DIR}/lib/pkgconfig/${pc}.pc"
  [ -f "$f" ] || continue
  grep -q '^Libs.private:' "$f" && sed -i 's/^Libs.private:.*/Libs.private: -ldl/' "$f" \
                                || sed -i '/^Libs:/a Libs.private: -ldl' "$f"
done
echo "libva (static) built — DRM backend, dlopens the system VA driver at runtime."
