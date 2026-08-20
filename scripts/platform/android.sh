#!/usr/bin/env bash
set -euo pipefail
# Android platform config (NDK cross).
# SOURCED by steps/02_configure.sh based on the RID family; shares its environment.
case "${RID}" in
  android-arm64)
    # Locate the NDK. ANDROID_NDK_HOME is an optional OVERRIDE — normally the NDK is found
    # automatically: CI/dev shells export ANDROID_NDK_LATEST_HOME / ANDROID_NDK_ROOT, and a
    # standard SDK install keeps it under $ANDROID_SDK_ROOT/ndk/<version>. So an Android build
    # "just works" wherever the SDK/NDK is installed, without a platform-specific top-level arg.
    if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
      if   [[ -n "${ANDROID_NDK_LATEST_HOME:-}" ]]; then ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
      elif [[ -n "${ANDROID_NDK_ROOT:-}" ]];        then ANDROID_NDK_HOME="${ANDROID_NDK_ROOT}"
      else
        for _sdk in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}"; do
          [[ -n "${_sdk}" && -d "${_sdk}/ndk" ]] || continue
          ANDROID_NDK_HOME="$(ls -d "${_sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1)"
          ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
          [[ -n "${ANDROID_NDK_HOME}" ]] && break
        done
      fi
    fi
    [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]] || {
      echo "ERROR: Android NDK not found. Install it under the Android SDK (\$ANDROID_SDK_ROOT/ndk/<version>) or set ANDROID_NDK_HOME." >&2
      exit 1; }
    export ANDROID_NDK_HOME
    API=28  # Android 9+. Required so ggml-vulkan's Vulkan 1.1 symbols resolve (see below).
    TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
    ANDROID_TRIPLE=aarch64-linux-android
    ANDROID_ABI=arm64-v8a
    export CC="${TOOLCHAIN}/bin/${ANDROID_TRIPLE}${API}-clang"
    export CXX="${CC}++"
    export AR="${TOOLCHAIN}/bin/llvm-ar"
    export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
    export STRIP="${TOOLCHAIN}/bin/llvm-strip"
    export NM="${TOOLCHAIN}/bin/llvm-nm"
    PKGS=(autoconf automake build-essential cmake curl gperf git libtool meson nasm ninja-build
          patchelf pkg-config xz-utils yasm
          glslc glslang-tools)
    CONFIGURE_FLAGS+=(
      --enable-cross-compile --target-os=android --arch=aarch64
      --cc="${CC}" --cxx="${CXX}" --ar="${AR}" --ranlib="${RANLIB}"
      --strip="${STRIP}" --nm="${NM}"
      --sysroot="${TOOLCHAIN}/sysroot"
      --enable-jni --enable-mediacodec
      --enable-hwaccel=h264_mediacodec --enable-hwaccel=hevc_mediacodec
      --enable-decoder=h264_mediacodec --enable-decoder=hevc_mediacodec
    )
    HWACCEL_FEATURES="MediaCodec"
    BUILD_VULKAN=1        # FFmpeg Vulkan (header-only + runtime dlopen); system libvulkan on API 28+
    # whisper ggml backend = Vulkan. ggml-vulkan links Vulkan 1.1 symbols directly
    # (e.g. vkGetPhysicalDeviceFeatures2), exported by the API-28 libvulkan stub and present on
    # Android 9+ devices at runtime — hence API=28 above (drops Android 7.0-8.1 for these libs).
    # GPU used when a Vulkan device is present; CPU fallback otherwise.
    WHISPER_BACKEND="vulkan"
    BUILD_FONTCONFIG=0
    BUILD_LIBSVTAV1=0  # SVT-AV1 static-archive step fails under the NDK; AV1 covered by libaom
    BUILD_LIBWEBP=0    # WebP cmake ships no .pc; image-only codec, not needed for mobile decode
    BUILD_TYPE_LABEL="Android (NDK cross)"
    ;;

esac
