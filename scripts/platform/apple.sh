#!/usr/bin/env bash
set -euo pipefail
# Apple platform config (macOS + iOS).
# SOURCED by steps/02_configure.sh based on the RID family; shares its environment.
case "${RID}" in
  osx-*)
    # macOS — native build (Intel or Apple Silicon)
    CONFIGURE_FLAGS+=(
      --enable-videotoolbox --enable-audiotoolbox
      --enable-securetransport   # OS-native TLS/https (no dependency)
    )
    HWACCEL_FEATURES="VideoToolbox AudioToolbox"
    BUILD_VULKAN=1
    # macOS has no native Vulkan: build the Vulkan-Loader and pair it with MoltenVK (moltenvk.sh)
    # so --enable-vulkan actually runs on Metal. Both are bundled into the artifact by 08. This is
    # v3-only — 04_select_license clears BUILD_VULKAN for v2 (MoltenVK is Apache-2.0). Whisper still
    # uses the Metal ggml backend directly; Vulkan is for FFmpeg's GPU filters.
    BUILD_VULKAN_LOADER=1
    WHISPER_BACKEND="metal"
    NPROC="sysctl -n hw.ncpu"
    BUILD_TYPE_LABEL="macOS (native)"
    ;;

  ios-arm64|ios-sim-arm64)
    case "${RID}" in
      ios-arm64)     IOS_SDK=iphoneos;        IOS_MINVER="-miphoneos-version-min=13.0" ;;
      ios-sim-arm64) IOS_SDK=iphonesimulator; IOS_MINVER="-mios-simulator-version-min=13.0" ;;
    esac
    IOS_SYSROOT="$(xcrun --sdk "${IOS_SDK}" --show-sdk-path)"
    # Assign then export separately: `export X=$(cmd)` returns the export's status (0),
    # masking an xcrun failure from `set -e` — a missing SDK would yield an empty CC and
    # a broken build instead of aborting. Bare assignment lets set -e catch it.
    CC="$(xcrun --sdk "${IOS_SDK}" --find clang)";     export CC
    CXX="$(xcrun --sdk "${IOS_SDK}" --find clang++)";  export CXX
    AR="$(xcrun --sdk "${IOS_SDK}" --find ar)";        export AR
    RANLIB="$(xcrun --sdk "${IOS_SDK}" --find ranlib)"; export RANLIB
    EXTRA_CFLAGS="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}"
    EXTRA_CXXFLAGS="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}"
    EXTRA_LDFLAGS="-arch arm64 ${IOS_MINVER} -isysroot ${IOS_SYSROOT}"
    # Autotools deps (kvazaar, libogg/vorbis, opus, lame) invoke a GENERIC clang —
    # unlike the target-prefixed mingw/NDK compilers — so they need the arch/sysroot
    # in the environment or their ./configure link test fails ("C compiler cannot
    # create executables"). Export them so every dep's configure/cmake/meson inherits.
    export CFLAGS="${EXTRA_CFLAGS}"
    export CXXFLAGS="${EXTRA_CXXFLAGS}"
    export LDFLAGS="${EXTRA_LDFLAGS}"
    CONFIGURE_FLAGS+=(
      --enable-cross-compile --target-os=darwin --arch=aarch64
      --cc="${CC}" --cxx="${CXX}" --ar="${AR}" --ranlib="${RANLIB}"
      --sysroot="${IOS_SYSROOT}"
      --enable-videotoolbox
      --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox
      --enable-securetransport   # OS-native TLS/https (no dependency)
    )
    HWACCEL_FEATURES="VideoToolbox"
    # Vulkan via MoltenVK (Vulkan-over-Metal) for parity with macOS — for FFmpeg's Vulkan GPU
    # filters (no Metal equivalent in the filtergraph). v3 only: MoltenVK is Apache-2.0, so
    # 04_select_license clears BUILD_VULKAN for the App-Store-safe v2 cells. Whisper still uses the
    # native Metal ggml backend. NOTE: unlike macOS, iOS does NOT build the Khronos Vulkan-Loader —
    # it fails to build for the iOS SDK (loader asm-gen, Error 137) and is unnecessary: on iOS
    # MoltenVK IS the driver and is linked/loaded directly (no ICD-loader indirection). moltenvk.sh
    # provides libMoltenVK for the iOS slice; 08 bundles it as a framework.
    BUILD_VULKAN=1
    WHISPER_BACKEND="metal"
    BUILD_FONTCONFIG=0
    BUILD_LIBSVTAV1=0  # SVT-AV1 static-archive step fails cross-compiling; AV1 covered by libaom
    BUILD_LIBWEBP=0    # WebP cmake ships no .pc; image-only codec, not needed for mobile decode
    NPROC="sysctl -n hw.ncpu"
    BUILD_TYPE_LABEL="iOS (SDK cross)"
    ;;

esac
