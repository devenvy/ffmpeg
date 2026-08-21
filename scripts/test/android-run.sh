#!/usr/bin/env bash
# Android EMULATOR runtime smoke test — the deeper layer beyond android.sh's
# structural + link checks. Runs in a CI job that booted a KVM-accelerated x86_64
# emulator whose API-35 image has built-in arm64 translation (native bridge): it
# compiles scripts/test/smoke.c against the built arm64 .so, pushes the binary +
# libraries to the device, and executes the arm64 program there (translated). This
# proves the libraries actually load and run on Android — encode/decode, whisper,
# TLS — not just that they are shaped correctly.
# NOTE: this runs a STANDALONE arm64 executable via `adb shell`. API-35's native
# bridge translates it; if a future image only translates app-loaded libs, this
# would need wrapping in an instrumented APK instead.
set -uo pipefail
DIR="${1:?usage: android-run.sh <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME (needed to cross-compile the smoke test)}"
command -v adb >/dev/null 2>&1 || { echo "android-run.sh: adb not found" >&2; exit 2; }
LIBDIR="${DIR}/lib/arm64-v8a"

info "Android emulator runtime smoke (${LIBDIR})"
# NDK host toolchain that exists (linux-aarch64 on an arm64 runner, else linux-x86_64).
_tcroot="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt"
# NDK ships one host prebuilt dir (linux-x86_64 / linux-aarch64 / darwin-*); pick whichever exists.
_tchost="$(ls "${_tcroot}" 2>/dev/null | head -1)"
TCBIN="${_tcroot}/${_tchost}/bin"
DEST=/data/local/tmp/ffsmoke
# Embed the on-device lib dir as an RPATH (DT_RUNPATH) in the binary. Under the x86_64 emulator's
# arm64 native bridge, the translated linker resolves libs by the ELF's own RPATH — it does NOT
# honor LD_LIBRARY_PATH for a standalone binary (verified: libs present in ${DEST}, LD_LIBRARY_PATH
# set, still "libavformat.so not found"). RPATH points the linker straight at the pushed .so.
check_smoke_link "${TCBIN}/aarch64-linux-android28-clang" "${DIR}/include" /tmp/smoke_android \
  -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample \
  -Wl,-rpath,"${DEST}" || finish

adb wait-for-device
adb shell "rm -rf ${DEST}; mkdir -p ${DEST}" >/dev/null
# Each .so must locate its SIBLING deps on-device (libavcodec.so -> libc++_shared.so, other libav*).
# The emulator's arm64 native bridge ignores LD_LIBRARY_PATH, and bionic resolves rpath PER-OBJECT
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
# Run the arm64 binary (translated by the API-35 native bridge). LD_LIBRARY_PATH points the linker
# at the pushed .so; if the bridge ignores it, fall back to setting it inline in the exec env.
OUT="$(adb shell "cd ${DEST} && LD_LIBRARY_PATH=${DEST} ./smoke 2>&1; echo EXIT=\$?")"
echo "$OUT"
if grep -q "smoke: ALL PASS" <<<"$OUT" && grep -q "EXIT=0" <<<"$OUT"; then
  pass "emulator runtime: encode/decode + whisper + TLS pass on-device"
else
  fail "emulator runtime smoke failed on-device"
fi
finish
