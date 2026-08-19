#!/usr/bin/env bash
# iOS (ios-arm64 device / ios-sim-arm64 simulator) test — structural checks plus,
# for the runnable simulator slice, an ABI link check. The artifact is static .a
# libraries (Mach-O); we verify arch, core symbols, and features/headers, then
# (simulator slice, macOS build job) link the smoke program against the archives
# to prove they resolve. EXECUTING it on the simulator is scripts/test/ios-run.sh.
set -uo pipefail
RID="${1:?usage: ios.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: ios.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
info "iOS structural checks (${RID}, ${DIR})"

LIBDIR="${DIR}/lib"
for base in avcodec avformat avutil avfilter swscale swresample; do
  dylib="${LIBDIR}/lib${base}.dylib"
  [ -e "$dylib" ] || { fail "missing lib${base}.dylib"; continue; }
  check_arch "$dylib" 'Mach-O 64-bit dynamically linked shared library arm64'
  check_symbol "$dylib" "${base}_version"
done

# Feature/license from the embedded config (present in the compiled dylibs).
load_config_string "${LIBDIR}/libavutil.dylib" "${LIBDIR}/libavcodec.dylib"
check_config "--enable-videotoolbox" "VideoToolbox"
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
# ios-sim is the lean slice (04_select_license drops x264/x265 on the simulator);
# the device slice keeps full GPL parity.
LEAN=""; [ "$RID" = "ios-sim-arm64" ] && LEAN=lean
check_license_boundary "$LEAN"

[ -f "${DIR}/include/libavcodec/avcodec.h" ] \
  && pass "headers present (include/libavcodec/avcodec.h)" \
  || fail "missing include/libavcodec/avcodec.h"

# ABI link check for BOTH slices (macOS build job): DYNAMICALLY link the smoke program
# against the dylibs. iOS is dynamic now, so this resolves cleanly at build time — no
# -all_load static whack-a-mole — which is why this is a GATING check again (SMOKE_SOFT
# gone). A real Tier-2 signal even for the DEVICE slice, which can't be executed on CI
# (the simulator RUN, on the Apple-Silicon runner, is ios-run.sh).
if command -v xcrun >/dev/null 2>&1; then
  case "$RID" in
    ios-sim-arm64) IOS_SDK=iphonesimulator; IOS_MIN=-mios-simulator-version-min=13.0 ;;
    *)             IOS_SDK=iphoneos;        IOS_MIN=-miphoneos-version-min=13.0 ;;
  esac
  SDK="$(xcrun --sdk "${IOS_SDK}" --show-sdk-path 2>/dev/null)"
  CC="$(xcrun --sdk "${IOS_SDK}" --find clang 2>/dev/null)"
  # Dynamic link: the static deps (whisper/ggml, opus, kvazaar, …) are baked INTO the
  # dylibs, so we link only the libav* dylibs plus the Apple frameworks/system libs they
  # load. No -all_load, no dep archives. -rpath points at LIBDIR so the link's own binary
  # could resolve them (a device app resolves via the embedded frameworks dir + @rpath).
  check_smoke_link "${CC} -arch arm64 ${IOS_MIN} -isysroot ${SDK}" \
    "${DIR}/include" /tmp/smoke_ios \
    -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample \
    -Wl,-rpath,"${LIBDIR}" \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation -framework CoreServices \
    -framework Security -framework Foundation -framework Metal -framework MetalKit \
    -framework Accelerate -framework QuartzCore \
    -lc++ -liconv -lz
else
  skip "smoke link: Xcode/xcrun not available (run in the macOS build job)"
fi

finish
