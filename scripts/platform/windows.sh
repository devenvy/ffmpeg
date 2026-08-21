#!/usr/bin/env bash
set -euo pipefail
# Windows platform config (mingw-w64 cross).
# SOURCED by steps/02_configure.sh based on the RID family; shares its environment.
case "${RID}" in
  win-x64)
    # Windows — cross-compiled from Linux with mingw-w64 (win32 threading)
    # Explicitly use the -win32 toolchain variant to avoid a runtime
    # dependency on libwinpthread-1.dll (the -posix variant pulls it in).
    # mingw-w64-tools -> gendef, llvm -> llvm-dlltool: together these turn each
    # built DLL into an MSVC-consumable COFF import library (see artifact staging).
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    PKGS=(cmake git mingw-w64 mingw-w64-tools llvm meson nasm ninja-build pkg-config curl xz-utils yasm
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

esac
