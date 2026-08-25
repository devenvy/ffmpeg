#!/usr/bin/env bash
set -euo pipefail
# openjpeg — JPEG 2000 codec (BSD-2). Enables FFmpeg's external libopenjpeg
# JPEG 2000 en/decoder. SOURCED by scripts/build.sh (shares env; appends
# --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBOPENJPEG}" == "1" ]] || { echo "Skipping openjpeg (not needed for ${RID})."; return 0; }

# Core libopenjp2 only: -DBUILD_CODEC=OFF drops the CLI tools (which pull png/tiff).
build_cmake_dep openjpeg \
  -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF

# OpenJPEG 2.5.x emits a malformed Libs.private ("-l-lpthread") in libopenjp2.pc — its CMake
# prepends -l to an already-complete -lpthread, so FFmpeg's static pkg-config link test looks
# for a library literally named "-lpthread" and fails ("libopenjp2 not found"). Repair the
# token in place. (sed -i.bak for BSD/macOS sed portability, matching scripts/deps/shaderc.sh;
# a no-op on platforms where the token isn't emitted.)
OPJ_PC="${DEPS_DIR}/lib/pkgconfig/libopenjp2.pc"
if [ -f "${OPJ_PC}" ]; then
  sed -i.bak 's/-l-lpthread/-lpthread/g' "${OPJ_PC}"
  rm -f "${OPJ_PC}.bak"
fi

CONFIGURE_FLAGS+=(--enable-libopenjpeg)
echo "libopenjpeg (JPEG 2000) enabled."
