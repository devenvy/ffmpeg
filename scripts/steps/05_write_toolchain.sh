#!/usr/bin/env bash
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
  android-arm64)
    CMAKE_CROSS_ARGS+=(
      -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="${ANDROID_ABI}"
      -DANDROID_PLATFORM="android-${API}"
    )
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
  android-arm64)
    MESON_CROSS_FILE="${WORK_DIR}/android-meson-cross.ini"
    cat > "${MESON_CROSS_FILE}" <<MESON
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
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
