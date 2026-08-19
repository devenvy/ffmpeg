#!/usr/bin/env bash
set -euo pipefail
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
BUILD_OPENSSL=0        # OpenSSL 3.x TLS (v3 series, Linux/Android)
BUILD_GNUTLS=0         # GnuTLS TLS (v2 series replacement for OpenSSL; set by 04_select_license)
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

# Cross-compile host triple, derived ONCE from the RID and consumed by the autotools
# dependency scripts (which no longer each repeat this same case). Empty = native build.
# Named CROSS_HOST (not HOST) so it can't collide with an environment HOST var, which
# would silently inject --host into native builds.
CROSS_HOST=""
case "${RID}" in
  win-x64)                 CROSS_HOST=x86_64-w64-mingw32 ;;
  linux-armhf)             CROSS_HOST=arm-linux-gnueabihf ;;
  android-arm64)           CROSS_HOST=aarch64-linux-android ;;
  ios-arm64|ios-sim-arm64) CROSS_HOST=aarch64-apple-darwin ;;
esac

# Platform-specific toolchain, hwaccel flags, and BUILD_* switches. The per-RID detail
# lives in scripts/platform/<family>.sh, sourced here by RID family — keeps this file
# small and makes adding a new RID/platform a localized change.
case "${RID}" in
  linux-*)     PLATFORM=linux ;;
  win-*)       PLATFORM=windows ;;
  osx-*|ios-*) PLATFORM=apple ;;
  android-*)   PLATFORM=android ;;
  *) echo "Error: unsupported BUILD_RID '${RID}'" >&2; exit 1 ;;
esac
. "${ROOT_DIR}/scripts/platform/${PLATFORM}.sh"

# Linux and Android have no OS TLS backend FFmpeg can use, so they build OpenSSL
# (Apache-2.0 — GPL/LGPL-compatible, no --enable-nonfree needed). Windows/Apple
# already got their native backend above.
case "${RID}" in
  linux-*|android-*) BUILD_OPENSSL=1 ;;
esac
