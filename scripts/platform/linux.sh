#!/usr/bin/env bash
set -euo pipefail
# Linux platform config (glibc x64/arm64/armhf + musl).
# SOURCED by steps/02_configure.sh based on the RID family; shares its environment.
case "${RID}" in
  linux-x64)
    # Hwaccel dispatch libraries (libdrm/libva/libvpl/Vulkan-Loader) are built
    # from source as STATIC and linked into FFmpeg (see the BUILD_*_SOURCE flags),
    # so the artifact has NO external .so dependencies — it starts on any distro
    # without an apt install; the static dispatch layers dlopen the system GPU
    # driver at runtime. VDPAU is dropped: it's legacy (NVIDIA→NVDEC, others→VAAPI)
    # and the only thing that dragged in an X11 dependency.
    PKGS=(autoconf automake build-essential cmake curl gperf git libtool meson nasm ninja-build
          patchelf pkg-config xz-utils yasm
          glslc glslang-tools spirv-headers spirv-tools)
    CONFIGURE_FLAGS+=(
      --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec
      --enable-vaapi --enable-libdrm --enable-libvpl
      --enable-v4l2-m2m
    )
    HWACCEL_FEATURES="CUDA NVENC NVDEC VAAPI libdrm QSV V4L2-M2M"
    BUILD_NVIDIA=1
    BUILD_VULKAN=1
    BUILD_LIBDRM_SOURCE=1
    BUILD_LIBVA_SOURCE=1
    BUILD_VPL_SOURCE=1
    BUILD_VULKAN_LOADER=1
    WHISPER_BACKEND="vulkan"
    # Built in the manylinux_2_28 container (glibc 2.28) to keep the runtime floor
    # low. On that old glibc, libpthread/libdl are SEPARATE libraries; on glibc
    # >= 2.34 (e.g. ubuntu-latest) they are folded into libc. FFmpeg's isolated
    # per-dependency configure link checks don't carry the global -pthread, so
    # static deps that use them (libvpl -> pthread_key_*, ggml/whisper -> dl*) fail
    # to link during ./configure and get silently disabled. Name them explicitly
    # via --extra-libs (a no-op stub on newer glibc, so harmless if the host moves).
    EXTRA_LIBS="-lpthread -ldl"
    # Force -fPIC on ALL static dependency builds. The manylinux (RHEL) gcc-toolset
    # is NOT built --enable-default-pie, unlike Ubuntu's gcc, so static libs that
    # don't explicitly request -fPIC produce non-PIC objects (R_X86_64_32S relocs)
    # that fail to link into FFmpeg's shared libav*.so. Exporting CFLAGS/CXXFLAGS is
    # honored by autotools/cmake/meson dep builds alike (meson also PICs by default).
    export CFLAGS="${CFLAGS:+${CFLAGS} }-fPIC"
    export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-fPIC"
    BUILD_TYPE_LABEL="Linux glibc"
    ;;

  linux-arm64)
    # Static hwaccel dispatch libs (see linux-x64) — no external .so deps. No QSV
    # (libvpl) on ARM.
    PKGS=(autoconf automake build-essential cmake curl gperf git libtool meson nasm ninja-build
          patchelf pkg-config xz-utils
          glslc glslang-tools spirv-headers spirv-tools)
    CONFIGURE_FLAGS+=(
      --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec
      --enable-vaapi --enable-libdrm
      --enable-v4l2-m2m
    )
    HWACCEL_FEATURES="CUDA NVENC NVDEC VAAPI libdrm V4L2-M2M"
    BUILD_NVIDIA=1
    BUILD_VULKAN=1
    BUILD_LIBDRM_SOURCE=1
    BUILD_LIBVA_SOURCE=1
    BUILD_VULKAN_LOADER=1
    WHISPER_BACKEND="vulkan"
    # See linux-x64: manylinux_2_28 (glibc 2.28) separates libpthread/libdl, so
    # name them for FFmpeg's per-dependency configure link checks (libvpl, ggml).
    EXTRA_LIBS="-lpthread -ldl"
    # See linux-x64: RHEL gcc-toolset lacks default-PIE, force -fPIC on static deps.
    export CFLAGS="${CFLAGS:+${CFLAGS} }-fPIC"
    export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-fPIC"
    BUILD_TYPE_LABEL="Linux glibc"
    ;;

  linux-armhf)
    # 32-bit ARM (Raspberry Pi 3/4/5 with 32-bit OS) — cross-compiled from x64
    PKGS=(autoconf automake build-essential cmake curl gperf git libtool meson nasm ninja-build
          patchelf pkg-config xz-utils
          crossbuild-essential-armhf)
    CONFIGURE_FLAGS+=(
      --arch=arm --cpu=armv7-a+vfpv3
      --cross-prefix=arm-linux-gnueabihf-
      --pkg-config=pkg-config
      --enable-cross-compile --target-os=linux
      --enable-v4l2-m2m
    )
    HWACCEL_FEATURES="V4L2-M2M"
    BUILD_LIBSVTAV1=0  # SVT-AV1 requires 64-bit
    BUILD_VULKAN=1        # FFmpeg Vulkan (header-only + runtime dlopen) — video/filter accel
    WHISPER_BACKEND="cpu" # no dependable 32-bit-ARM GPU path for ggml; CPU-only ASR here
    BUILD_TYPE_LABEL="Linux glibc (cross-compiled)"
    ;;

  linux-musl-x64)
    # musl/Alpine — native build inside Alpine container. Like the glibc targets, the
    # hwaccel dispatch libraries (libdrm/libva/libvpl/Vulkan-Loader) are built from
    # source as STATIC and linked in (the BUILD_*_SOURCE flags) rather than taken from
    # Alpine's -dev packages — otherwise FFmpeg links the system libva.so.2/libvpl.so.2
    # dynamically and the artifact won't start on a stock musl system that lacks them.
    # The static dispatch layers dlopen the GPU driver at runtime, so VAAPI/QSV still
    # work when a driver is present. (libstdc++/libgcc_s remain — whisper's C++ runtime,
    # a standard `apk add libstdc++ libgcc` on any musl host.)
    PKGS_APK=(autoconf automake libtool build-base cmake curl diffutils gperf git linux-headers
              meson nasm ninja patchelf perl pkgconf xz yasm
              glslang shaderc)
    CONFIGURE_FLAGS+=(
      --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec
      --enable-vaapi --enable-libdrm --enable-libvpl
    )
    HWACCEL_FEATURES="CUDA NVENC NVDEC VAAPI libdrm QSV"
    BUILD_NVIDIA=1
    BUILD_VULKAN=1
    BUILD_LIBDRM_SOURCE=1
    BUILD_LIBVA_SOURCE=1
    BUILD_VPL_SOURCE=1
    BUILD_VULKAN_LOADER=1
    WHISPER_BACKEND="vulkan"
    BUILD_TYPE_LABEL="Linux musl (native Alpine)"
    ;;

esac
