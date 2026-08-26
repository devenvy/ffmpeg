#!/usr/bin/env bash
set -euo pipefail
# libvmaf — Netflix VMAF perceptual video-quality metric (BSD-2-Clause-Patent,
# GPLv2-compatible). Enables FFmpeg's vmaf filter. The meson project lives in the
# libvmaf/ subdirectory of the repo. Default prediction models are compiled into
# the library (no runtime model files). C++ — the C++ runtime is added to
# EXTRA_LIBS for FFmpeg's static link. SOURCED by scripts/build.sh (uses
# MESON_CROSS_FILE for cross targets). Not a standalone script.

[[ "${BUILD_LIBVMAF}" == "1" ]] || { echo "Skipping libvmaf (not needed for ${RID})."; return 0; }

echo "Building libvmaf (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf vmaf
clone_dep libvmaf "${WORK_DIR}/vmaf"
cd vmaf/libvmaf || exit 1     # meson project is in the libvmaf/ subdir
VMAF_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
           --buildtype=release
           -Denable_tests=false -Denable_docs=false
           -Dbuilt_in_models=true -Denable_float=true)
[[ -n "${MESON_CROSS_FILE:-}" ]] && VMAF_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${VMAF_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
# libvmaf is C++; its pkg-config declares no C++ runtime. Add it for FFmpeg's
# static --enable-libvmaf link (libstdc++ on GNU/Linux + mingw, libc++ on Apple/NDK).
case "${PLATFORM:-linux}" in
  apple|android) EXTRA_LIBS="${EXTRA_LIBS:-} -lc++" ;;
  *)             EXTRA_LIBS="${EXTRA_LIBS:-} -lstdc++" ;;
esac
CONFIGURE_FLAGS+=(--enable-libvmaf)
echo "libvmaf (vmaf quality metric) enabled."
