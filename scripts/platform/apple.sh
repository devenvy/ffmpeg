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
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN_LOADER=1
    WHISPER_BACKEND="metal"
    NPROC="sysctl -n hw.ncpu"
    BUILD_TYPE_LABEL="macOS (native)"
    ;;

  maccatalyst-arm64|maccatalyst-x64)
    # Every Apple arm sets these individually; omitting them silently inherited the Linux
    # defaults, and NPROC="nproc" does not exist on macOS -- openh264 died with
    # "meson compile: error: argument -j/--jobs: invalid int value". Found by diffing the
    # assignments of this arm against the osx/ios arms rather than one CI round-trip each.
    NPROC="sysctl -n hw.ncpu"
    WHISPER_BACKEND="metal"          # Catalyst has Metal, same as macOS/iOS
    BUILD_VULKAN=1                   # via MoltenVK; 04_select_license clears it for v2 cells
    # Follows iOS, not macOS, for the rest: Catalyst is a framework/link-only target, and
    # BUILD_VULKAN_LOADER stays off because MoltenVK is linked STATICALLY here (the loader is
    # only bundled for the flat osx-* layout).
    BUILD_FONTCONFIG=0
    BUILD_LIBSVTAV1=0                # same cross-compile static-archive failure as iOS
    BUILD_LIBWEBP=0                  # WebP cmake ships no .pc
    # Mac Catalyst: an iOS-API (UIKit) app running on macOS. It is neither ios-* nor osx-* —
    # it uses the macOS SDK with an ios*-macabi target triple, so it needs its own arm.
    # Consumers are .NET MAUI / Xcode targets that resolve the maccatalyst slice of the
    # xcframework; osx-* cannot substitute, because the slice would not validate.
    case "${RID}" in
      maccatalyst-arm64) MCAT_ARCH=arm64;  MCAT_FFARCH=aarch64 ;;
      maccatalyst-x64)   MCAT_ARCH=x86_64; MCAT_FFARCH=x86_64  ;;
    esac
    # 14.0 is the deployment floor: low enough that an app with a higher minimum still links
    # against us (a library min below the app's is always compatible), high enough to avoid
    # the earliest macabi releases. Catalyst itself starts at iOS 13.1 / macOS 10.15.
    MCAT_TARGET="${MCAT_ARCH}-apple-ios14.0-macabi"
    MCAT_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
    # Same assign-then-export discipline as the iOS arm: `export X=$(cmd)` would mask an
    # xcrun failure from set -e and yield an empty CC.
    CC="$(xcrun --sdk macosx --find clang)";      export CC
    CXX="$(xcrun --sdk macosx --find clang++)";   export CXX
    AR="$(xcrun --sdk macosx --find ar)";         export AR
    RANLIB="$(xcrun --sdk macosx --find ranlib)"; export RANLIB
    # -target carries BOTH arch and deployment target for macabi; there is no
    # -mmaccatalyst-version-min, and -arch alone would build a plain macOS object.
    EXTRA_CFLAGS="-target ${MCAT_TARGET} -isysroot ${MCAT_SYSROOT}"
    EXTRA_CXXFLAGS="-target ${MCAT_TARGET} -isysroot ${MCAT_SYSROOT}"
    EXTRA_LDFLAGS="-target ${MCAT_TARGET} -isysroot ${MCAT_SYSROOT}"
    # Exported for the same reason as iOS: autotools deps invoke a generic clang and their
    # configure link test fails without the target/sysroot in the environment.
    export CFLAGS="${EXTRA_CFLAGS}"
    export CXXFLAGS="${EXTRA_CXXFLAGS}"
    export LDFLAGS="${EXTRA_LDFLAGS}"
    CONFIGURE_FLAGS+=(
      --enable-cross-compile --target-os=darwin --arch="${MCAT_FFARCH}"
      --cc="${CC}" --cxx="${CXX}" --ar="${AR}" --ranlib="${RANLIB}"
      --sysroot="${MCAT_SYSROOT}"
      --enable-videotoolbox
      --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox
      --enable-securetransport
    )
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    HWACCEL_FEATURES="VideoToolbox"
    BUILD_TYPE_LABEL="Mac Catalyst (macabi)"
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
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    HWACCEL_FEATURES="VideoToolbox"
    # Vulkan via MoltenVK (Vulkan-over-Metal) — for FFmpeg's Vulkan GPU filters (no Metal
    # equivalent in the filtergraph). v3 only: MoltenVK is Apache-2.0, so 04_select_license
    # clears BUILD_VULKAN for the App-Store-safe v2 cells. Whisper still uses the native Metal
    # ggml backend. NOTE: unlike macOS, iOS does NOT build the Khronos Vulkan-Loader — not
    # because upstream lacks iOS support (its CMake has an explicit IOS/VK_USE_PLATFORM_IOS_MVK
    # branch), but because vulkan-loader.sh passes no iOS CMake toolchain, so it stays
    # macOS-only in this repo — and it does NOT ship MoltenVK as its own framework: FFmpeg's runtime
    # dlopen only ever tries the leaf names libvulkan.dylib / libvulkan.1.dylib /
    # libMoltenVK.dylib, none of which resolves from inside an app bundle. moltenvk.sh therefore
    # installs libMoltenVK.a and adds --enable-vulkan-static, linking the driver INTO the libav*
    # frameworks. Nothing Vulkan-shaped is staged separately for iOS.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN=1
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    WHISPER_BACKEND="metal"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_FONTCONFIG=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_LIBSVTAV1=0  # SVT-AV1 static-archive step fails cross-compiling; AV1 covered by libaom
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_LIBWEBP=0    # WebP cmake ships no .pc; image-only codec, not needed for mobile decode
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    NPROC="sysctl -n hw.ncpu"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_TYPE_LABEL="iOS (SDK cross)"
    ;;

  *) echo "platform/apple.sh: unexpected RID '${RID}' — add a case arm for it" >&2; exit 1 ;;
esac
