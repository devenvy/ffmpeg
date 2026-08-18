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
  a="${LIBDIR}/lib${base}.a"
  [ -e "$a" ] || { fail "missing lib${base}.a"; continue; }
  check_arch "$a" 'ar archive|current ar archive'   # static archive
  check_symbol "$a" "${base}_version"
done

# Feature/license from the embedded config (present in the compiled objects).
load_config_string "${LIBDIR}/libavutil.a" "${LIBDIR}/libavcodec.a"
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

# ABI link check for BOTH slices (macOS build job): static-link the smoke program
# against the .a + the system frameworks FFmpeg needs. Linking clean proves the
# archives resolve — a real Tier-2 signal even for the DEVICE slice, which can't be
# executed on CI (the simulator RUN, on the Apple-Silicon runner, is ios-run.sh).
if command -v xcrun >/dev/null 2>&1; then
  case "$RID" in
    ios-sim-arm64) IOS_SDK=iphonesimulator; IOS_MIN=-mios-simulator-version-min=13.0 ;;
    *)             IOS_SDK=iphoneos;        IOS_MIN=-miphoneos-version-min=13.0 ;;
  esac
  SDK="$(xcrun --sdk "${IOS_SDK}" --show-sdk-path 2>/dev/null)"
  CC="$(xcrun --sdk "${IOS_SDK}" --find clang 2>/dev/null)"
  # Static-link the way a real consumer must: -all_load pulls every object. FFmpeg
  # registers codecs/filters via constructors, and clang's machine-outliner emits
  # cross-object helpers (_OUTLINED_FUNCTION_*), so on-demand linking leaves undefined
  # refs. Link ALL our archives — libav* AND their static deps (zimg/whisper/ggml/
  # opus/openssl/...) now staged alongside — plus the Apple frameworks FFmpeg + ggml need.
  ALL_A=(); for a in "${LIBDIR}"/*.a; do [ -e "$a" ] && ALL_A+=("$a"); done
  check_smoke_link "${CC} -arch arm64 ${IOS_MIN} -isysroot ${SDK}" \
    "${DIR}/include" /tmp/smoke_ios \
    -Wl,-all_load "${ALL_A[@]}" \
    -lc++ -liconv -lz \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation -framework CoreServices \
    -framework Security -framework Foundation -framework Metal -framework MetalKit \
    -framework Accelerate -framework QuartzCore
else
  skip "smoke link: Xcode/xcrun not available (run in the macOS build job)"
fi

finish
