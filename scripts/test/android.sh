#!/usr/bin/env bash
# Android (arm64) test — structural checks + an ABI link check. The artifact is
# aarch64 shared libraries (no executables), so we verify they are shaped and
# configured correctly, then (when the NDK is present, i.e. the build job)
# compile the smoke program against them to prove the ABI is complete. Actually
# EXECUTING on a device is scripts/test/android-run.sh (the emulator job).
set -uo pipefail
DIR="${1:?usage: android.sh <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ELF inspection (readelf/nm) must read the Linux ELF .so on ANY test host — but macOS has no GNU
# readelf and its nm reads Mach-O, not ELF. Put the NDK's llvm-readelf/llvm-nm on PATH first (they
# read ELF regardless of host); lib.sh resolves READELF/NM from PATH at source time, so this precedes it.
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  _r="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"; _h="$(ls "$_r" 2>/dev/null | head -1)"
  [ -n "${_h}" ] && [ -d "${_r}/${_h}/bin" ] && export PATH="${_r}/${_h}/bin:${PATH}"
fi
. "${HERE}/lib.sh"

LIBDIR="${DIR}/lib/arm64-v8a"
info "Android arm64 structural checks (${LIBDIR})"

for base in avcodec avformat avutil avfilter swscale swresample avdevice; do
  lib="${LIBDIR}/lib${base}.so"
  [ -e "$lib" ] || { [ "$base" = avdevice ] && continue; fail "missing lib${base}.so"; continue; }
  check_arch "$lib" 'ELF 64-bit.*ARM aarch64'
  check_soname_unversioned "$lib"
done

check_core_symbols "${LIBDIR}" so

# Android hardware decode must link the NDK media libs.
if ${READELF} -d "${LIBDIR}/libavcodec.so" 2>/dev/null | grep -q 'libmediandk.so'; then
  pass "libavcodec links libmediandk.so (MediaCodec)"
else
  fail "libavcodec does not link libmediandk.so"
fi

# The C++ codec libs (OpenH264/libass/whisper) make libavcodec/libavfilter depend
# on libc++_shared.so at runtime. It is not part of Android, so the artifact must
# bundle it — otherwise a consuming app crashes on load. (Found by the on-device
# smoke test; guarded here so it cannot silently regress.)
if [ -f "${LIBDIR}/libc++_shared.so" ]; then
  pass "libc++_shared.so bundled (C++ runtime dependency)"
else
  fail "libc++_shared.so NOT bundled — apps will fail to load libavcodec.so"
fi

load_config_string "${LIBDIR}/libavcodec.so" "${LIBDIR}/libavutil.so"
check_config "--enable-mediacodec" "MediaCodec"
check_config "--enable-jni" "JNI"
check_config "--enable-decoder=h264_mediacodec" "h264 MediaCodec decoder"
check_config "--enable-whisper" "Whisper ASR filter"
# Vulkan is v3-only (Vulkan-Headers are Apache-2.0, dropped from the v2 series). The
# embedded --enable-version3 flag distinguishes the series.
case " ${CONFIG_STR} " in
  *" --enable-version3 "*) check_config "--enable-vulkan" "Vulkan" ;;
  *)                       check_config_absent "--enable-vulkan" "Vulkan (v2: dropped)" ;;
esac
check_tls
check_license_boundary

# Link artifact must ship headers.
[ -f "${DIR}/include/libavcodec/avcodec.h" ] \
  && pass "headers present (include/libavcodec/avcodec.h)" \
  || fail "missing include/libavcodec/avcodec.h"

# Runtime-ABI link check with the NDK (present in the android build job): compile
# the smoke program against the .so — proves the libraries have no undefined
# symbols and a consuming app can link them. The emulator RUN is android-run.sh.
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  # NDK host toolchain that exists (linux-aarch64 on an arm64 runner, else linux-x86_64).
  _tcroot="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
  # NDK ships one host prebuilt dir (linux-x86_64 / linux-aarch64 / darwin-*); pick whichever exists.
  _tchost="$(ls "${_tcroot}" 2>/dev/null | head -1)"
  TCBIN="${_tcroot}/${_tchost}/bin"
  check_smoke_link "${TCBIN}/aarch64-linux-android28-clang" "${DIR}/include" /tmp/smoke_android \
    -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample
else
  skip "smoke link: ANDROID_NDK_HOME not set (run in the android build job)"
fi

finish
