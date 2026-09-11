#!/usr/bin/env bash
set -euo pipefail
# libvpx — VP8 / VP9 video encoder + decoder (BSD-3), the WebM reference
# codec.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_LIBVPX}" == "1" ]]; then
  echo "Building libvpx (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf libvpx
  clone_dep libvpx "${WORK_DIR}/libvpx"
  cd libvpx || exit 1

  VPX_ARGS=(
    --prefix="${DEPS_DIR}"
    --disable-shared
    --enable-static
    --enable-vp8
    --enable-vp9
    --enable-vp9-highbitdepth
    --disable-examples
    --disable-tools
    --disable-docs
    --disable-unit-tests
    --enable-pic
  )
  VPX_CROSS=""

  case "${RID}" in
    linux-armhf)
      VPX_ARGS+=(--target=armv7-linux-gcc --extra-cflags="-mfpu=neon")
      VPX_CROSS="arm-linux-gnueabihf-"
      ;;
    win-x64)
      VPX_ARGS+=(--target=x86_64-win64-gcc --extra-cflags="-static-libgcc")
      VPX_CROSS="${CROSS_PREFIX}-"
      ;;
    win-arm64)
      # libvpx's arm64-win64-gcc target covers any GCC-style driver, llvm-mingw's clang
      # included. This builds a static .a, so the runtime-linkage flags that matter live on
      # FFmpeg's own link — see platform/windows.sh's EXTRA_LDFLAGS.
      VPX_ARGS+=(--target=arm64-win64-gcc)
      VPX_CROSS="${CROSS_PREFIX}-"
      ;;
    android-arm64)
      VPX_ARGS+=(--target=arm64-android-gcc --extra-cflags="-fPIC")
      ;;
    android-x64)
      VPX_ARGS+=(--target=x86_64-android-gcc --extra-cflags="-fPIC")
      ;;
    maccatalyst-arm64|maccatalyst-x64)
      # libvpx picks its assembler config from --target, and its darwin targets imply a
      # platform. macabi is not one of them, so use the plain darwin target for the arch and
      # carry the real platform in the flags, which must reach the ASM as well as the C --
      # the same failure mode x264 hit (asm objects tagged macOS, link refuses to mix).
      case "${RID}" in
        maccatalyst-arm64) VPX_TARGET="arm64-darwin-gcc"  ;;
        maccatalyst-x64)   VPX_TARGET="x86_64-darwin-gcc" ;;
      esac
      VPX_ARGS+=(--target="${VPX_TARGET}"
                 --extra-cflags="-target ${MCAT_TARGET} -isysroot ${MCAT_SYSROOT}")
      ;;
    ios-arm64)
      # Device only — libvpx's arm64-darwin-gcc target is iOS-device-specific.
      # The simulator slice is built lean (no libvpx) so it never reaches here.
      VPX_ARGS+=(--target=arm64-darwin-gcc
                 --extra-cflags="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}")
      ;;
  esac

  if [[ -n "${VPX_CROSS}" ]]; then
    CROSS="${VPX_CROSS}" ./configure "${VPX_ARGS[@]}"
    CROSS="${VPX_CROSS}" make -j"$(${NPROC})"
    CROSS="${VPX_CROSS}" make install
  else
    ./configure "${VPX_ARGS[@]}"
    make -j"$(${NPROC})"
    make install
  fi

  CONFIGURE_FLAGS+=(--enable-libvpx)
  echo "libvpx (VP8/VP9) support enabled."
else
  echo "Skipping libvpx (not needed for ${RID})."
fi
