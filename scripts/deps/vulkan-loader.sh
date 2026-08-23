#!/usr/bin/env bash
set -euo pipefail
# Vulkan-Loader — minimal shared Vulkan ICD loader (Apache-2.0), built with
# WSI disabled so it's libc-only and can be bundled in the artifact.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

# On glibc Linux, whisper's ggml-vulkan HARD-LINKS the loader (FFmpeg itself only
# dlopens it — vulkan.pc stays header-only). Rather than depend on the
# system libvulkan (which is built with X11/xcb WSI and would re-introduce an
# install requirement), build a minimal shared Vulkan-Loader with WSI disabled —
# its only dependency is libc — so it can be bundled in the artifact. It still
# dlopens the system GPU ICD driver at runtime (GPU when present, CPU fallback).
if [[ "${BUILD_VULKAN}" == "1" && "${BUILD_VULKAN_LOADER:-0}" == "1" ]]; then
  echo "Building Vulkan-Loader (shared, no WSI — libc-only, for bundling)..."
  cd "${WORK_DIR}" || exit 1
  # Install the Vulkan-Headers CMake package so the loader's find_package works.
  cmake -S Vulkan-Headers -B Vulkan-Headers/build -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" >/dev/null
  cmake --install Vulkan-Headers/build >/dev/null
  rm -rf Vulkan-Loader
  git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Loader.git
  cmake -S Vulkan-Loader -B Vulkan-Loader/build \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" -DVULKAN_HEADERS_INSTALL_DIR="${DEPS_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DBUILD_WSI_XLIB_SUPPORT=OFF -DBUILD_WSI_XCB_SUPPORT=OFF \
    -DBUILD_WSI_WAYLAND_SUPPORT=OFF -DBUILD_WSI_DIRECTFB_SUPPORT=OFF
  cmake --build Vulkan-Loader/build -j "$(${NPROC})"
  cmake --install Vulkan-Loader/build
  echo "Vulkan-Loader (libc-only) built — will be bundled by 08_stage_artifacts."
fi
