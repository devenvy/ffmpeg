#!/usr/bin/env bash
# iOS SIMULATOR runtime smoke test — the deeper layer beyond ios.sh's structural
# + link checks. Runs on a macOS (Apple-Silicon) CI job with a booted arm64
# simulator: the simulator slice is an arm64 binary, so it runs natively on the
# runner (no slow emulation). Compiles scripts/test/smoke.c against the dynamic
# dylibs and executes it via simctl.
set -uo pipefail
RID="${1:?usage: ios-run.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: ios-run.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
[ "$RID" = "ios-sim-arm64" ] || { echo "ios-run.sh: only the ios-sim-arm64 slice runs on the simulator"; exit 0; }
command -v xcrun >/dev/null 2>&1 || { echo "ios-run.sh: xcrun not found (macOS only)" >&2; exit 2; }
LIBDIR="${DIR}/lib"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CC="$(xcrun --sdk iphonesimulator --find clang)"

info "iOS simulator runtime smoke (${LIBDIR})"
# -rpath LIBDIR so the spawned binary resolves the @rpath-id'd dylibs at runtime; the
# static deps are baked into the dylibs so only the libav* dylibs + Apple frameworks link.
check_smoke_link "${CC} -arch arm64 -mios-simulator-version-min=13.0 -isysroot ${SDK}" \
  "${DIR}/include" /tmp/smoke_ios \
  -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample \
  -Wl,-rpath,"${LIBDIR}" \
  -lc++ -liconv -lz \
  -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
  -framework CoreVideo -framework CoreFoundation -framework CoreServices \
  -framework Security -framework Foundation -framework Metal -framework MetalKit \
  -framework Accelerate -framework QuartzCore || finish

OUT="$(xcrun simctl spawn booted /tmp/smoke_ios 2>&1; echo EXIT=$?)"
echo "$OUT"
if grep -q "smoke: ALL PASS" <<<"$OUT" && grep -q "EXIT=0" <<<"$OUT"; then
  pass "simulator runtime: encode/decode + whisper + TLS pass"
else
  fail "simulator runtime smoke failed"
fi
finish
