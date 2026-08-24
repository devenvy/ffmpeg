#!/usr/bin/env bash
set -euo pipefail
# SPIRV-Headers — Khronos SPIR-V headers (MIT-like) needed by whisper.cpp's
# ggml-vulkan backend on the mingw/NDK cross targets and musl (where system
# spirv-headers packages aren't available/predictable).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${WHISPER_BACKEND}" == "vulkan" ]]; then
  case "${RID}" in
    win-x64|android-arm64|linux-musl-x64|linux-x64|linux-arm64)
      # ggml-vulkan does find_package(SPIRV-Headers) (CONFIG mode), so it needs
      # SPIRV-HeadersConfig.cmake — not just the headers. Install SPIRV-Headers properly
      # (headers + cmake config) into DEPS_DIR and point find_package straight at the
      # installed config dir (avoids cross-toolchain find-root-path issues).
      rm -rf "${WORK_DIR}/SPIRV-Headers-ggml"
      clone_dep spirv-headers "${WORK_DIR}/SPIRV-Headers-ggml"
      cmake -S "${WORK_DIR}/SPIRV-Headers-ggml" -B "${WORK_DIR}/SPIRV-Headers-ggml/build" \
        -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}"
      cmake --install "${WORK_DIR}/SPIRV-Headers-ggml/build"
      echo "SPIRV-Headers installed (whisper ggml-vulkan dependency)."
      ;;
  esac
fi
