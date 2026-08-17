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
check_license_boundary

[ -f "${DIR}/include/libavcodec/avcodec.h" ] \
  && pass "headers present (include/libavcodec/avcodec.h)" \
  || fail "missing include/libavcodec/avcodec.h"

# Runtime-ABI link check for the runnable simulator slice (macOS build job):
# static-link the smoke program against the .a + the system frameworks FFmpeg
# needs. Linking clean proves the archives resolve. The simulator RUN (arm64
# binary on an Apple-Silicon runner) is ios-run.sh.
if [ "$RID" = "ios-sim-arm64" ] && command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
  CC="$(xcrun --sdk iphonesimulator --find clang 2>/dev/null)"
  check_smoke_link "${CC} -arch arm64 -mios-simulator-version-min=13.0 -isysroot ${SDK}" \
    "${DIR}/include" /tmp/smoke_ios \
    -L "${LIBDIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample \
    -lc++ -liconv -lz \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation -framework Security
else
  skip "smoke link: iOS simulator SDK not available (run in the macOS build job)"
fi

finish
