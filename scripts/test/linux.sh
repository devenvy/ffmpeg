#!/usr/bin/env bash
# Linux test (linux-x64 / linux-arm64 / linux-armhf / linux-musl-x64 / linux-musl-arm64).
# Structural always; functional when the host can execute the target — natively
# (arch match) or via qemu-user (cross arch, if installed).
set -uo pipefail
RID="${1:?usage: linux.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: linux.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"

case "$RID" in
  linux-x64|linux-musl-x64) ARCH_RE='ELF 64-bit.*x86-64'; TARCH=x86_64; QEMU=""              ;;
  linux-arm64)              ARCH_RE='ELF 64-bit.*aarch64'; TARCH=aarch64; QEMU=qemu-aarch64  ;;
  # QEMU="" like linux-musl-x64: the qemu branch below invokes `qemu -L /usr/${TARCH}-linux-gnu*`, a
  # GLIBC sysroot, which is wrong for a musl binary. It runs natively on the arm64 runner; if it ever
  # cannot, the `else` branch fails loudly rather than silently downgrading to structural-only.
  linux-musl-arm64)         ARCH_RE='ELF 64-bit.*aarch64'; TARCH=aarch64; QEMU=""              ;;
  linux-armhf)              ARCH_RE='ELF 32-bit.*ARM';     TARCH=arm;     QEMU=qemu-arm       ;;
  *) echo "linux.sh: unexpected RID $RID" >&2; exit 2 ;;
esac
info "Linux structural checks (${RID}, ${DIR})"

for base in avcodec avformat avutil avfilter swscale swresample; do
  check_arch "${DIR}/lib${base}.so" "$ARCH_RE"
  check_shared_object "${DIR}/lib${base}.so"
done
check_core_symbols "${DIR}" so
load_config_string "${DIR}/libavcodec.so" "${DIR}/libavutil.so"
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
check_license_boundary
check_pkgconfig "${DIR}"

# The -dev archive (include/ + the shared libraries) is what downstream consumers
# actually build against, and until now nothing on desktop ever compiled or linked
# against it -- mobile ran this check, linux/macOS/Windows did not. That is the gap
# that let a wrong-architecture import library ship on win-arm64. Compile and link
# smoke.c against the SHIPPED headers and libraries, exactly as a consumer would.
# linux-armhf is 32-bit ARM but its test job runs on an x86-64 host under qemu-user, so the
# native cc CANNOT link against the ARM32 artifact -- it needs the cross-compiler that job
# installs alongside qemu. Every other linux RID tests on a matching host.
case "${RID}" in
  linux-armhf) SMOKE_CC="arm-linux-gnueabihf-gcc" ;;
  *)           SMOKE_CC="${CC:-cc}" ;;
esac
if [ ! -d "${DIR}/include" ]; then
  fail "no include/ in the artifact -- the -dev archive would ship empty"
elif ! command -v "${SMOKE_CC}" >/dev/null 2>&1; then
  fail "smoke link: ${SMOKE_CC} not installed on this runner (the -dev archive would go untested)"
else
  check_smoke_link "${SMOKE_CC}" "${DIR}/include" "$(mktemp -d)/smoke" \
    -L "${DIR}" -lavformat -lavcodec -lavfilter -lavutil -lswscale -lswresample
fi
case "$RID" in
  linux-x64|linux-arm64|linux-musl-x64|linux-musl-arm64) check_config "--enable-vaapi" "VAAPI" ;;
esac

# Functional: native if arch matches, else qemu-user if available.
FFMPEG="${DIR}/ffmpeg"; FFPROBE="${DIR}/ffprobe"; export FFMPEG FFPROBE  # consumed by run_functional (sourced lib.sh)
export LD_LIBRARY_PATH="${DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ "$(uname -m)" = "$TARCH" ] || { [ "$TARCH" = x86_64 ] && [ "$(uname -m)" = amd64 ]; }; then
  RUNNER=(); info "running functional suite natively"; run_functional
elif [ -n "$QEMU" ] && command -v "$QEMU" >/dev/null 2>&1; then
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  RUNNER=("$QEMU" -L /usr/"${TARCH}"-linux-gnu* -E LD_LIBRARY_PATH="${DIR}")
  info "running functional suite under ${QEMU}"; run_functional
else
  # Never silently downgrade to a structural-only PASS — a cross target we cannot execute is
  # UNVETTED. 32-bit armhf has no native hosted silicon (arm64 runners are Neoverse-N1, no
  # AArch32), so it must run under qemu-user; if that is unavailable, FAIL rather than skip.
  fail "functional suite: cannot execute ${TARCH} target — ${QEMU:-qemu} not available (refusing to skip)"
fi

finish
