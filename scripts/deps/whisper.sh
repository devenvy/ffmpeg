#!/usr/bin/env bash
set -euo pipefail
# whisper.cpp — on-device speech-to-text engine (MIT) behind FFmpeg's
# af_whisper filter; built with a per-platform GGML backend (Vulkan / Metal /
# CPU).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

echo "Building whisper.cpp (static, backend=${WHISPER_BACKEND})..."
cd "${WORK_DIR}" || exit 1
rm -rf whisper.cpp
clone_dep whisper "${WORK_DIR}/whisper.cpp"
cd whisper.cpp || exit 1

WHISPER_CMAKE=(
  # Explicit Release, like build_cmake_dep gives the helper-built deps: without a build
  # type a single-configuration generator leaves whisper/ggml with NO optimisation flags.
  -DCMAKE_BUILD_TYPE=Release
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
# musl links the C++ runtime STATICALLY rather than depending on it. A base Alpine image ships
# no libstdc++.so.6/libgcc_s.so.1, so a dynamic link makes the artifact unable to start at all:
#   Error loading shared library libstdc++.so.6: No such file or directory
# Bundling the runtimes would fix that, but it means REDISTRIBUTING GPLv3 libraries -- the GCC
# Runtime Library Exception covers our linked output, not shipping the runtime itself, so it
# would pull a GPLv3 section 6 corresponding-source obligation into every musl artifact,
# including the lgplv2 cell. Static linking avoids the obligation instead of complying with it:
# the result is "Target Code" under the Exception, which is exactly what the Exception exists to
# permit. It also matches what BtbN ships -- their libavcodec has no libstdc++ dependency.
#
# -l:libstdc++.a is the same archive-name trick this repo already uses for win-arm64's
# -l:libc++.a: a bare -lstdc++ resolves to the shared library, and -static-libstdc++ is a driver
# flag the C link does not honour here. Verified on a shared library with C++ exceptions: the
# result has only libc and the loader in DT_NEEDED, and still runs.
case "${RID}" in
  linux-musl-*)
    CXX_STATIC_LIB="-l:libstdc++.a"
    # libstdc++.a comes from Alpine's libstdc++-dev, pulled in transitively by build-base -> g++.
    # That chain is not ours to control, and if it ever stops holding the failure would surface
    # as an obscure "cannot find -l:libstdc++.a" deep inside FFmpeg's configure link tests, with
    # whisper silently reported as "not found". Check it up front and say what to install.
    if ! "${CC:-gcc}" -print-file-name=libstdc++.a 2>/dev/null | grep -q '/'; then
      echo "ERROR: libstdc++.a not found on this musl toolchain." >&2
      echo "  ${RID} links the C++ runtime statically so the artifact needs none at runtime." >&2
      echo "  Install it with: apk add libstdc++-dev   (normally transitive via build-base -> g++)" >&2
      exit 1
    fi
    ;;
  *)            CXX_STATIC_LIB="-lstdc++" ;;
esac
case "${WHISPER_BACKEND}" in
  vulkan)
    WHISPER_CMAKE+=(-DGGML_VULKAN=ON -DGGML_CPU=ON)
    WHISPER_SYS_LIBS="-lvulkan ${CXX_STATIC_LIB} -lm -lpthread"
    # glibc-native linux-x64/arm64 get Vulkan + SPIRV headers from system packages
    # (libvulkan-dev, spirv-headers). For the mingw/NDK cross targets (can't use host
    # /usr/include — glibc pollution) and for Alpine/musl (header-package names are less
    # predictable), supply Vulkan-Headers + SPIRV-Headers in DEPS_DIR (distro-independent)
    # and point ggml's find_package at them. The loader lib still comes from the
    # toolchain/system (mingw import-lib, NDK sysroot, or apk vulkan-loader-dev).
    case "${RID}" in
      win-x64|android-arm64|android-x64|linux-musl-x64|linux-musl-arm64|linux-x64|linux-arm64)
        [ -d "${DEPS_DIR}/include/vulkan" ] || {
          rm -rf "${WORK_DIR}/Vulkan-Headers-ggml"   # clone_dep git-clones into this dir; clear a stale one (retry/re-run) so the clone can't abort under set -e
          clone_dep vulkan-headers "${WORK_DIR}/Vulkan-Headers-ggml"
          cp -r "${WORK_DIR}/Vulkan-Headers-ggml/include/vulkan" "${DEPS_DIR}/include/"
          cp -r "${WORK_DIR}/Vulkan-Headers-ggml/include/vk_video" "${DEPS_DIR}/include/" 2>/dev/null || true
        }
        # SPIRV-Headers (headers + cmake config) are installed into DEPS_DIR by
        # deps/spirv-headers.sh, sourced before this script in 06_build_libraries.sh.
        # ggml-vulkan does find_package(SPIRV-Headers) (CONFIG mode), so point it
        # straight at the installed config dir (avoids cross-toolchain
        # find-root-path issues).
        SPIRV_HEADERS_CFG="$(dirname "$(find "${DEPS_DIR}" -iname 'spirv-headers*config.cmake' 2>/dev/null | head -1)")"
        WHISPER_CMAKE+=(-DVulkan_INCLUDE_DIR="${DEPS_DIR}/include"
                        -DSPIRV-Headers_DIR="${SPIRV_HEADERS_CFG}")
        ;;
    esac
    case "${RID}" in
      win-x64)
        # mingw ships no Windows Vulkan loader import-lib. We used to synthesize one from the
        # headers with dlltool, which worked but made vulkan-1.dll a HARD import of the
        # resulting libavfilter -- so ffmpeg.exe would not start at all on a machine without
        # the Vulkan runtime (any host with no GPU driver: headless server, container, fresh
        # VM). Confirmed in our own published 9.0.1.6 artifact:
        #   objdump -p avfilter-12.dll | grep 'DLL Name'  ->  DLL Name: vulkan-1.dll
        # Link the static shim instead (deps/vulkan-shim.sh); it resolves vulkan-1.dll through
        # LoadLibraryExA on first use, so the import disappears while the capability stays.
        # Verified with mingw locally: identical consumer object links to 1 vulkan import via
        # the dlltool lib and 0 via the shim, with LoadLibraryExA present instead.
        [ -n "${VULKAN_SHIM_LIB:-}" ] || {
          echo "ERROR: win-x64 whisper needs the Vulkan shim, but vulkan-shim.sh did not build it." >&2
          echo "  (BUILD_VULKAN_SHIM must be set for this RID; see scripts/platform/windows.sh)" >&2
          exit 1
        }
        WHISPER_CMAKE+=(-DVulkan_LIBRARY="${VULKAN_SHIM_LIB}")
        WHISPER_SYS_LIBS="-l:$(basename "${VULKAN_SHIM_LIB}") -lstdc++ -lm"
        ;;
      android-arm64|android-x64)
        # NDK API-28 sysroot libvulkan.so exports the Vulkan 1.1 symbols ggml links directly.
        WHISPER_CMAKE+=(-DVulkan_LIBRARY="${TOOLCHAIN}/sysroot/usr/lib/${ANDROID_TRIPLE}/${API}/libvulkan.so")
        WHISPER_SYS_LIBS="-lvulkan -lc++ -lm"
        ;;
      linux-x64|linux-arm64)
        # Link OUR bundled libc-only Vulkan loader (built by vulkan-loader.sh), not
        # the system one — so the artifact has no external libvulkan dependency.
        # Headers come from DEPS_DIR (vulkan-headers.sh); SPIRV-Headers from the
        # system package.
        WHISPER_CMAKE+=(-DVulkan_INCLUDE_DIR="${DEPS_DIR}/include"
                        -DVulkan_LIBRARY="${DEPS_DIR}/lib/libvulkan.so")
        ;;
    esac
    ;;
  metal)  WHISPER_CMAKE+=(-DGGML_BLAS_VENDOR=Apple -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_CPU=ON)
          # GGML_BLAS_VENDOR is pinned to Apple rather than left to ggml's platform
          # detection. That detection works for a native macOS build but not through the
          # macabi cross-build, where it fell back to a generic BLAS search and failed:
          #   -- x86 detected / Could NOT find BLAS (missing: BLAS_LIBRARIES)
          #   CMake Error at ggml/src/ggml-blas/CMakeLists.txt:98
          # Accelerate is present in the macOS SDK for Catalyst, so naming the vendor is
          # enough; every Apple RID wants Apple here, so this is not Catalyst-specific.
          # Apple auto-enables the BLAS backend (Accelerate); its archive is picked up by the
          # installed-archive enumeration below. Frameworks: Metal + Foundation + Accelerate.
          WHISPER_SYS_LIBS="-lc++ -lm -framework Foundation -framework Metal -framework MetalKit -framework Accelerate" ;;
  cpu|*)  WHISPER_CMAKE+=(-DGGML_CPU=ON)
          # Android/Bionic has no libstdc++ (it uses libc++) and pthread lives in libc, so
          # -lstdc++/-lpthread don't resolve there — FFmpeg's whisper link check then fails
          # ("whisper not found"). v2 drops Vulkan → Android takes THIS cpu fallback, so it
          # must use -lc++. Linux (glibc/musl) keeps libstdc++.
          case "${RID}" in
            # win-arm64 lands here too (llvm-mingw, cpu backend). A bare -lstdc++ must NOT
            # be added there: llvm-mingw resolves it to libc++.dll.a, which then collides
            # with the static libc++ from -static-libstdc++. CXX_RT_LIB carries the archive
            # this RID actually wants (-l:libc++.a). -lpthread is likewise omitted -- it does
            # not exist under mingw, whose threading is built in.
            android-*) WHISPER_SYS_LIBS="-lc++ -lm" ;;
            win-arm64) WHISPER_SYS_LIBS="${CXX_RT_LIB-} -lm" ;;
            *)         WHISPER_SYS_LIBS="${CXX_STATIC_LIB} -lm -lpthread" ;;
          esac ;;
esac

# mingw-w64 headers lack the Win10 THREAD_POWER_THROTTLING_* definitions that ggml-cpu.c
# uses unconditionally on _WIN32 (they exist in the real Windows SDK but are gated out at
# MinGW's default NTDDI level). Force-include a shim so ggml-cpu compiles. ggml-cpu is built
# by EVERY backend, so this applies to all Windows RIDs — hoisted out of the vulkan branch so
# the v2 series (Vulkan dropped → cpu backend) gets it too, not just the v3/vulkan path.
# win-* rather than win-x64: llvm-mingw (win-arm64) bundles the same mingw-w64 headers with
# the same NTDDI gating, so ggml-cpu.c fails there identically.
case "${RID}" in win-*)
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
  ;;
esac

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

# Assembling from "whatever got installed" is right for the OPTIONAL backends (ggml auto-enables
# BLAS on Apple, for instance) but it silently tolerates the REQUESTED one going missing. If
# ggml's cmake cannot find Vulkan/Metal it falls back to CPU without failing, so libggml-vulkan.a
# simply would not exist, the loop above would skip it, and whisper would register and transcribe
# -- on the CPU. Every test would pass: the filter is there, inference works, and nothing states
# which backend ran. That is the GPU equivalent of the Vulkan-filter defect this branch exists
# for, so require the archive that WHISPER_BACKEND asked for.
case "${WHISPER_BACKEND}" in
  cpu) _ggml_want="" ;;                       # CPU is libggml-cpu.a, already required below
  *)   _ggml_want="libggml-${WHISPER_BACKEND}.a" ;;
esac
if [[ -n "${_ggml_want}" && ! -f "${DEPS_DIR}/lib/${_ggml_want}" ]]; then
  echo "ERROR: whisper requested the ${WHISPER_BACKEND} ggml backend on ${RID}, but" >&2
  echo "  ${DEPS_DIR}/lib/${_ggml_want} was not installed - ggml fell back to CPU silently." >&2
  echo "  Installed ggml archives:" >&2
  ls -1 "${DEPS_DIR}/lib/"libggml*.a 2>/dev/null | sed 's|.*/|    |' >&2
  exit 1
fi
if [[ ! -f "${DEPS_DIR}/lib/libggml-cpu.a" ]]; then
  echo "ERROR: libggml-cpu.a missing - whisper has no CPU fallback path on ${RID}." >&2
  exit 1
fi
echo "whisper: ggml backend verified present (${WHISPER_BACKEND})."
WHISPER_PRIV="${WHISPER_GGML} ${WHISPER_SYS_LIBS}"

# whisper.cpp installs no pkg-config file; hand-author one (as done for x265/vpl).
# Static link: Libs.private lists the ggml archives + loader/toolchain in dependency order.
# pkg-config Version: is conventionally bare (no leading 'v'), unlike the ledger's git tag.
whisper_pc_ver="$(dep_version whisper)"; whisper_pc_ver="${whisper_pc_ver#v}"
cat > "${DEPS_DIR}/lib/pkgconfig/whisper.pc" <<PKGCONFIG
prefix=${DEPS_DIR}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: whisper
Description: whisper.cpp speech recognition
Version: ${whisper_pc_ver}
Libs: -L\${libdir} -lwhisper
Libs.private: ${WHISPER_PRIV}
Cflags: -I\${includedir}
PKGCONFIG

CONFIGURE_FLAGS+=(--enable-whisper)
echo "whisper.cpp (af_whisper filter, backend=${WHISPER_BACKEND}) enabled."
