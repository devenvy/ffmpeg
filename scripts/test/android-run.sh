#!/usr/bin/env bash
# Android EMULATOR runtime smoke test — the deeper layer beyond android.sh's
# structural + link checks. Runs in a CI job that booted a KVM-accelerated x86_64
# emulator. For android-arm64 the API-35 image's built-in arm64 translation
# (native bridge) is used: it compiles scripts/test/smoke.c against the built
# arm64 .so, pushes the binary + libraries to the device, and executes the
# arm64 program there (translated). For android-x64 the emulator IS x86_64, so
# the x86_64 .so and smoke binary run natively on it — no translation involved.
# Either way this proves the libraries actually load and run on Android —
# encode/decode, whisper, TLS — not just that they are shaped correctly.
# NOTE: this runs a STANDALONE executable via `adb shell`. For android-arm64,
# API-35's native bridge translates it; if a future image only translates
# app-loaded libs, that RID would need wrapping in an instrumented APK instead.
# android-x64 has no such dependency since it never goes through the bridge.
set -uo pipefail
RID="${1:?usage: android-run.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: android-run.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME (needed to cross-compile the smoke test)}"
command -v adb >/dev/null 2>&1 || { echo "android-run.sh: adb not found" >&2; exit 2; }

case "$RID" in
  android-arm64) ABI=arm64-v8a; CLANG_TRIPLE=aarch64-linux-android ;;
  android-x64)   ABI=x86_64;    CLANG_TRIPLE=x86_64-linux-android  ;;
  *) echo "android-run.sh: unexpected RID $RID" >&2; exit 2 ;;
esac
NDK_API=28
LIBDIR="${DIR}/lib/${ABI}"

info "Android emulator runtime smoke (${RID}, ${LIBDIR})"
# NDK host toolchain that exists (linux-aarch64 on an arm64 runner, else linux-x86_64).
_tcroot="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
# NDK ships one host prebuilt dir (linux-x86_64 / linux-aarch64 / darwin-*); pick whichever exists.
_tchost="$(ls "${_tcroot}" 2>/dev/null | head -1)"
TCBIN="${_tcroot}/${_tchost}/bin"
DEST=/data/local/tmp/ffsmoke
# Embed the on-device lib dir as an RPATH (DT_RUNPATH) in the binary. This matters most for
# android-arm64: under the x86_64 emulator's arm64 native bridge, the TRANSLATED linker resolves
# libs by the ELF's own RPATH — it does NOT honor LD_LIBRARY_PATH for a standalone binary (verified:
# libs present in ${DEST}, LD_LIBRARY_PATH set, still "libavformat.so not found"). RPATH points the
# linker straight at the pushed .so. android-x64 runs NATIVELY on the emulator (no bridge, no
# translation), where bionic's own linker behavior applies instead — setting the RPATH here as well
# is harmless and keeps both RIDs on one code path.
check_smoke_link "${TCBIN}/${CLANG_TRIPLE}${NDK_API}-clang" "${DIR}/include" /tmp/smoke_android \
  -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample \
  -Wl,-rpath,"${DEST}" || finish

adb wait-for-device
adb shell "rm -rf ${DEST}; mkdir -p ${DEST}" >/dev/null
# Each .so must locate its SIBLING deps on-device (libavcodec.so -> libc++_shared.so, other libav*).
# For android-arm64, the emulator's arm64 native bridge ignores LD_LIBRARY_PATH; for android-x64
# there is no bridge (the binary runs natively), but either way bionic resolves rpath PER-OBJECT
# (DT_RUNPATH is not transitive), so every lib needs its own rpath to ${DEST}. Patch that in with
# patchelf — but on throwaway COPIES pushed to the device; the downloaded/published artifact is
# never modified (we only add a search path for the test environment).
_patchdir="$(mktemp -d)"
# patchelf is MANDATORY here (the whole fix depends on it): if it can't be made
# available, fail loudly rather than silently pushing unpatched libs that will hit
# the exact "libc++_shared.so not found" transitive-dep error we're solving.
if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y -q patchelf
fi
command -v patchelf >/dev/null 2>&1 || { echo "android-run.sh: patchelf unavailable; cannot set per-lib rpath" >&2; exit 2; }
for so in "${LIBDIR}"/*.so; do
  b="$(basename "$so")"
  cp "$so" "${_patchdir}/${b}"
  patchelf --set-rpath "${DEST}" "${_patchdir}/${b}"
  # Verify the rpath actually took — a no-op patch would reintroduce the transitive failure.
  got="$(patchelf --print-rpath "${_patchdir}/${b}")"
  [ "${got}" = "${DEST}" ] || { echo "android-run.sh: rpath not set on ${b} (got '${got}')" >&2; exit 2; }
  adb push "${_patchdir}/${b}" "${DEST}/" >/dev/null || { echo "PUSH FAILED: ${b}" >&2; exit 2; }
done
echo "patchelf: DT_RUNPATH=${DEST} set + verified on $(find "${LIBDIR}" -maxdepth 1 -name '*.so' | wc -l) libs"
rm -rf "${_patchdir}"
adb push /tmp/smoke_android "${DEST}/smoke"
adb shell "chmod 755 ${DEST}/smoke" >/dev/null
echo "--- on-device contents of ${DEST} (diagnostic) ---"
adb shell "ls -la ${DEST}" || true
# Run the binary — for android-arm64, translated by the API-35 native bridge; for android-x64,
# native to the emulator (no translation). LD_LIBRARY_PATH points the linker at the pushed .so;
# the RPATH baked in above is what actually resolves deps if the bridge ignores LD_LIBRARY_PATH.
OUT="$(adb shell "cd ${DEST} && LD_LIBRARY_PATH=${DEST} ./smoke 2>&1; echo EXIT=\$?")"
echo "$OUT"
if grep -q "smoke: ALL PASS" <<<"$OUT" && grep -q "EXIT=0" <<<"$OUT"; then
  pass "emulator runtime: encode/decode + whisper + TLS pass on-device"
else
  fail "emulator runtime smoke failed on-device"
fi
finish
