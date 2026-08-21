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
check_smoke_link "${TCBIN}/aarch64-linux-android28-clang" "${DIR}/include" /tmp/smoke_android \
  -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample || finish

adb wait-for-device
DEST=/data/local/tmp/ffsmoke
adb shell "rm -rf ${DEST}; mkdir -p ${DEST}" >/dev/null
for so in "${LIBDIR}"/*.so; do adb push "$so" "${DEST}/" || echo "PUSH FAILED: $so"; done
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
