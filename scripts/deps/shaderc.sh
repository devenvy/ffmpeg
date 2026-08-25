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
echo "shaderc built (static libshaderc_combined + bundled glslang/SPIRV-Tools)."
