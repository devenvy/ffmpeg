#!/usr/bin/env bash
set -euo pipefail
# x264 — H.264 / AVC software encoder (GPL-2.0+). GPL builds only.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBX264}" == "1" ]]; then
  echo "Building libx264 (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf x264
  git clone --depth 1 --branch stable https://code.videolan.org/videolan/x264.git
  cd x264 || exit 1

  X264_ARGS=(
    --prefix="${DEPS_DIR}"
    --enable-static
    --disable-shared
    --enable-pic
    --disable-cli
  )

  case "${RID}" in
    linux-armhf)
      X264_ARGS+=(--cross-prefix=arm-linux-gnueabihf- --host=arm-linux-gnueabihf)
      ;;
    win-x64)
      X264_ARGS+=(--cross-prefix="${CROSS_PREFIX}-" --host=x86_64-w64-mingw32)
      ;;
    android-arm64)
      X264_ARGS+=(--host=aarch64-linux-android --sysroot="${TOOLCHAIN}/sysroot")
      ;;
    ios-arm64)
      # Device only (sim slice is lean). The iOS arch/min-version/sysroot must
      # reach the ASM too (--extra-asflags) or x264's asm objects are tagged
      # 'macOS' and the iOS linker rejects the archive.
      X264_ARGS+=(--host=aarch64-apple-darwin
                  --extra-cflags="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}"
                  --extra-asflags="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}"
                  --extra-ldflags="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}")
      ;;
  esac

  ./configure "${X264_ARGS[@]}"
  make -j"$(${NPROC})"
  make install

  CONFIGURE_FLAGS+=(--enable-libx264)
  echo "libx264 (H.264 software encoder) enabled."
else
  echo "Skipping libx264 (GPL builds only)."
fi
