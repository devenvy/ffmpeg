#!/usr/bin/env bash
set -euo pipefail
# shaderc — Google's GLSL/HLSL -> SPIR-V compiler (Apache-2.0), built as a static
# library. Its ONLY consumer here is libplacebo, whose Vulkan renderer compiles
# shaders to SPIR-V at runtime via libshaderc — so it is guarded on BUILD_LIBPLACEBO,
# not built otherwise. shaderc vendors glslang + SPIRV-Tools + SPIRV-Headers via its
# own utils/git-sync-deps (pinned by shaderc itself, not the ledger). SOURCED by
# scripts/build.sh (shares its environment). Not a standalone script. Appends no
# FFmpeg --enable flag (it is a build dependency of libplacebo, not an FFmpeg library).

[[ "${BUILD_LIBPLACEBO}" == "1" ]] || return 0

echo "Building shaderc (static, for libplacebo)..."
cd "${WORK_DIR}" || exit 1
rm -rf shaderc
clone_dep shaderc "${WORK_DIR}/shaderc"
cd shaderc || exit 1
# Fetch shaderc's pinned third-party sources (glslang / SPIRV-Tools / SPIRV-Headers /
# abseil / re2). Needs python3 + git, both present in the build environment.
python3 ./utils/git-sync-deps
cmake -B build -G Ninja \
  -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON -DENABLE_GLSLANG_BINARIES=OFF \
  ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"}
cmake --build build --target install -j "$(${NPROC})"
# We link statically. Point the default shaderc.pc at the self-contained static archive
# (libshaderc_combined bundles glslang + SPIRV-Tools) and drop the shared library, so
# FFmpeg's static link of libplacebo pulls the static shaderc and nothing depends on a
# libshaderc_shared.so at runtime.
# sed -i.bak (attached suffix) is portable — bare `sed -i` fails on BSD/macOS (osx/ios).
sed -i.bak 's/-lshaderc_shared/-lshaderc_combined/' "${DEPS_DIR}/lib/pkgconfig/shaderc.pc"
rm -f "${DEPS_DIR}/lib/pkgconfig/shaderc.pc.bak"
rm -f "${DEPS_DIR}"/lib/libshaderc_shared.*   # .so/.dylib/.dll across platforms
# shaderc's install also drops its glslc CLI into ${DEPS_DIR}/bin — built for the TARGET
# arch on cross builds, so it shadows the host glslc (installed by 03) that shader steps
# must run. We only need libshaderc for libplacebo, so remove it. (-rf: on macOS/iOS
# glslc installs as a glslc.app bundle directory, not a plain file.)
rm -rf "${DEPS_DIR}"/bin/glslc*

# FFmpeg 8.x needs --enable-libshaderc for its Vulkan FILTERS; 9.x does not.
# The two lines obtain SPIR-V compilation differently and the difference is silent:
#   n8.1.2: scale_vulkan, xfade_vulkan, blend_vulkan, chromaber_vulkan, transpose_vulkan,
#           vflip_vulkan, color_vulkan, blackdetect_vulkan all carry *_filter_deps="vulkan
#           spirv_library", and spirv_library comes ONLY from --enable-libshaderc or
#           --enable-libglslang (configure:7368). We passed neither, and with
#           --disable-autodetect nothing turned it on, so EVERY 8.1.2 cell shipped with zero
#           Vulkan filters -- measured in the published 8.1.2.6 artifacts, including the RIDs
#           where 9.0.1 has them.
#   n9.0.1: the same filters depend on spirv_compiler instead, which configure derives by
#           probing a glslc BINARY; libshaderc was removed as an option entirely, so passing
#           it there would be an unknown-option error.
# Hence the version gate. We already build and install shaderc.pc (pointed at the static
# libshaderc_combined above), which is exactly what require_pkg_config wants.
case "${FFMPEG_VERSION}" in
  8.*)
    # shellcheck disable=SC2034  # appended here; consumed by steps/07_build_ffmpeg.sh
    CONFIGURE_FLAGS+=(--enable-libshaderc)
    echo "FFmpeg 8.x: enabling libshaderc so the Vulkan filters get spirv_library."
    ;;
esac
echo "shaderc built (static libshaderc_combined + bundled glslang/SPIRV-Tools)."
