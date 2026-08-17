#!/usr/bin/env bash
# Android EMULATOR runtime smoke test — the deeper layer beyond android.sh's
# structural + link checks. Runs in a CI job that has booted an arm64-v8a
# emulator: it compiles scripts/test/smoke.c against the built .so, pushes the
# binary + libraries to the device, and executes them there. This proves the
# libraries actually load and run on Android — encode/decode, whisper, TLS — not
# just that they are shaped correctly.
set -uo pipefail
DIR="${1:?usage: android-run.sh <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME (needed to cross-compile the smoke test)}"
command -v adb >/dev/null 2>&1 || { echo "android-run.sh: adb not found" >&2; exit 2; }
LIBDIR="${DIR}/lib/arm64-v8a"

info "Android emulator runtime smoke (${LIBDIR})"
TCBIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
check_smoke_link "${TCBIN}/aarch64-linux-android28-clang" "${DIR}/include" /tmp/smoke_android \
  -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample || finish

adb wait-for-device
DEST=/data/local/tmp/ffsmoke
adb shell "rm -rf ${DEST}; mkdir -p ${DEST}" >/dev/null
for so in "${LIBDIR}"/*.so; do adb push "$so" "${DEST}/" >/dev/null; done
adb push /tmp/smoke_android "${DEST}/smoke" >/dev/null
adb shell "chmod 755 ${DEST}/smoke" >/dev/null
OUT="$(adb shell "cd ${DEST} && LD_LIBRARY_PATH=${DEST} ./smoke; echo EXIT=\$?")"
echo "$OUT"
if grep -q "smoke: ALL PASS" <<<"$OUT" && grep -q "EXIT=0" <<<"$OUT"; then
  pass "emulator runtime: encode/decode + whisper + TLS pass on-device"
else
  fail "emulator runtime smoke failed on-device"
fi
finish
