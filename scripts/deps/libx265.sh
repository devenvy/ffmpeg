#!/usr/bin/env bash
set -euo pipefail
# x265 — H.265 / HEVC software encoder (GPL-2.0+). GPL builds only; pinned to
# 3.6 (4.0+ has broken aarch64 NEON intrinsics).
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBX265}" == "1" ]]; then
  if ! command -v cmake &>/dev/null; then
    case "${RID}" in
      osx-*)       brew list cmake &>/dev/null || brew install cmake ;;
      linux-musl-*) apk add --no-cache cmake ;;
      *)           sudo apt-get install -y cmake ;;
    esac
  fi

  echo "Building libx265 (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf x265_git
  # x265 4.0+ has broken aarch64 NEON intrinsics (intrapred-prim.cpp):
  # https://github.com/HandBrake/HandBrake/issues/3652
  # https://github.com/microsoft/vcpkg/issues/46880
  clone_dep x265 "${WORK_DIR}/x265_git"
  cd x265_git || exit 1

  # Apply upstream fix for CMake 4.x: change cmake_policy OLD → NEW
  # https://mailman.videolan.org/pipermail/x265-devel/2025-February/014251.html
  sed -i.bak 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/' source/CMakeLists.txt
  sed -i.bak 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/' source/CMakeLists.txt

  X265_EXTRA=()
  case "${RID}" in
    linux-armhf) X265_EXTRA+=(-DENABLE_ASSEMBLY=OFF) ;;
    osx-*)       X265_EXTRA+=(-DENABLE_ASSEMBLY=OFF) ;;
    android-*|ios-*) X265_EXTRA+=(-DENABLE_ASSEMBLY=OFF) ;;
    win-x64)     X265_EXTRA+=(-DCMAKE_SYSTEM_PROCESSOR=x86_64
                   -DCMAKE_C_FLAGS="-static-libgcc -O2"
                   -DCMAKE_CXX_FLAGS="-static-libgcc -static-libstdc++ -O2") ;;
  esac

  cmake -B build -S source \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DLIB_INSTALL_DIR=lib \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_LIBNUMA=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
    ${X265_EXTRA[@]+"${X265_EXTRA[@]}"}
  cmake --build build -j"$(${NPROC})"
  cmake --install build

  # Overwrite x265.pc — cmake-generated one has platform-specific Libs.private
  # (e.g. -lgcc_s -lrt) that break pkg-config --static on macOS
  X265_PRIVATE_LIBS="-lstdc++ -lm -lpthread"
  case "${RID}" in
    osx-*)           X265_PRIVATE_LIBS="-lc++ -lm" ;;
    android-*|ios-*) X265_PRIVATE_LIBS="-lc++ -lm" ;;  # NDK/iOS use libc++, pthread is in libc
    win-*)           X265_PRIVATE_LIBS="-lstdc++ -lm" ;;
  esac

  cat > "${DEPS_DIR}/lib/pkgconfig/x265.pc" <<PKGCONFIG
prefix=${DEPS_DIR}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: $(dep_version x265)
Libs: -L\${libdir} -lx265
Libs.private: ${X265_PRIVATE_LIBS}
Cflags: -I\${includedir}
PKGCONFIG

  CONFIGURE_FLAGS+=(--enable-libx265)
  echo "libx265 (H.265/HEVC software encoder) enabled."
else
  echo "Skipping libx265 (GPL builds only)."
fi
