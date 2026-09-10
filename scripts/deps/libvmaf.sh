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
# libvmaf bundles libsvm, whose src/svm.cpp defines a global
#   template <class T> static inline void swap(T&, T&)
# Because svm_node lives in the global namespace, ADL makes that a candidate alongside
# std::swap wherever libc++ calls swap() unqualified inside <vector>, and every
# std::vector<svm_node>::push_back instantiation fails with "call to 'swap' is ambiguous".
# libstdc++ does not trip it (its internals qualify the call), which is why only llvm-mingw
# sees this. Rename libsvm's helper and its 26 call sites together — they are all its own,
# svm.cpp pulls in no std::swap of its own. Verified by cross-building libvmaf v3.2.0 for
# aarch64-w64-mingw32 with and without the rename.
if [[ "${RID}" == "win-arm64" ]]; then
  sed -i "s/\bswap(/libsvm_swap(/g" "${WORK_DIR}/vmaf/libvmaf/src/svm.cpp"
  echo "libvmaf: renamed libsvm's global swap (libc++ ADL ambiguity on win-arm64)"
fi
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
