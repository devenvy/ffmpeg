#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 5: Cross Toolchain Files
#
# Create the dependency install dir and write the CMake/Meson
# cross-compilation toolchain files used to build the static dependencies
# for non-native targets (mingw, Android NDK, iOS, armhf).
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

DEPS_DIR="${WORK_DIR}/deps"
mkdir -p "${DEPS_DIR}/include" "${DEPS_DIR}/lib/pkgconfig"
export PKG_CONFIG_PATH="${DEPS_DIR}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# ── Cross-compilation toolchain files ─────────────────────────────────────

CMAKE_CROSS_ARGS=()

case "${RID}" in
  linux-armhf)
    ARMHF_TOOLCHAIN="${WORK_DIR}/armhf-toolchain.cmake"
    cat > "${ARMHF_TOOLCHAIN}" <<CMAKE
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
set(CMAKE_C_FLAGS_INIT "-mfpu=neon")
set(CMAKE_CXX_FLAGS_INIT "-mfpu=neon")
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE
    CMAKE_CROSS_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${ARMHF_TOOLCHAIN}")
    ;;
  win-arm64)
    # llvm-mingw is clang-based: the drivers are -clang/-clang++ (not -gcc/-g++), and it
    # provides llvm-windres under the same triple prefix. ARM64 is the CMake spelling of
    # the processor for Windows-on-ARM.
    TOOLCHAIN_FILE="${WORK_DIR}/llvm-mingw-toolchain.cmake"
    cat > "${TOOLCHAIN_FILE}" <<CMAKE
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ARM64)
set(CMAKE_C_COMPILER ${CROSS_PREFIX}-clang)
set(CMAKE_CXX_COMPILER ${CROSS_PREFIX}-clang++)
set(CMAKE_RC_COMPILER ${CROSS_PREFIX}-windres)
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE
    CMAKE_CROSS_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}")
    ;;
  win-x64)
    TOOLCHAIN_FILE="${WORK_DIR}/mingw-toolchain.cmake"
    cat > "${TOOLCHAIN_FILE}" <<CMAKE
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${CROSS_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${CROSS_PREFIX}-g++)
set(CMAKE_RC_COMPILER ${CROSS_PREFIX}-windres)
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE
    CMAKE_CROSS_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}")
    ;;
  android-arm64|android-x64)
    CMAKE_CROSS_ARGS+=(
      -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="${ANDROID_ABI}"
      -DANDROID_PLATFORM="android-${API}"
    )
    ;;
  maccatalyst-arm64|maccatalyst-x64)
    # Catalyst is NOT CMAKE_SYSTEM_NAME iOS: that makes CMake emit iphoneos flags and drop
    # the macabi suffix. It is a Darwin target built against the macOS SDK, distinguished
    # solely by the -target triple, which apple.sh already put in CFLAGS/LDFLAGS.
    MCAT_TOOLCHAIN="${WORK_DIR}/maccatalyst-toolchain.cmake"
    cat > "${MCAT_TOOLCHAIN}" <<CMAKE
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR ${MCAT_ARCH})
set(CMAKE_OSX_SYSROOT ${MCAT_SYSROOT})
set(CMAKE_OSX_ARCHITECTURES ${MCAT_ARCH})
set(CMAKE_C_FLAGS_INIT "-target ${MCAT_TARGET}")
set(CMAKE_CXX_FLAGS_INIT "-target ${MCAT_TARGET}")
# Objective-C/C++ need the target too. Setting only C/CXX left ggml's Metal backend
# (ggml-metal.m) compiled for plain macOS, and the link then failed with
#   ld: building for 'macCatalyst', but linking in object file (libggml-metal.a)
# which surfaced as a bogus "whisper >= 1.7.5 not found using pkg-config".
set(CMAKE_OBJC_FLAGS_INIT "-target ${MCAT_TARGET}")
set(CMAKE_OBJCXX_FLAGS_INIT "-target ${MCAT_TARGET}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-target ${MCAT_TARGET}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-target ${MCAT_TARGET}")
# The SDK sits on the find root path beside DEPS_DIR so SDK FRAMEWORKS resolve while host
# libraries still do not. Without it, MODE_LIBRARY ONLY confined the search to DEPS_DIR and
# ggml's find_package(BLAS) could not see Accelerate:
#   Could NOT find BLAS (missing: BLAS_LIBRARIES)  -- ggml-blas/CMakeLists.txt:98
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR} ${MCAT_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# Frameworks are searched separately from plain libraries; LAST lets the SDK supply
# Accelerate without letting a stray framework outrank a dep we built ourselves.
set(CMAKE_FIND_FRAMEWORK LAST)
CMAKE
    CMAKE_CROSS_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${MCAT_TOOLCHAIN}")
    ;;
  ios-arm64|ios-sim-arm64)
    IOS_TOOLCHAIN="${WORK_DIR}/ios-toolchain.cmake"
    cat > "${IOS_TOOLCHAIN}" <<CMAKE
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT ${IOS_SYSROOT})
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)
set(CMAKE_FIND_ROOT_PATH ${DEPS_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
CMAKE
    CMAKE_CROSS_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${IOS_TOOLCHAIN}")
    ;;
esac

# ── Meson cross files (for meson-based deps: dav1d, openh264) ──────────────
# Native builds leave MESON_CROSS_FILE empty; the meson deps skip --cross-file.
MESON_CROSS_FILE=""
case "${RID}" in
  win-arm64)
    MESON_CROSS_FILE="${WORK_DIR}/llvm-mingw-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CROSS_PREFIX}-clang'
cpp = '${CROSS_PREFIX}-clang++'
ar = '${CROSS_PREFIX}-ar'
strip = '${CROSS_PREFIX}-strip'
windres = '${CROSS_PREFIX}-windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
needs_exe_wrapper = true
MESON
    ;;
  win-x64)
    MESON_CROSS_FILE="${WORK_DIR}/mingw-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CROSS_PREFIX}-gcc-win32'
cpp = '${CROSS_PREFIX}-g++-win32'
ar = '${CROSS_PREFIX}-ar'
strip = '${CROSS_PREFIX}-strip'
windres = '${CROSS_PREFIX}-windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
needs_exe_wrapper = true
MESON
    ;;
  android-arm64|android-x64)
    MESON_CROSS_FILE="${WORK_DIR}/android-meson-cross.ini"
    case "${RID}" in
      android-arm64) MESON_CPU_FAMILY=aarch64; MESON_CPU=aarch64 ;;
      android-x64)   MESON_CPU_FAMILY=x86_64;  MESON_CPU=x86_64 ;;
    esac
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '${MESON_CPU_FAMILY}'
cpu = '${MESON_CPU}'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
needs_exe_wrapper = true
MESON
    ;;
  linux-armhf)
    MESON_CROSS_FILE="${WORK_DIR}/armhf-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = 'arm-linux-gnueabihf-gcc'
cpp = 'arm-linux-gnueabihf-g++'
ar = 'arm-linux-gnueabihf-ar'
strip = 'arm-linux-gnueabihf-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
needs_exe_wrapper = true
MESON
    ;;
  maccatalyst-arm64|maccatalyst-x64)
    MESON_CROSS_FILE="${WORK_DIR}/maccatalyst-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = 'strip'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-target', '${MCAT_TARGET}', '-isysroot', '${MCAT_SYSROOT}']
cpp_args = ['-target', '${MCAT_TARGET}', '-isysroot', '${MCAT_SYSROOT}']
c_link_args = ['-target', '${MCAT_TARGET}', '-isysroot', '${MCAT_SYSROOT}']
cpp_link_args = ['-target', '${MCAT_TARGET}', '-isysroot', '${MCAT_SYSROOT}']
[host_machine]
system = 'darwin'
cpu_family = '${MCAT_FFARCH}'
cpu = '${MCAT_FFARCH}'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
# Catalyst binaries RUN on the build host (macOS), unlike ios-*, so meson may execute
# its own test programs instead of guessing.
needs_exe_wrapper = false
MESON
    ;;
  ios-arm64|ios-sim-arm64)
    MESON_CROSS_FILE="${WORK_DIR}/ios-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = 'strip'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '${IOS_SYSROOT}', '${IOS_MINVER}']
cpp_args = ['-arch', 'arm64', '-isysroot', '${IOS_SYSROOT}', '${IOS_MINVER}']
c_link_args = ['-arch', 'arm64', '-isysroot', '${IOS_SYSROOT}', '${IOS_MINVER}']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '${IOS_SYSROOT}', '${IOS_MINVER}']
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
pkg_config_libdir = '${DEPS_DIR}/lib/pkgconfig'
needs_exe_wrapper = true
MESON
    ;;
esac

# ── Toolchain sanity: fail here, not 200 lines into the first dependency ──────────
# A cross RID whose compiler is missing from PATH otherwise surfaces as an opaque error
# from whichever dep configures first — win-arm64 shipped a provisioning bug that read
# "Unable to invoke compiler: aarch64-w64-mingw32-clang" out of libvpx's configure, with
# no hint that 03_install_packages.sh was the culprit. Check it once, here, where the
# message can name the actual cause.
#
# Deliberately in 05 rather than 02: gen-matrix.sh simulates 02_configure + 04_select_license
# on a runner that has no cross toolchains at all, so a hard check there would break the
# coverage-matrix job for every cross RID.
if [ -n "${CC:-}" ] && ! command -v "${CC}" >/dev/null 2>&1 && [ ! -x "${CC}" ]; then
  echo "ERROR: the compiler this RID configured is not executable: CC=${CC}" >&2
  echo "  RID=${RID}. Check that scripts/steps/03_install_packages.sh installed and PATH-exported" >&2
  echo "  the toolchain for this RID (it is sourced, so its 'export PATH' reaches this step)." >&2
  exit 1
fi
echo "Toolchain OK for ${RID}: ${CC:-<native>}"
