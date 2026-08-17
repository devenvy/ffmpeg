#!/usr/bin/env bash
############################################
# Step 2: RID-Specific Configuration
#
# Everything that differs per target — the cross toolchain (compiler,
# sysroot), the FFmpeg configure flags for that platform's hardware
# acceleration, and which optional libraries to build. Sets the BUILD_*
# switches that the later steps read.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── Per-RID configuration ─────────────────────────────────────────────────

PKGS=()
CONFIGURE_FLAGS=()
HWACCEL_FEATURES=""
BUILD_NVIDIA=0
BUILD_VULKAN=0
BUILD_AMF=0
BUILD_VPL_SOURCE=0
# Build the hwaccel dispatch libs from source as STATIC (Linux) so the artifact
# has no external .so deps; the static layers dlopen the system driver at runtime.
BUILD_LIBDRM_SOURCE=0
BUILD_LIBVA_SOURCE=0
BUILD_VULKAN_LOADER=0
BUILD_LIBVPX=1
BUILD_LIBX264=0
BUILD_LIBX265=0
BUILD_ZLIB=1
BUILD_FREETYPE=1
BUILD_FONTCONFIG=1
BUILD_LIBOPUS=1
BUILD_LIBAOM=1
BUILD_LIBSVTAV1=1
BUILD_LIBWEBP=1
BUILD_LIBDAV1D=1
BUILD_LIBVORBIS=1
BUILD_LIBSOXR=1
BUILD_LIBMP3LAME=1
BUILD_LIBOPENH264=1
BUILD_LIBKVAZAAR=1
BUILD_LIBZIMG=1
BUILD_LIBASS=1
# TLS/https backend. Windows uses SChannel and Apple uses SecureTransport (both
# OS-native, no dependency — enabled directly in the per-RID flags below);
# Linux/Android have no system TLS FFmpeg can use, so they build OpenSSL. Since
# --disable-autodetect is set, every backend must be requested explicitly.
BUILD_OPENSSL=0
EXTRA_CFLAGS=""
EXTRA_CXXFLAGS=""
EXTRA_LDFLAGS=""
EXTRA_LIBS=""          # extra link libs for configure checks + final link (e.g. old-glibc -lpthread -ldl)
THREAD_FLAG="--enable-pthreads"
PIC_FLAG="--enable-pic"
NPROC="nproc"
BUILD_TYPE_LABEL=""
# whisper.cpp ggml compute backend for the af_whisper filter (always built).
# metal (Apple) | vulkan (Linux/Win/Android) | cpu (fallback / armhf). Default cpu.
WHISPER_BACKEND="cpu"

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
    # musl/Alpine — native build inside Alpine container
    PKGS_APK=(autoconf automake libtool build-base cmake curl diffutils gperf git linux-headers
              meson nasm ninja patchelf perl pkgconf xz yasm
              libdrm-dev libva-dev libvpl-dev
              glslang shaderc vulkan-loader-dev)
    CONFIGURE_FLAGS+=(
      --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec
      --enable-vaapi --enable-libdrm --enable-libvpl
    )
    HWACCEL_FEATURES="CUDA NVENC NVDEC VAAPI libdrm QSV"
    BUILD_NVIDIA=1
    BUILD_VULKAN=1
    WHISPER_BACKEND="vulkan"
    BUILD_TYPE_LABEL="Linux musl (native Alpine)"
    ;;

  win-x64)
    # Windows — cross-compiled from Linux with mingw-w64 (win32 threading)
    # Explicitly use the -win32 toolchain variant to avoid a runtime
    # dependency on libwinpthread-1.dll (the -posix variant pulls it in).
    # mingw-w64-tools -> gendef, llvm -> llvm-dlltool: together these turn each
    # built DLL into an MSVC-consumable COFF import library (see artifact staging).
    PKGS=(cmake git mingw-w64 mingw-w64-tools llvm meson nasm ninja-build pkg-config curl xz-utils yasm
          glslc glslang-tools)
    CROSS_PREFIX="x86_64-w64-mingw32"
    export CC="${CROSS_PREFIX}-gcc-win32"
    export CXX="${CROSS_PREFIX}-g++-win32"
    export AR="${CROSS_PREFIX}-ar"
    export RANLIB="${CROSS_PREFIX}-ranlib"
    export NM="${CROSS_PREFIX}-nm"
    export STRIP="${CROSS_PREFIX}-strip"
    EXTRA_CFLAGS="-static-libgcc -static-libstdc++ -O2 -pipe"
    EXTRA_CXXFLAGS="-static-libgcc -static-libstdc++ -O2 -pipe"
    EXTRA_LDFLAGS="-static-libgcc -static-libstdc++"
    CONFIGURE_FLAGS+=(
      --cross-prefix="${CROSS_PREFIX}-"
      --cc="${CROSS_PREFIX}-gcc-win32"
      --cxx="${CROSS_PREFIX}-g++-win32"
      --pkg-config=pkg-config
      --arch=x86_64 --target-os=mingw32
      --enable-cross-compile
      --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec
      --enable-d3d11va --enable-dxva2
      --enable-amf --enable-libvpl
      --enable-mediafoundation
      --enable-schannel   # OS-native TLS/https (no dependency)
    )
    # d3d12va omitted: needs D3D12 video-decode headers (ID3D12VideoDecoder) that
    # the mingw-w64 toolchain doesn't ship. d3d11va + dxva2 cover Windows hw decode.
    HWACCEL_FEATURES="CUDA NVENC NVDEC D3D11VA DXVA2 AMF QSV(libvpl) MediaFoundation"
    THREAD_FLAG="--enable-w32threads"
    PIC_FLAG=""  # not applicable to mingw
    BUILD_NVIDIA=1
    BUILD_VULKAN=1
    BUILD_AMF=1
    BUILD_VPL_SOURCE=1
    BUILD_FONTCONFIG=0  # not on Windows: needs a runtime fonts.conf for no real gain.
                        # libass uses DirectWrite; drawtext uses fontfile= (the Windows norm).
    # whisper ggml-vulkan cross-compiles under mingw with build-env additions handled in the
    # build_whisper block: a dlltool-generated libvulkan-1.dll.a import-lib, a
    # THREAD_POWER_THROTTLING_* compat shim, and SPIRV-Headers on the include path.
    WHISPER_BACKEND="vulkan"
    BUILD_TYPE_LABEL="Windows (cross-compiled from Linux)"
    ;;

  osx-*)
    # macOS — native build (Intel or Apple Silicon)
    CONFIGURE_FLAGS+=(
      --enable-videotoolbox --enable-audiotoolbox
      --enable-securetransport   # OS-native TLS/https (no dependency)
    )
    HWACCEL_FEATURES="VideoToolbox AudioToolbox"
    BUILD_VULKAN=1
    WHISPER_BACKEND="metal"
    NPROC="sysctl -n hw.ncpu"
    BUILD_TYPE_LABEL="macOS (native)"
    ;;

  android-arm64)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME (path to Android NDK r26+)}"
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
    BUILD_VULKAN=0        # Apple has no native Vulkan; MoltenVK deferred (separate investigation)
    WHISPER_BACKEND="metal"
    BUILD_FONTCONFIG=0
    BUILD_LIBSVTAV1=0  # SVT-AV1 static-archive step fails cross-compiling; AV1 covered by libaom
    BUILD_LIBWEBP=0    # WebP cmake ships no .pc; image-only codec, not needed for mobile decode
    NPROC="sysctl -n hw.ncpu"
    BUILD_TYPE_LABEL="iOS (SDK cross)"
    ;;

  *)
    echo "Error: unsupported BUILD_RID '${RID}'" >&2
    exit 1
    ;;
esac

# Linux and Android have no OS TLS backend FFmpeg can use, so they build OpenSSL
# (Apache-2.0 — GPL/LGPL-compatible, no --enable-nonfree needed). Windows/Apple
# already got their native backend above.
case "${RID}" in
  linux-*|android-*) BUILD_OPENSSL=1 ;;
esac
