#!/usr/bin/env bash
set -euo pipefail
# SPIRV-Headers — Khronos SPIR-V headers (MIT-like), needed by whisper.cpp's ggml-vulkan
# backend AND by FFmpeg's own Vulkan code. System spirv-headers packages aren't available or
# predictable on the cross targets and musl, so they are installed from the pinned ledger ref.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

# Gated on EITHER consumer, not just whisper. ggml-vulkan needs these headers, but so does
# FFmpeg's own Vulkan code -- n9's swscale SPIR-V backend compiles only behind
# HAVE_SPIRV_HEADERS_SPIRV_H / HAVE_SPIRV_UNIFIED1_SPIRV_H. The old gate was
# WHISPER_BACKEND == vulkan plus a RID allowlist, which excluded linux-armhf, win-arm64 and
# every Apple target -- all of which still set BUILD_VULKAN=1 on the v3 cells. So those RIDs
# enabled Vulkan in configure and then built it against whatever headers the host happened to
# have, or none. Installing headers can only add capability, never remove it, and the install
# below is header-only (no compilation), so it is safe to run wherever Vulkan is enabled.
if [[ "${WHISPER_BACKEND}" == "vulkan" || "${BUILD_VULKAN:-0}" == "1" ]]; then
  # ggml-vulkan does find_package(SPIRV-Headers) (CONFIG mode), so it needs
  # SPIRV-HeadersConfig.cmake -- not just the headers. Install SPIRV-Headers properly
  # (headers + cmake config) into DEPS_DIR and point find_package straight at the
  # installed config dir (avoids cross-toolchain find-root-path issues).
  rm -rf "${WORK_DIR}/SPIRV-Headers-ggml"
  clone_dep spirv-headers "${WORK_DIR}/SPIRV-Headers-ggml"
  cmake -S "${WORK_DIR}/SPIRV-Headers-ggml" -B "${WORK_DIR}/SPIRV-Headers-ggml/build" \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}"
  cmake --install "${WORK_DIR}/SPIRV-Headers-ggml/build"
  echo "SPIRV-Headers installed (ggml-vulkan and/or FFmpeg Vulkan dependency)."
fi
