#!/usr/bin/env bash
set -euo pipefail
# openjpeg — JPEG 2000 codec (BSD-2). Enables FFmpeg's external libopenjpeg
# JPEG 2000 en/decoder. SOURCED by scripts/build.sh (shares env; appends
# --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBOPENJPEG}" == "1" ]] || { echo "Skipping openjpeg (not needed for ${RID})."; return 0; }

# Core libopenjp2 only: -DBUILD_CODEC=OFF drops the CLI tools (which pull png/tiff).
build_cmake_dep openjpeg \
  -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF

# OpenJPEG 2.5.x emits a malformed Libs.private in libopenjp2.pc — its CMake prepends -l to an
# already-complete thread flag, giving "-l-lpthread" (glibc, thread lib = -lpthread) or
# "-l-pthread" (NDK/others, thread flag = -pthread). FFmpeg's static pkg-config link test then
# looks for a library literally named "-lpthread"/"-pthread" and fails ("libopenjp2 not found").
# Repair both forms in place. (sed -i.bak for BSD/macOS portability, matching shaderc.sh; a
# no-op where the token isn't emitted.)
OPJ_PC="${DEPS_DIR}/lib/pkgconfig/libopenjp2.pc"
if [ -f "${OPJ_PC}" ]; then
  sed -i.bak -E 's/-l(-l?pthread)/\1/g' "${OPJ_PC}"
  rm -f "${OPJ_PC}.bak"
fi

CONFIGURE_FLAGS+=(--enable-libopenjpeg)
echo "libopenjpeg (JPEG 2000) enabled."
