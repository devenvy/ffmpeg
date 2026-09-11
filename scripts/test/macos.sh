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
# Vulkan is v3-only (MoltenVK + Vulkan-Headers are Apache-2.0, dropped from the v2 series).
# Structural, so it belongs here rather than inside the native-execution branch below, where
# a non-native invocation would skip it entirely.
case " ${CONFIG_STR} " in
  *" --enable-vulkan "*) : ;;
  *) check_config_absent "--enable-vulkan" "Vulkan (v2: dropped)" ;;
esac
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
check_license_boundary
# The deployment target is portability metadata, not a build detail: without an explicit
# floor the binary inherits the CI runner OS, and the published osx-arm64 artifact shipped
# requiring macOS 26. Assert the floor the platform block promises.
MACOS_MIN_EXPECTED="11.0"
check_macho_minos "${DIR}/ffmpeg" "${MACOS_MIN_EXPECTED}"
for _dylib in "${DIR}"/libav*.dylib "${DIR}"/libsw*.dylib; do
  [ -e "${_dylib}" ] || continue
  check_macho_minos "${_dylib}" "${MACOS_MIN_EXPECTED}"
done
check_pkgconfig "${DIR}"

# Same reasoning as linux.sh: the -dev archive is otherwise entirely unverified.
if [ -d "${DIR}/include" ]; then
  check_smoke_link "clang" "${DIR}/include" "$(mktemp -d)/smoke"     -L "${DIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample
else
  fail "no include/ in the artifact — the -dev archive would ship empty"
fi

FFMPEG="${DIR}/ffmpeg"; FFPROBE="${DIR}/ffprobe"; export FFMPEG FFPROBE  # consumed by run_functional (sourced lib.sh)
export DYLD_LIBRARY_PATH="${DIR}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = "$TARCH" ]; then
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  RUNNER=(); info "running functional suite natively"; run_functional
  # Where we ship Vulkan (v3) it must actually work: the runner has Metal, so a failure here
  # is a real defect, not a missing-device artefact. This half stays inside the native branch
  # because assert_vulkan_device EXECUTES ffmpeg, so it is only meaningful on a native run.
  # The structural half (a v2 cell must not carry --enable-vulkan) is asserted above, where
  # it runs regardless of host.
  case " ${CONFIG_STR} " in
    *" --enable-vulkan "*) assert_vulkan_device ;;
  esac
else
  # Never green-wash an unexecuted target: in CI macOS runs on a native Darwin runner, so reaching
  # here means a real capability gap (wrong host / arch mismatch), which must fail rather than skip.
  fail "functional suite: cannot execute ${TARCH} target on $(uname -s)/$(uname -m) (refusing to skip)"
fi

finish
