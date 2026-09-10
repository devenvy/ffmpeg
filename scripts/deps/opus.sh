#!/usr/bin/env bash
set -euo pipefail
# libopus — Opus audio encoder + decoder (BSD-3).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBOPUS}" == "1" ]]; then
  OPUS_EXTRA=()
  # opus's CMake believes ARM runtime CPU detection works on any Windows
  # (OpusFunctions.cmake: CMAKE_SYSTEM_NAME MATCHES "Windows" -> detection = 1), but
  # celt/arm/armcpu.c only IMPLEMENTS the Windows path under defined(_MSC_VER). llvm-mingw is
  # clang, so that branch is skipped, and every other branch (Linux/Apple/ELF/OpenBSD) with it,
  # so the file hits its own "no CPU detection method available" #error. Disabling intrinsics
  # turns off the ARM asm + RTCD path entirely (CMakeLists gates it on
  # `OPUS_CPU_ARM AND NOT OPUS_DISABLE_INTRINSICS`), leaving the portable C. The cost is
  # NEON-accelerated Opus on this one RID; correctness is unaffected.
  [[ "${RID}" == "win-arm64" ]] && OPUS_EXTRA+=(-DOPUS_DISABLE_INTRINSICS=ON)
  build_cmake_dep opus \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF "${OPUS_EXTRA[@]+"${OPUS_EXTRA[@]}"}"
  CONFIGURE_FLAGS+=(--enable-libopus)
  echo "libopus (Opus audio encoder) enabled."
else
  echo "Skipping libopus."
fi
