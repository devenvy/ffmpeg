#!/usr/bin/env bash
# Vulkan-Headers — Khronos Vulkan API headers (Apache-2.0) for FFmpeg's Vulkan
# filters/hwaccel and whisper's GPU backend.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_VULKAN}" == "1" ]]; then
  echo "Installing Vulkan-Headers..."
  cd "${WORK_DIR}" || exit 1
  rm -rf Vulkan-Headers
  git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git
  cp -r Vulkan-Headers/include/vulkan "${DEPS_DIR}/include/"
  cp -r Vulkan-Headers/include/vk_video "${DEPS_DIR}/include/"

  VULKAN_HEADER_FILE="${DEPS_DIR}/include/vulkan/vulkan_core.h"
  VULKAN_HEADER_REV="$(awk '/^#define VK_HEADER_VERSION / { print $3; exit }' "${VULKAN_HEADER_FILE}")"
  if grep -q '^#define VK_API_VERSION_1_4 ' "${VULKAN_HEADER_FILE}"; then
    VULKAN_API_VERSION="1.4"
  elif grep -q '^#define VK_API_VERSION_1_3 ' "${VULKAN_HEADER_FILE}"; then
    VULKAN_API_VERSION="1.3"
  else
    echo "Vulkan support requires Vulkan 1.3+ headers." >&2
    exit 1
  fi

  VULKAN_PC_VERSION="${VULKAN_API_VERSION}.${VULKAN_HEADER_REV}"
  cat > "${DEPS_DIR}/lib/pkgconfig/vulkan.pc" <<PKGCONFIG
prefix=${DEPS_DIR}
includedir=\${prefix}/include

Name: Vulkan-Headers
Description: Vulkan header-only SDK for FFmpeg configure checks
Version: ${VULKAN_PC_VERSION}
Cflags: -I\${includedir}
PKGCONFIG

  # On glibc Linux, whisper's ggml-vulkan HARD-LINKS the loader (FFmpeg itself only
  # dlopens it — vulkan.pc stays header-only above). Rather than depend on the
  # system libvulkan (which is built with X11/xcb WSI and would re-introduce an
  # install requirement), build a minimal shared Vulkan-Loader with WSI disabled —
  # its only dependency is libc — so it can be bundled in the artifact. It still
  # dlopens the system GPU ICD driver at runtime (GPU when present, CPU fallback).
  if [[ "${BUILD_VULKAN_LOADER:-0}" == "1" ]]; then
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

  CONFIGURE_FLAGS+=(--enable-vulkan)
  VULKAN_STATUS="enabled (headers ${VULKAN_PC_VERSION})"
  HWACCEL_FEATURES="${HWACCEL_FEATURES} Vulkan"
  echo "Vulkan support enabled (${VULKAN_PC_VERSION})"
else
  echo "Skipping Vulkan headers (not needed for ${RID})."
  VULKAN_STATUS="disabled"
fi
