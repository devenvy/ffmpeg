#!/usr/bin/env bash
set -euo pipefail
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

  CONFIGURE_FLAGS+=(--enable-vulkan)
  VULKAN_STATUS="enabled (headers ${VULKAN_PC_VERSION})"
  HWACCEL_FEATURES="${HWACCEL_FEATURES} Vulkan"
  echo "Vulkan support enabled (${VULKAN_PC_VERSION})"
else
  echo "Skipping Vulkan headers (not needed for ${RID})."
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  VULKAN_STATUS="disabled"
fi
