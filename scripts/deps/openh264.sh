#!/usr/bin/env bash
# openh264 — Cisco's H.264 software encoder/decoder (BSD-2-Clause). Gives the
# LGPL builds a software H.264 encoder (x264 is GPL-only). SOURCED by
# scripts/build.sh (uses MESON_CROSS_FILE for cross targets; appends its
# --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBOPENH264}" == "1" ]] || { echo "Skipping openh264 (not needed for ${RID})."; return 0; }

echo "Building openh264 (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf openh264
git clone --depth 1 --branch v2.4.1 https://github.com/cisco/openh264.git
cd openh264 || exit 1

OH_ARGS=(
  --prefix="${DEPS_DIR}"
  --libdir=lib
  --default-library=static
  --buildtype=release
  -Dtests=disabled
)
[[ -n "${MESON_CROSS_FILE:-}" ]] && OH_ARGS+=(--cross-file "${MESON_CROSS_FILE}")

meson setup build "${OH_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build

# openh264's meson build doesn't reliably install a pkg-config file FFmpeg finds;
# write one (FFmpeg's configure requires openh264 >= 1.3.0).
cat > "${DEPS_DIR}/lib/pkgconfig/openh264.pc" <<PC
prefix=${DEPS_DIR}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: openh264
Description: OpenH264 — Cisco H.264 codec
Version: 2.4.1
Libs: -L\${libdir} -lopenh264
Libs.private: -lstdc++ -lm
Cflags: -I\${includedir}
PC

CONFIGURE_FLAGS+=(--enable-libopenh264)
echo "openh264 (software H.264 encode/decode) enabled."
