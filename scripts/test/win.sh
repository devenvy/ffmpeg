#!/usr/bin/env bash
# Windows test (win-x64 / win-arm64). Structural always (PE arch, import libs, embedded
# config). Functional via Wine when available (the -win32 mingw build has no
# libwinpthread dependency, so nothing extra is needed to run it under Wine).
set -uo pipefail
RID="${1:?usage: win.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: win.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# llvm-readobj reads PE export tables (nm cannot) and ships with the preinstalled LLVM on the
# Windows runner; put it on PATH so check_pe_export can verify DLL exports. No-op elsewhere.
[ -d "/c/Program Files/LLVM/bin" ] && export PATH="/c/Program Files/LLVM/bin:${PATH}"
. "${HERE}/lib.sh"

# `file` reports an ARM64 PE as "PE32+ ... Aarch64", not x86-64, so the arch assertion has to
# follow the RID — otherwise a correct win-arm64 artifact fails as though it were mis-built.
case "$RID" in
  win-x64)   ARCH_RE='PE32\+.*x86-64' ;;
  # `file` labels ARM64 PEs "ARM64" (not "Aarch64", which is the ELF spelling).
  win-arm64) ARCH_RE='PE32\+.*ARM64' ;;
  *) echo "win.sh: unexpected RID $RID" >&2; exit 2 ;;
esac
info "Windows structural checks (${RID}, ${DIR})"

for base in avcodec avformat avutil avfilter swscale swresample; do
  dll="$(ls "${DIR}/${base}"-*.dll 2>/dev/null | head -1)"
  [ -n "$dll" ] || { fail "missing ${base}-*.dll"; continue; }
  check_arch "$dll" "$ARCH_RE"
  check_shared_object "$dll"
  check_pe_export "$dll" "${base}_version"   # verify the DLL's export table (not just the file type)
done
check_arch "${DIR}/ffmpeg.exe" "$ARCH_RE"

# A toolchain runtime DLL we do not ship is fatal at LOAD time, not link time: Windows refuses
# to map the module and every binary that pulls it dies before main. That surfaces only as
# "ffmpeg does not run", with no hint which library was missing -- win-arm64 shipped
# avcodec/avfilter/avformat importing libunwind.dll and libwinpthread-1.dll exactly this way.
# Assert it structurally instead, so the failure names the offending DLL.
audit_runtime_dll_imports() {
  local f imp bad=""
  command -v llvm-readobj >/dev/null 2>&1 || { info "llvm-readobj unavailable — skipping DLL-import audit"; return; }
  for f in "${DIR}"/*.dll "${DIR}"/*.exe; do
    [ -f "$f" ] || continue
    while read -r imp; do
      [ -n "$imp" ] || continue
      [ -f "${DIR}/${imp}" ] && continue          # shipped alongside → fine
      case "$imp" in
        libunwind*|libwinpthread*|libgcc_s*|libstdc++*|libc++*|libssp*|libatomic*|libgomp*)
          bad="${bad} $(basename "$f")→${imp}" ;;
      esac
    done < <(llvm-readobj --coff-imports "$f" 2>/dev/null | grep -oE 'Name: [^ ]+' | awk '{print $2}')
  done
  [ -z "$bad" ] && pass "no unshipped toolchain runtime DLL imports" \
                || fail "unshipped toolchain runtime DLL imports:${bad}"
}
audit_runtime_dll_imports

# MSVC import libraries live in the native tree (packaged into the -dev tarball).
n_lib=$(ls "${DIR}"/lib/*.lib 2>/dev/null | wc -l)
[ "$n_lib" -ge 6 ] && pass "MSVC import libs present (${n_lib} .lib)" || fail "missing .lib import libs (found ${n_lib})"

# Counting the .lib files is not enough: they are well-formed COFF either way, so a
# wrong -m on llvm-dlltool produces x64 import libraries inside the ARM64 dev archive
# and link.exe rejects them only once a consumer tries to build. Assert the machine
# type matches the RID instead.
audit_import_lib_arch() {
  local want f m bad=""
  case "$RID" in
    win-x64)   want="IMAGE_FILE_MACHINE_AMD64" ;;
    win-arm64) want="IMAGE_FILE_MACHINE_ARM64" ;;
    *) return ;;
  esac
  command -v llvm-readobj >/dev/null 2>&1 || { info "llvm-readobj unavailable — skipping import-lib arch audit"; return; }
  for f in "${DIR}"/lib/*.lib; do
    [ -f "$f" ] || continue
    m="$(llvm-readobj --file-headers "$f" 2>/dev/null | grep -m1 -oE 'IMAGE_FILE_MACHINE_[A-Z0-9]+')"
    [ "$m" = "$want" ] || bad="${bad} $(basename "$f")=${m:-unknown}"
  done
  if [ -z "$bad" ]; then
    pass "MSVC import libs are ${want}"
  else
    fail "MSVC import libs have the wrong machine type (want ${want}):${bad}"
  fi
}
audit_import_lib_arch

# The -dev archive (include/ + lib/*.lib) is what MSVC/CMake consumers build against, and
# nothing used to compile or link against it -- mobile ran this check, desktop did not,
# which is how a wrong-architecture import library shipped. Build smoke.c against the
# SHIPPED headers and link it against the SHIPPED import libraries, the way a consumer
# will. clang targeting MSVC drives lld-link and honours the .lib machine type, so an x64
# lib inside an ARM64 archive fails here with "machine type x64 conflicts".
case "$RID" in
  win-x64)   SMOKE_TRIPLE="x86_64-pc-windows-msvc" ;;
  win-arm64) SMOKE_TRIPLE="aarch64-pc-windows-msvc" ;;
  *)         SMOKE_TRIPLE="" ;;
esac
if [ ! -d "${DIR}/include" ]; then
  fail "no include/ in the artifact -- the -dev archive would ship empty"
elif [ -n "${SMOKE_TRIPLE}" ]; then
  SMOKE_LIBS=()
  for _b in avformat avcodec avfilter avutil swscale swresample; do
    [ -f "${DIR}/lib/${_b}.lib" ] && SMOKE_LIBS+=("${DIR}/lib/${_b}.lib")
  done
  if [ "${#SMOKE_LIBS[@]}" -eq 0 ]; then
    fail "no .lib import libraries to link a consumer against"
  else
    # Pre-flight: the msvc triple needs a discoverable Visual Studio installation for the
    # CRT headers. It is present on the GitHub Windows images, but a missing/undiscoverable
    # one is an ENVIRONMENT problem, not a defect in the artifact -- degrade to a skip so it
    # cannot redden the build. audit_import_lib_arch above still runs unconditionally and
    # catches the wrong-architecture case on its own.
    _pf="$(mktemp -d)"; printf 'int main(void){return 0;}
' > "${_pf}/pf.c"
    if clang --target="${SMOKE_TRIPLE}" "${_pf}/pf.c" -o "${_pf}/pf.exe" >/dev/null 2>&1; then
      check_smoke_link "clang --target=${SMOKE_TRIPLE}" "${DIR}/include" "${_pf}/smoke.exe" "${SMOKE_LIBS[@]}"
    else
      info "no usable ${SMOKE_TRIPLE} toolchain (Visual Studio CRT not discoverable) — skipping consumer link test"
    fi
    rm -rf "${_pf}"
  fi
fi

load_config_string "${DIR}"/avcodec-*.dll "${DIR}"/avutil-*.dll
check_config "--enable-whisper" "Whisper ASR filter"
check_config "--enable-mediafoundation" "MediaFoundation"
check_config "--enable-d3d11va" "D3D11VA"
check_tls
check_license_boundary
check_pkgconfig "${DIR}"

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
  fail "functional suite: cannot execute ${RID} target — not on Windows and no Wine (refusing to skip)"
fi

finish
