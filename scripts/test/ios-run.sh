#!/usr/bin/env bash
# iOS SIMULATOR runtime smoke test — the deeper layer beyond ios.sh's structural
# + link checks. Runs on a macOS (Apple-Silicon) CI job with a booted arm64
# simulator: the simulator slice is an arm64 binary, so it runs natively on the
# runner (no slow emulation). Compiles scripts/test/smoke.c against the dynamic
# frameworks and executes it via simctl.
set -uo pipefail
RID="${1:?usage: ios-run.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: ios-run.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
[ "$RID" = "ios-sim-arm64" ] || { echo "ios-run.sh: only the ios-sim-arm64 slice runs on the simulator"; exit 0; }
command -v xcrun >/dev/null 2>&1 || { echo "ios-run.sh: xcrun not found (macOS only)" >&2; exit 2; }
FWDIR="${DIR}/frameworks"
# ABSOLUTE frameworks path: the baked -rpath must resolve at RUNTIME under `simctl spawn`, whose
# process CWD is NOT this dir — a relative rpath fails ("Library not loaded: @rpath/…"). The
# simulator process runs on the host, so an absolute host path is reachable. (A real app instead
# embeds the frameworks and uses @executable_path/Frameworks; this is the test-harness equivalent.)
FWABS="$(cd "${FWDIR}" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CC="$(xcrun --sdk iphonesimulator --find clang)"

info "iOS simulator runtime smoke (${FWABS})"
# -F resolves the framework links + smoke.c's <libavcodec/…> imports; the ABSOLUTE -rpath lets the
# spawned binary resolve the @rpath-id'd frameworks at runtime. Static deps are baked into each
# framework binary, so only the libav* frameworks + Apple system frameworks link.
check_smoke_link "${CC} -arch arm64 -mios-simulator-version-min=13.0 -isysroot ${SDK}" \
  "${FWABS}" /tmp/smoke_ios \
  -F "${FWABS}" \
  -framework libavformat -framework libavcodec -framework libavfilter \
  -framework libavutil -framework libswscale -framework libswresample \
  -Wl,-rpath,"${FWABS}" \
  -lc++ -liconv -lz \
  -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
  -framework CoreVideo -framework CoreFoundation -framework CoreServices \
  -framework Security -framework Foundation -framework Metal -framework MetalKit \
  -framework Accelerate -framework QuartzCore -framework IOSurface -framework UIKit || finish

# If this cell advertises Vulkan, REQUIRE the probe in smoke.c to produce a real device.
# iOS links MoltenVK statically, and MoltenVK runs over Metal, which an Apple-Silicon
# simulator host always has — so "Vulkan enabled but no device" is a genuine defect here, not
# a property of the runner. This is the only check that proves the static-MoltenVK path works
# at runtime rather than merely being compiled in. v2 cells have no Vulkan and stay lenient.
# simctl only forwards variables prefixed SIMCTL_CHILD_ into the spawned process.
load_config_string "${FWABS}/libavutil.framework/libavutil" "${FWABS}/libavcodec.framework/libavcodec"
# Deliberately NOT an array: macOS ships bash 3.2, where expanding an empty array under
# `set -u` is an "unbound variable" error, which would fail the whole job rather than the check.
REQUIRE_VULKAN=0
case " ${CONFIG_STR} " in
  *" --enable-vulkan "*|*" --enable-vulkan-static "*)
    REQUIRE_VULKAN=1
    info "Vulkan enabled in this cell — requiring the probe to create a real device" ;;
  *) info "no Vulkan in this cell — Vulkan probe stays advisory" ;;
esac

if [ "${REQUIRE_VULKAN}" = 1 ]; then
  OUT="$(SIMCTL_CHILD_SMOKE_REQUIRE_VULKAN=1 xcrun simctl spawn booted /tmp/smoke_ios 2>&1; echo EXIT=$?)"
else
  OUT="$(xcrun simctl spawn booted /tmp/smoke_ios 2>&1; echo EXIT=$?)"
fi
echo "$OUT"
if grep -q "smoke: ALL PASS" <<<"$OUT" && grep -q "EXIT=0" <<<"$OUT"; then
  if [ "${REQUIRE_VULKAN}" = 1 ]; then
    pass "simulator runtime: encode/decode + whisper + TLS + a real Vulkan device"
  else
    pass "simulator runtime: encode/decode + whisper + TLS pass"
  fi
else
  fail "simulator runtime smoke failed"
fi
finish
