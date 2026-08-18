#!/usr/bin/env bash
# Shared test helpers for the per-platform test scripts in this directory.
# Sourced by test/<platform>.sh. Provides:
#   - pass/fail/info/skip counters + finish
#   - structural checks (arch, soname, exported symbols, embedded-config flags,
#     feature strings) that work from ANY host against ANY target's libraries
#   - a functional suite parameterized by a launcher (native / wine / qemu)
#
# The structural checks lean on two facts: `nm -D` / `readelf` / `strings` read
# foreign-arch ELF fine, and FFmpeg embeds its full ./configure command line as a
# rodata string in the libraries — so feature/license coverage is verifiable
# without executing anything.

PASS=0 FAIL=0 SKIP=0
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "[INFO] $*"; }
skip() { echo "[SKIP] $*"; SKIP=$((SKIP+1)); }

finish() {
  echo
  echo "Passed: ${PASS}  Failed: ${FAIL}  Skipped: ${SKIP}"
  [ "${FAIL}" -eq 0 ]
}

# --- tool resolution (prefer llvm-* which are always foreign-arch capable) ----
NM="$(command -v llvm-nm || command -v nm || true)"
READELF="$(command -v llvm-readelf || command -v readelf || true)"

# --- structural helpers -------------------------------------------------------

# check_arch <file> <regex>  — `file` output must match regex (arch/format).
check_arch() {
  local f="$1" re="$2"
  if [ ! -e "$f" ]; then fail "missing: $f"; return 1; fi
  # Inspection-only check: if `file` isn't available (e.g. a minimal Windows shell),
  # skip rather than fail — actually running the binary is the primary signal, and a
  # missing inspection tool should never fail a job where execution succeeds.
  if ! command -v file >/dev/null 2>&1; then skip "arch check: 'file' not available"; return 0; fi
  # -L: follow symlinks (Linux ships libfoo.so -> libfoo.so.NN).
  if file -L "$f" | grep -qE "$re"; then pass "arch ok: $(basename "$f") ($re)"
  else fail "arch mismatch: $(basename "$f") — $(file -L "$f" | sed 's/.*: //')"; fi
}

# check_soname_unversioned <sharedlib>  — SONAME must have no .NN suffix (Android).
check_soname_unversioned() {
  local f="$1" sn
  sn="$(${READELF} -d "$f" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"
  case "$sn" in
    *.so) pass "unversioned soname: $(basename "$f") -> $sn" ;;
    "")   fail "no SONAME: $(basename "$f")" ;;
    *)    fail "versioned soname: $(basename "$f") -> $sn" ;;
  esac
}

# check_symbol <lib> <symbol>  — symbol is exported (works on foreign-arch libs).
# Capture nm output to a variable before grepping: piping nm straight into
# `grep -qw` lets grep close the pipe on first match, nm takes SIGPIPE, and
# `set -o pipefail` then reports a false failure (flaky, depending on where the
# symbol lands in nm's output). Same pattern as run_functional below.
check_symbol() {
  local f="$1" s="$2" syms
  # Inspection-only: if no nm/llvm-nm is present, skip rather than fail — execution
  # (Tier 2) is the real signal; a missing inspection tool must not fail the job.
  if [ -z "$NM" ]; then skip "symbol check ($s): no nm/llvm-nm available"; return; fi
  # Match an optional leading underscore: Mach-O (macOS/iOS) prefixes symbols with '_'
  # (e.g. _avcodec_version), ELF does not. A pattern beats `grep -w`, whose word
  # boundary treats the leading '_' as part of the token and misses it.
  local re="(^|[^A-Za-z0-9_])_?${s}([^A-Za-z0-9_]|\$)"
  syms="$(${NM} -D --defined-only "$f" 2>/dev/null)"
  grep -qE "$re" <<<"$syms" || syms="$(${NM} "$f" 2>/dev/null)"
  if grep -qE "$re" <<<"$syms"; then
    pass "symbol: $(basename "$f") exports $s"
  else
    fail "symbol: $(basename "$f") missing $s"
  fi
}

# The libav* version symbols every good build must export.
check_core_symbols() {
  local dir="$1" ext="$2"
  local -A map=( [avcodec]=avcodec_version [avformat]=avformat_version
                 [avutil]=avutil_version [avfilter]=avfilter_version
                 [swscale]=swscale_version [swresample]=swresample_version )
  local base
  for base in "${!map[@]}"; do
    local lib
    lib="$(ls "${dir}"/lib${base}.${ext}* 2>/dev/null | head -1)"
    [ -n "$lib" ] && check_symbol "$lib" "${map[$base]}"
  done
}

# CONFIG_STR is the embedded ./configure line, harvested from any lib once.
CONFIG_STR=""
load_config_string() {
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    # Anchor on an FFmpeg-distinctive flag so we don't grab a bundled dependency's
    # own embedded configure line (which lacks the FFmpeg --enable-* flags).
    CONFIG_STR="$(strings -a "$f" 2>/dev/null | grep -m1 -- '--disable-autodetect' || true)"
    [ -n "$CONFIG_STR" ] && return 0
  done
  return 1
}

# check_config <flag> <human label>  — the build was configured with <flag>.
check_config() {
  local flag="$1" label="${2:-$1}"
  if [ -z "$CONFIG_STR" ]; then skip "config check ($label): no embedded config string"; return; fi
  if grep -q -- " ${flag}\b" <<<" ${CONFIG_STR} "; then pass "configured: ${label} (${flag})"
  else fail "not configured: ${label} (${flag})"; fi
}

# check_config_absent <flag> <label>  — the build must NOT have <flag> (license gate).
check_config_absent() {
  local flag="$1" label="${2:-$1}"
  if [ -z "$CONFIG_STR" ]; then skip "config check ($label): no embedded config string"; return; fi
  if grep -q -- " ${flag}\b" <<<" ${CONFIG_STR} "; then fail "unexpectedly configured: ${label} (${flag})"
  else pass "absent as required: ${label} (${flag})"; fi
}

# check_tls  — every build must have exactly one TLS backend, and which one is
# platform-appropriate: OpenSSL on Linux/Android, SChannel on Windows,
# SecureTransport on Apple. Structural, so it also covers the mobile static libs.
check_tls() {
  if [ -z "$CONFIG_STR" ]; then skip "tls check: no embedded config string"; return; fi
  case " ${CONFIG_STR} " in
    *" --enable-openssl "*)         pass "TLS backend: OpenSSL (https/tls)" ;;
    *" --enable-schannel "*)        pass "TLS backend: SChannel (https/tls)" ;;
    *" --enable-securetransport "*) pass "TLS backend: SecureTransport (https/tls)" ;;
    *) fail "no TLS backend configured (expected openssl/schannel/securetransport)" ;;
  esac
}

# License-appropriate encoder expectations, driven by the embedded config string.
check_license_boundary() {
  local lean="${1:-}"   # a lean slice (e.g. ios-sim) intentionally omits x264/x265
  case " ${CONFIG_STR} " in
    *" --enable-gpl "*)
      info "GPL build (per embedded config)"
      if [ -n "$lean" ]; then
        info "lean slice: x264/x265 intentionally omitted — skipping GPL-encoder presence check"
      else
        check_config "--enable-libx264" "x264 (H.264 SW encoder)"
        check_config "--enable-libx265" "x265 (H.265 SW encoder)"
      fi ;;
    *" --disable-gpl "*)
      info "LGPL build (per embedded config)"
      check_config_absent "--enable-gpl" "GPL"
      check_config_absent "--enable-libx264" "x264 (GPL)"
      check_config_absent "--enable-libx265" "x265 (GPL)" ;;
    *) skip "license boundary: could not read gpl/lgpl from config string" ;;
  esac
}

# --- mobile smoke program (link + optional runtime) ---------------------------
# scripts/test/smoke.c exercises the real runtime (encode+decode roundtrip,
# whisper filter, https/tls) using only the public libav* API, so it works on
# targets that ship no ffmpeg executable (Android .so, iOS .a).
SMOKE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/smoke.c"

# check_smoke_link <cc> <include-dir> <out> <link-args...>
# Compile+link the smoke program against the artifact. Linking with no undefined
# references proves the libraries' ABI is complete and self-consistent — a real
# check well beyond "the .so is the right shape", and it needs no device. On
# success SMOKE_BIN holds the path, so a caller with an emulator/simulator can
# then run it. Skips (does not fail) when no suitable compiler is present.
SMOKE_BIN=""
check_smoke_link() {
  local cc="$1" incdir="$2" out="$3"; shift 3
  if [ -z "$cc" ] || ! command -v "${cc%% *}" >/dev/null 2>&1; then
    skip "smoke link: compiler not available (${cc:-unset})"; return 1
  fi
  if $cc "$SMOKE_SRC" -I "$incdir" -o "$out" "$@" 2>/tmp/smoke-cc.err; then
    pass "smoke program links against the artifact (ABI complete)"
    SMOKE_BIN="$out"; return 0
  fi
  fail "smoke program did not link: $(tail -3 /tmp/smoke-cc.err | tr '\n' ' ')"
  return 1
}

# --- functional suite (parameterized launcher) --------------------------------
# Set RUNNER=() for native, (wine) for Windows, (qemu-aarch64 -L <sysroot>) etc.
# Requires FFMPEG and FFPROBE (paths) and RUNNER to be set by the caller.
run_functional() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  if "${RUNNER[@]}" "$FFMPEG" -hide_banner -version >/dev/null 2>&1; then
    pass "ffmpeg runs ($("${RUNNER[@]}" "$FFMPEG" -hide_banner -version 2>/dev/null | head -1))"
  else
    fail "ffmpeg does not run under [${RUNNER[*]:-native}] — skipping remaining functional checks"
    return
  fi
  "${RUNNER[@]}" "$FFPROBE" -hide_banner -version >/dev/null 2>&1 \
    && pass "ffprobe runs" || fail "ffprobe does not run"

  # Capture enumerations to variables first: piping straight into `grep -q`
  # makes grep close the pipe on first match, ffmpeg takes SIGPIPE, and
  # `set -o pipefail` then reports a false failure. Capturing avoids the pipe.
  local filters decoders d
  filters="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -filters 2>/dev/null || true)"
  grep -qw whisper <<<"$filters" \
    && pass "whisper filter listed" || fail "whisper filter not listed"

  decoders="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -decoders 2>/dev/null || true)"
  for d in h264 hevc; do
    grep -qw "$d" <<<"$decoders" && pass "$d decoder present" || fail "$d decoder missing"
  done

  local protocols p
  protocols="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -protocols 2>/dev/null || true)"
  for p in https tls; do
    grep -qw "$p" <<<"$protocols" && pass "$p protocol present" || fail "$p protocol missing"
  done

  if "${RUNNER[@]}" "$FFMPEG" -hide_banner -y -f lavfi -i testsrc=size=320x240:rate=25:duration=1 \
        -c:v mpeg4 "$tmp/out.mp4" >/dev/null 2>&1 \
     && "${RUNNER[@]}" "$FFMPEG" -hide_banner -v error -i "$tmp/out.mp4" -f null - >/dev/null 2>&1; then
    pass "encode + decode round-trip"
  else
    fail "encode + decode round-trip"
  fi
}
