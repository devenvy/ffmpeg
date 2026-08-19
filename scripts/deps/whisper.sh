#!/usr/bin/env bash
set -euo pipefail
# whisper.cpp — on-device speech-to-text engine (MIT) behind FFmpeg's
# af_whisper filter; built with a per-platform GGML backend (Vulkan / Metal /
# CPU).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

echo "Building whisper.cpp v1.8.6 (static, backend=${WHISPER_BACKEND})..."
cd "${WORK_DIR}" || exit 1
rm -rf whisper.cpp
git clone --depth 1 --branch v1.8.6 https://github.com/ggml-org/whisper.cpp
cd whisper.cpp || exit 1

WHISPER_CMAKE=(
  -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="${DEPS_DIR}"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DWHISPER_BUILD_EXAMPLES=OFF
  -DWHISPER_BUILD_TESTS=OFF
  -DWHISPER_BUILD_SERVER=OFF
  -DGGML_BUILD_TESTS=OFF
  -DGGML_BUILD_EXAMPLES=OFF
)
case "${WHISPER_BACKEND}" in
  vulkan)
    WHISPER_CMAKE+=(-DGGML_VULKAN=ON -DGGML_CPU=ON)
    WHISPER_SYS_LIBS="-lvulkan -lstdc++ -lm -lpthread"
    # glibc-native linux-x64/arm64 get Vulkan + SPIRV headers from system packages
    # (libvulkan-dev, spirv-headers). For the mingw/NDK cross targets (can't use host
    # /usr/include — glibc pollution) and for Alpine/musl (header-package names are less
    # predictable), supply Vulkan-Headers + SPIRV-Headers in DEPS_DIR (distro-independent)
    # and point ggml's find_package at them. The loader lib still comes from the
    # toolchain/system (mingw import-lib, NDK sysroot, or apk vulkan-loader-dev).
    case "${RID}" in
      win-x64|android-arm64|linux-musl-x64|linux-x64|linux-arm64)
        [ -d "${DEPS_DIR}/include/vulkan" ] || {
          git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "${WORK_DIR}/Vulkan-Headers-ggml"
          cp -r "${WORK_DIR}/Vulkan-Headers-ggml/include/vulkan" "${DEPS_DIR}/include/"
          cp -r "${WORK_DIR}/Vulkan-Headers-ggml/include/vk_video" "${DEPS_DIR}/include/" 2>/dev/null || true
        }
        # ggml-vulkan does find_package(SPIRV-Headers) (CONFIG mode), so it needs
        # SPIRV-HeadersConfig.cmake — not just the headers. Install SPIRV-Headers properly
        # (headers + cmake config) into DEPS_DIR and point find_package straight at the
        # installed config dir (avoids cross-toolchain find-root-path issues).
        rm -rf "${WORK_DIR}/SPIRV-Headers-ggml"
        git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "${WORK_DIR}/SPIRV-Headers-ggml"
        cmake -S "${WORK_DIR}/SPIRV-Headers-ggml" -B "${WORK_DIR}/SPIRV-Headers-ggml/build" \
          -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}"
        cmake --install "${WORK_DIR}/SPIRV-Headers-ggml/build"
        SPIRV_HEADERS_CFG="$(dirname "$(find "${DEPS_DIR}" -iname 'spirv-headers*config.cmake' 2>/dev/null | head -1)")"
        WHISPER_CMAKE+=(-DVulkan_INCLUDE_DIR="${DEPS_DIR}/include"
                        -DSPIRV-Headers_DIR="${SPIRV_HEADERS_CFG}")
        ;;
    esac
    case "${RID}" in
      win-x64)
        # mingw ships no Windows Vulkan loader import-lib; synthesize one from the headers
        # via dlltool (the runtime loader is vulkan-1.dll, provided by the GPU driver).
        grep -rhoE 'VKAPI_CALL[[:space:]]+vk[A-Za-z0-9]+' "${DEPS_DIR}/include/vulkan/"*.h \
          | awk '{print $2}' | sort -u > "${WORK_DIR}/vulkan-1.syms"
        { echo "LIBRARY vulkan-1.dll"; echo "EXPORTS"; cat "${WORK_DIR}/vulkan-1.syms"; } > "${WORK_DIR}/vulkan-1.def"
        "${CROSS_PREFIX}-dlltool" -d "${WORK_DIR}/vulkan-1.def" -D vulkan-1.dll -l "${DEPS_DIR}/lib/libvulkan-1.dll.a"
        WHISPER_CMAKE+=(-DVulkan_LIBRARY="${DEPS_DIR}/lib/libvulkan-1.dll.a")
        WHISPER_SYS_LIBS="-l:libvulkan-1.dll.a -lstdc++ -lm"
        ;;
      android-arm64)
        # NDK API-28 sysroot libvulkan.so exports the Vulkan 1.1 symbols ggml links directly.
        WHISPER_CMAKE+=(-DVulkan_LIBRARY="${TOOLCHAIN}/sysroot/usr/lib/${ANDROID_TRIPLE}/${API}/libvulkan.so")
        WHISPER_SYS_LIBS="-lvulkan -lc++ -lm"
        ;;
      linux-x64|linux-arm64)
        # Link OUR bundled libc-only Vulkan loader (built by vulkan.sh), not the
        # system one — so the artifact has no external libvulkan dependency. Headers
        # come from DEPS_DIR (vulkan.sh); SPIRV-Headers from the system package.
        WHISPER_CMAKE+=(-DVulkan_INCLUDE_DIR="${DEPS_DIR}/include"
                        -DVulkan_LIBRARY="${DEPS_DIR}/lib/libvulkan.so")
        ;;
    esac
    ;;
  metal)  WHISPER_CMAKE+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_CPU=ON)
          # Apple auto-enables the BLAS backend (Accelerate); its archive is picked up by the
          # installed-archive enumeration below. Frameworks: Metal + Foundation + Accelerate.
          WHISPER_SYS_LIBS="-lc++ -lm -framework Foundation -framework Metal -framework MetalKit -framework Accelerate" ;;
  cpu|*)  WHISPER_CMAKE+=(-DGGML_CPU=ON)
          WHISPER_SYS_LIBS="-lstdc++ -lm -lpthread" ;;
esac

# mingw-w64 headers lack the Win10 THREAD_POWER_THROTTLING_* definitions that ggml-cpu.c
# uses unconditionally on _WIN32 (they exist in the real Windows SDK but are gated out at
# MinGW's default NTDDI level). Force-include a shim so ggml-cpu compiles. ggml-cpu is built
# by EVERY backend, so this applies to all of win-x64 — hoisted out of the vulkan branch so
# the v2 series (Vulkan dropped → cpu backend) gets it too, not just the v3/vulkan path.
if [ "${RID}" = win-x64 ]; then
  cat > "${WORK_DIR}/win_ggml_compat.h" <<'SHIM'
#ifndef WHISPER_WIN_GGML_COMPAT_H
#define WHISPER_WIN_GGML_COMPAT_H
#include <windows.h>
#ifndef THREAD_POWER_THROTTLING_CURRENT_VERSION
typedef struct _THREAD_POWER_THROTTLING_STATE {
    ULONG Version; ULONG ControlMask; ULONG StateMask;
} THREAD_POWER_THROTTLING_STATE, *PTHREAD_POWER_THROTTLING_STATE;
#define THREAD_POWER_THROTTLING_CURRENT_VERSION 1
#define THREAD_POWER_THROTTLING_EXECUTION_SPEED 0x1
#define THREAD_POWER_THROTTLING_VALID_FLAGS THREAD_POWER_THROTTLING_EXECUTION_SPEED
#endif
#endif
SHIM
  WHISPER_CMAKE+=(-DCMAKE_C_FLAGS="-include ${WORK_DIR}/win_ggml_compat.h"
                  -DCMAKE_CXX_FLAGS="-include ${WORK_DIR}/win_ggml_compat.h")
fi

cmake -B build "${WHISPER_CMAKE[@]}" \
  ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"}
cmake --build build -j"$(${NPROC})"
cmake --install build

# Some toolchains (notably mingw) install the ggml archives WITHOUT the 'lib' prefix
# (ggml.a instead of libggml.a), so -lggml won't resolve at FFmpeg link time. Normalize
# to libggml*.a so the whisper.pc below works uniformly across platforms.
for f in ggml ggml-base ggml-cpu ggml-vulkan ggml-metal ggml-blas; do
  [ -f "${DEPS_DIR}/lib/${f}.a" ] && mv "${DEPS_DIR}/lib/${f}.a" "${DEPS_DIR}/lib/lib${f}.a"
done

# Assemble the ggml archive link line from what actually got INSTALLED (not a hardcoded
# per-backend guess). The ggml registry (libggml.a) references every backend it was
# compiled with — including the BLAS backend ggml auto-enables on Apple — so list the
# registry first, then all backends present, then libggml-base last (all depend on it).
WHISPER_GGML="-lggml"
for b in cpu metal vulkan blas; do
  [ -f "${DEPS_DIR}/lib/libggml-${b}.a" ] && WHISPER_GGML="${WHISPER_GGML} -lggml-${b}"
done
WHISPER_GGML="${WHISPER_GGML} -lggml-base"
WHISPER_PRIV="${WHISPER_GGML} ${WHISPER_SYS_LIBS}"

# whisper.cpp installs no pkg-config file; hand-author one (as done for x265/vpl).
# Static link: Libs.private lists the ggml archives + loader/toolchain in dependency order.
cat > "${DEPS_DIR}/lib/pkgconfig/whisper.pc" <<PKGCONFIG
prefix=${DEPS_DIR}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: whisper
Description: whisper.cpp speech recognition
Version: 1.8.6
Libs: -L\${libdir} -lwhisper
Libs.private: ${WHISPER_PRIV}
Cflags: -I\${includedir}
PKGCONFIG

CONFIGURE_FLAGS+=(--enable-whisper)
echo "whisper.cpp (af_whisper filter, backend=${WHISPER_BACKEND}) enabled."
