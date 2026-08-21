#!/usr/bin/env bash
# Windows (win-x64) test. Structural always (PE arch, import libs, embedded
# config). Functional via Wine when available (the -win32 mingw build has no
# libwinpthread dependency, so nothing extra is needed to run it under Wine).
set -uo pipefail
DIR="${1:?usage: win.sh <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
info "Windows x64 structural checks (${DIR})"

for dll in "${DIR}"/avcodec-*.dll "${DIR}"/avformat-*.dll "${DIR}"/avutil-*.dll \
           "${DIR}"/avfilter-*.dll "${DIR}"/swscale-*.dll "${DIR}"/swresample-*.dll; do
  check_arch "$dll" 'PE32\+.*x86-64'
  check_shared_object "$dll"
done
check_arch "${DIR}/ffmpeg.exe" 'PE32\+.*x86-64'

# MSVC import libraries live in the native tree (packaged into the -dev tarball).
n_lib=$(ls "${DIR}"/lib/*.lib 2>/dev/null | wc -l)
[ "$n_lib" -ge 6 ] && pass "MSVC import libs present (${n_lib} .lib)" || fail "missing .lib import libs (found ${n_lib})"

load_config_string "${DIR}"/avcodec-*.dll "${DIR}"/avutil-*.dll
check_config "--enable-whisper" "Whisper ASR filter"
check_config "--enable-mediafoundation" "MediaFoundation"
check_config "--enable-d3d11va" "D3D11VA"
check_tls
check_license_boundary

FFMPEG="$(ls "${DIR}"/ffmpeg.exe 2>/dev/null)"; FFPROBE="$(ls "${DIR}"/ffprobe.exe 2>/dev/null)"; export FFMPEG FFPROBE  # consumed by run_functional (sourced lib.sh)
if [[ "${OS:-}" == "Windows_NT" ]]; then
  # On a real Windows runner the .exe runs natively — no Wine, empty RUNNER.
  RUNNER=(); info "running functional suite natively on Windows"; run_functional
elif command -v wine >/dev/null 2>&1; then
  export WINEDEBUG=-all WINEPREFIX="${WINEPREFIX:-$(mktemp -d)}"
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  RUNNER=(wine); info "running functional suite under Wine"; run_functional
else
  # Never green-wash an unexecuted target: in CI win-x64 runs on a native Windows runner, so
  # reaching here (not Windows, no Wine) is a real capability gap that must fail, not skip.
  fail "functional suite: cannot execute win-x64 target — not on Windows and no Wine (refusing to skip)"
fi

finish
