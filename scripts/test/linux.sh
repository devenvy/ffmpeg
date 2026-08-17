#!/usr/bin/env bash
# Linux test (linux-x64 / linux-arm64 / linux-armhf / linux-musl-x64).
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
  linux-armhf)              ARCH_RE='ELF 32-bit.*ARM';     TARCH=arm;     QEMU=qemu-arm       ;;
  *) echo "linux.sh: unexpected RID $RID" >&2; exit 2 ;;
esac
info "Linux structural checks (${RID}, ${DIR})"

for base in avcodec avformat avutil avfilter swscale swresample; do
  check_arch "${DIR}/lib${base}.so" "$ARCH_RE"
done
check_core_symbols "${DIR}" so
load_config_string "${DIR}/libavcodec.so" "${DIR}/libavutil.so"
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
check_license_boundary
case "$RID" in
  linux-x64|linux-arm64|linux-musl-x64) check_config "--enable-vaapi" "VAAPI" ;;
esac

# Functional: native if arch matches, else qemu-user if available.
FFMPEG="${DIR}/ffmpeg"; FFPROBE="${DIR}/ffprobe"
export LD_LIBRARY_PATH="${DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ "$(uname -m)" = "$TARCH" ] || { [ "$TARCH" = x86_64 ] && [ "$(uname -m)" = amd64 ]; }; then
  RUNNER=(); info "running functional suite natively"; run_functional
elif [ -n "$QEMU" ] && command -v "$QEMU" >/dev/null 2>&1; then
  RUNNER=("$QEMU" -L /usr/"${TARCH}"-linux-gnu* -E LD_LIBRARY_PATH="${DIR}")
  info "running functional suite under ${QEMU}"; run_functional
else
  skip "functional suite: host is $(uname -m), target ${TARCH}, and ${QEMU:-qemu} not installed (structural only)"
fi

finish
