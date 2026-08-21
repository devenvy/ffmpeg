#!/usr/bin/env bash
# macOS (osx-x64 / osx-arm64) test. Runs natively on the macOS runner when the
# slice matches the host arch; structural otherwise.
set -uo pipefail
RID="${1:?usage: macos.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: macos.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"

case "$RID" in
  osx-x64)   ARCH_RE='Mach-O.*x86_64'; TARCH=x86_64 ;;
  osx-arm64) ARCH_RE='Mach-O.*arm64';  TARCH=arm64  ;;
  *) echo "macos.sh: unexpected RID $RID" >&2; exit 2 ;;
esac
info "macOS structural checks (${RID}, ${DIR})"

for base in avcodec avformat avutil avfilter swscale swresample; do
  lib="$(ls "${DIR}"/lib${base}.*.dylib "${DIR}"/lib${base}.dylib 2>/dev/null | head -1)"
  if [ -n "$lib" ]; then check_arch "$lib" "$ARCH_RE"; check_shared_object "$lib"; else fail "missing lib${base} dylib"; fi
done
check_core_symbols "${DIR}" dylib
load_config_string "${DIR}/ffmpeg" "$(ls "${DIR}"/libavutil.*.dylib 2>/dev/null | head -1)"
check_config "--enable-videotoolbox" "VideoToolbox"
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
check_license_boundary

FFMPEG="${DIR}/ffmpeg"; FFPROBE="${DIR}/ffprobe"; export FFMPEG FFPROBE  # consumed by run_functional (sourced lib.sh)
export DYLD_LIBRARY_PATH="${DIR}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = "$TARCH" ]; then
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  RUNNER=(); info "running functional suite natively"; run_functional
else
  skip "functional suite: host is $(uname -s)/$(uname -m), target ${TARCH} (structural only)"
fi

finish
