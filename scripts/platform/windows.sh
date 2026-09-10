#!/usr/bin/env bash
set -euo pipefail
# Windows platform config: win-x64 via mingw-w64, win-arm64 via llvm-mingw.
# SOURCED by steps/02_configure.sh based on the RID family; shares its environment.
case "${RID}" in
  win-x64)
    # Windows — cross-compiled from Linux with mingw-w64 (win32 threading)
    # Explicitly use the -win32 toolchain variant to avoid a runtime
    # dependency on libwinpthread-1.dll (the -posix variant pulls it in).
    # mingw-w64-tools -> gendef, llvm -> llvm-dlltool: together these turn each
    # built DLL into an MSVC-consumable COFF import library (see artifact staging).
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    PKGS=(autoconf automake build-essential gperf libtool
          cmake git mingw-w64 mingw-w64-tools llvm meson nasm ninja-build pkg-config curl xz-utils yasm
          glslc glslang-tools)
    CROSS_PREFIX="x86_64-w64-mingw32"
    export CC="${CROSS_PREFIX}-gcc-win32"
    export CXX="${CROSS_PREFIX}-g++-win32"
    export AR="${CROSS_PREFIX}-ar"
    export RANLIB="${CROSS_PREFIX}-ranlib"
    export NM="${CROSS_PREFIX}-nm"
    export STRIP="${CROSS_PREFIX}-strip"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    EXTRA_CFLAGS="-static-libgcc -static-libstdc++ -O2 -pipe"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    EXTRA_CXXFLAGS="-static-libgcc -static-libstdc++ -O2 -pipe"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
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
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    HWACCEL_FEATURES="CUDA NVENC NVDEC D3D11VA DXVA2 AMF QSV(libvpl) MediaFoundation"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    THREAD_FLAG="--enable-w32threads"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    PIC_FLAG=""  # not applicable to mingw
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_NVIDIA=1
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN=1
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_AMF=1
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VPL_SOURCE=1
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_FONTCONFIG=0  # not on Windows: needs a runtime fonts.conf for no real gain.
                        # libass uses DirectWrite; drawtext uses fontfile= (the Windows norm).
    # whisper ggml-vulkan cross-compiles under mingw with build-env additions handled in the
    # build_whisper block: a dlltool-generated libvulkan-1.dll.a import-lib, a
    # THREAD_POWER_THROTTLING_* compat shim, and SPIRV-Headers on the include path.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    WHISPER_BACKEND="vulkan"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_TYPE_LABEL="Windows (cross-compiled from Linux)"
    ;;

  win-arm64)
    # Windows on ARM — cross-compiled from Linux with LLVM-MinGW, not mingw-w64. Debian's
    # mingw-w64 packages only target x86; the aarch64-w64-mingw32 toolchain comes from
    # llvm-mingw (mstorsjo), which 03_install_packages.sh fetches and puts on PATH.
    # It is clang/LLVM-based, so the driver names are -clang/-clang++ rather than -gcc-win32,
    # and there is no -posix/-win32 split to avoid: llvm-mingw defaults to win32 threads,
    # so no libwinpthread-1.dll runtime dependency either.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    PKGS=(autoconf automake build-essential gperf libtool
          cmake git llvm meson ninja-build pkg-config curl xz-utils
          glslc glslang-tools)
    CROSS_PREFIX="aarch64-w64-mingw32"
    export CC="${CROSS_PREFIX}-clang"
    export CXX="${CROSS_PREFIX}-clang++"
    export AR="${CROSS_PREFIX}-ar"
    export RANLIB="${CROSS_PREFIX}-ranlib"
    export NM="${CROSS_PREFIX}-nm"
    export STRIP="${CROSS_PREFIX}-strip"
    # llvm-mingw does NOT link its runtimes statically by default: a bare link imports
    # libc++.dll and libunwind.dll, which the artifact does not ship, so every binary fails to
    # start on a clean machine. clang accepts the GCC spellings and honours them, so use the
    # same pair win-x64 does — verified by objdump'ing a cross-linked test binary, which drops
    # to system DLLs only once both are passed.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    EXTRA_CFLAGS="-static-libgcc -O2 -pipe"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    # -include system_error: FFmpeg 8.1.x's libavfilter/vsrc_gfxcapture_winrt.cpp uses
    # std::system_error without including <system_error>. libstdc++ pulls it in transitively
    # via <thread>/<mutex>, so win-x64 never notices; libc++ does not, so the llvm-mingw build
    # fails to compile it. Fixed upstream in 9.0.x, which includes the header — this flag is
    # therefore a no-op there and can go when the 8.x line is retired.
    EXTRA_CXXFLAGS="-static-libgcc -static-libstdc++ -O2 -pipe -include system_error"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    EXTRA_LDFLAGS="-static-libgcc -static-libstdc++"
    # -static-libstdc++ above already links libc++ statically. The dep scripts would
    # otherwise also append -lstdc++, which llvm-mingw resolves to libc++.dll.a, and the
    # link then fails on duplicate symbols (std::exception::~exception and friends).
    # shellcheck disable=SC2034  # set here; consumed by the sourced dep scripts
    CXX_RT_LIB=""
    CONFIGURE_FLAGS+=(
      --cross-prefix="${CROSS_PREFIX}-"
      --cc="${CROSS_PREFIX}-clang"
      --cxx="${CROSS_PREFIX}-clang++"
      --pkg-config=pkg-config
      --arch=aarch64 --target-os=mingw32
      --enable-cross-compile
      --enable-d3d11va --enable-dxva2
      --enable-mediafoundation
      --enable-schannel   # OS-native TLS/https (no dependency)
    )
    # Deliberately NOT enabled here, unlike win-x64 — all three are x86-only vendor stacks
    # with no Windows-on-ARM implementation: NVIDIA nvcodec (CUDA/NVENC/NVDEC), AMD AMF, and
    # Intel QSV/libvpl. d3d11va + dxva2 + MediaFoundation are the ARM64 hardware paths.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    HWACCEL_FEATURES="D3D11VA DXVA2 MediaFoundation"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    THREAD_FLAG="--enable-w32threads"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    PIC_FLAG=""  # not applicable to mingw
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_NVIDIA=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_AMF=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VPL_SOURCE=0
    # FFmpeg's Vulkan is header-only + a runtime dlopen of vulkan-1.dll, which Windows-on-ARM
    # ships where a driver exists (Adreno). Keeping it costs nothing when no driver is present.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN=1
    # SVT-AV1 is x86-only (its asm is hand-written for SSE/AVX); AV1 encode is covered by
    # libaom, decode by dav1d. Same exclusion linux-armhf and the Android arm targets take.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_LIBSVTAV1=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_FONTCONFIG=0  # as win-x64: libass uses DirectWrite, drawtext uses fontfile=.
    # Whisper starts on CPU here. The ggml-vulkan path on Windows needs a dlltool-synthesised
    # vulkan-1 import library (see deps/whisper.sh), which is written for the x86 mingw
    # toolchain; wiring it for llvm-mingw/aarch64 is follow-up work, not a launch blocker.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    WHISPER_BACKEND="cpu"
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_TYPE_LABEL="Windows on ARM (cross-compiled from Linux, llvm-mingw)"
    ;;

  *) echo "platform/windows.sh: unexpected RID '${RID}' — add a case arm for it" >&2; exit 1 ;;
esac
