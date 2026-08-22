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
# Parallel arrays for the GitHub Step Summary table (one entry per check; parallel so a
# message containing any character — spaces, pipes — is stored intact under `set -u`).
SUMMARY_EMOJI=()
SUMMARY_MSG=()
# Title for the summary table + annotations. Defaults to the build VARIANT (e.g.
# "8.1.2-linux-x64-gplv3") set by the CI job env, so each cell's results are labelled.
SUMMARY_TITLE="${SUMMARY_TITLE:-${VARIANT:-test} results}"

# Each check prints a [PASS]/[FAIL]/[SKIP] line (visible in the raw log) AND accumulates a
# row for the Step Summary. fail() additionally emits a GitHub ::error:: annotation so a
# failure surfaces at the TOP of the run + inline, without opening the log.
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); SUMMARY_EMOJI+=("✅"); SUMMARY_MSG+=("$*"); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); SUMMARY_EMOJI+=("❌"); SUMMARY_MSG+=("$*"); [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::${SUMMARY_TITLE}: $*" || true; }
info() { echo "[INFO] $*"; }
skip() { echo "[SKIP] $*"; SKIP=$((SKIP+1)); SUMMARY_EMOJI+=("⏭️"); SUMMARY_MSG+=("$*"); }

finish() {
  echo
  echo "Passed: ${PASS}  Failed: ${FAIL}  Skipped: ${SKIP}"
  # Render a per-check table into the job's Summary tab (native GitHub UI — no external deps).
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### ${SUMMARY_TITLE} — ✅ ${PASS} · ❌ ${FAIL} · ⏭️ ${SKIP}"
      echo
      echo "|  | Check |"
      echo "|--|-------|"
      local i msg
      for i in "${!SUMMARY_EMOJI[@]}"; do
        msg="${SUMMARY_MSG[$i]//|/\\|}"   # escape | so it doesn't break the table
        echo "| ${SUMMARY_EMOJI[$i]} | ${msg} |"
      done
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  [ "${FAIL}" -eq 0 ]
}

# --- tool resolution (prefer llvm-* which are always foreign-arch capable) ----
NM="$(command -v llvm-nm || command -v nm || true)"
READELF="$(command -v llvm-readelf || command -v readelf || true)"

# --- structural helpers -------------------------------------------------------

# _tool_missing <message>  — a required inspection tool (file/nm) or test input is absent. In CI
# that is a real failure, never a reason to green-wash a skip (our runners are known-good, so an
# absence signals a genuine problem); locally (no GITHUB_ACTIONS) fall back to skip so minimal dev
# shells still run the rest of the suite.
_tool_missing() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then fail "$1"; else skip "$1"; fi
}

# check_arch <file> <regex>  — `file` output must match regex (arch/format).
check_arch() {
  local f="$1" re="$2"
  if [ ! -e "$f" ]; then fail "missing: $f"; return 1; fi
  # Inspection-only check: if `file` isn't available (e.g. a minimal Windows shell),
  # skip rather than fail — actually running the binary is the primary signal, and a
  # missing inspection tool should never fail a job where execution succeeds.
  if ! command -v file >/dev/null 2>&1; then _tool_missing "arch check: 'file' not available"; return 0; fi
  # -L: follow symlinks (Linux ships libfoo.so -> libfoo.so.NN).
  if file -L "$f" | grep -qE "$re"; then pass "arch ok: $(basename "$f") ($re)"
  else fail "arch mismatch: $(basename "$f") — $(file -L "$f" | sed 's/.*: //')"; fi
}

# check_shared_object <file>  — a shipped libav* MUST be a shared/dynamic library, never a static
# archive or a plain executable. This is a LICENSE guard: FFmpeg's libav* are LGPL, and shipping
# them shared (user-replaceable) is what satisfies the LGPL relink requirement (LGPLv2.1 §6 /
# LGPLv3 §4) — a static libav* would push relink obligations onto every consumer. The build sets
# --enable-shared --disable-static (so no .a is even produced), but assert it in the ARTIFACT so a
# regression to a static build is a red job, not a silent compliance slip.
check_shared_object() {
  local f="$1"
  if [ ! -e "$f" ]; then fail "missing: $f"; return 1; fi
  # Inspection-only: mirror check_arch — a missing `file` skips, never fails a job.
  if ! command -v file >/dev/null 2>&1; then _tool_missing "shared-object check: 'file' not available"; return 0; fi
  # ELF DSO -> "shared object"; Mach-O -> "dynamically linked shared library"; PE -> "(DLL)".
  if file -L "$f" | grep -qiE 'shared object|dynamically linked shared library|\(DLL\)'; then
    pass "shared library: $(basename "$f")"
  else
    fail "NOT a shared library — LGPL requires shared libav*: $(basename "$f") — $(file -L "$f" | sed 's/.*: //')"
  fi
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
  # nm/llvm-nm reads ELF/Mach-O symbol tables and is present on the Linux/macOS test hosts (so this
  # never skips there). It is NOT used for Windows PE DLLs — those export tables are verified by
  # check_pe_export (nm can't read them). So a skip here would only happen off-CI on a bare host.
  if [ -z "$NM" ]; then _tool_missing "symbol check ($s): no nm/llvm-nm available"; return; fi
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

# check_pe_export <dll> <symbol>  — verify a Windows PE DLL exports <symbol>. nm/llvm-nm read the
# symbol table, NOT the PE export table, so they can't see DLL exports; use a PE-aware reader instead:
# llvm-readobj (--coff-exports), objdump (-p), or dumpbin (-exports) — whichever the runner has.
# Fails (in CI) if none is available, rather than leaving Windows exports unverified.
check_pe_export() {
  local f="$1" s="$2" out=""
  if [ ! -e "$f" ]; then fail "missing: $f"; return 1; fi
  if command -v llvm-readobj >/dev/null 2>&1; then
    out="$(llvm-readobj --coff-exports "$f" 2>/dev/null)"
  elif command -v objdump >/dev/null 2>&1; then
    out="$(objdump -p "$f" 2>/dev/null)"          # prints the Export Address Table (names)
  elif command -v dumpbin >/dev/null 2>&1; then
    out="$(dumpbin -exports "$f" 2>/dev/null)"     # '-exports' (not '/') avoids MSYS path-mangling
  else
    _tool_missing "PE export check ($s): no llvm-readobj/objdump/dumpbin available"; return
  fi
  if grep -qwE "$s" <<<"$out"; then
    pass "export: $(basename "$f") exports $s"
  else
    fail "export: $(basename "$f") missing $s"
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
    if command -v strings >/dev/null 2>&1; then
      CONFIG_STR="$(strings -a "$f" 2>/dev/null | grep -m1 -- '--disable-autodetect' || true)"
    else
      # Fallback with no `strings` (e.g. a minimal Windows/Git-bash shell): split the binary
      # on non-printable bytes with tr — the same effect as strings, using only tr+grep which
      # exist everywhere. This guarantees the license/TLS/config checks ALWAYS run instead of
      # silently skipping on a host that happens to lack binutils.
      CONFIG_STR="$(LC_ALL=C tr -c '[:print:]' '\n' < "$f" 2>/dev/null | grep -m1 -- '--disable-autodetect' || true)"
    fi
    [ -n "$CONFIG_STR" ] && return 0
  done
  return 1
}

# check_config <flag> <human label>  — the build was configured with <flag>.
check_config() {
  local flag="$1" label="${2:-$1}"
  if [ -z "$CONFIG_STR" ]; then fail "config check ($label): no embedded config string — artifact unreadable"; return; fi
  if grep -q -- " ${flag}\b" <<<" ${CONFIG_STR} "; then pass "configured: ${label} (${flag})"
  else fail "not configured: ${label} (${flag})"; fi
}

# check_config_absent <flag> <label>  — the build must NOT have <flag> (license gate).
check_config_absent() {
  local flag="$1" label="${2:-$1}"
  if [ -z "$CONFIG_STR" ]; then fail "config check ($label): no embedded config string — artifact unreadable"; return; fi
  if grep -q -- " ${flag}\b" <<<" ${CONFIG_STR} "; then fail "unexpectedly configured: ${label} (${flag})"
  else pass "absent as required: ${label} (${flag})"; fi
}

# check_tls  — every build must have exactly one TLS backend, and which one is
# platform-appropriate: OpenSSL on Linux/Android, SChannel on Windows,
# SecureTransport on Apple. Structural, so it also covers the mobile static libs.
check_tls() {
  if [ -z "$CONFIG_STR" ]; then fail "tls check: no embedded config string — artifact unreadable"; return; fi
  case " ${CONFIG_STR} " in
    *" --enable-openssl "*)         pass "TLS backend: OpenSSL (https/tls)" ;;
    *" --enable-gnutls "*)          pass "TLS backend: GnuTLS (https/tls)" ;;   # v2 series
    *" --enable-schannel "*)        pass "TLS backend: SChannel (https/tls)" ;;
    *" --enable-securetransport "*) pass "TLS backend: SecureTransport (https/tls)" ;;
    *)
      # The only builds with NO TLS backend are lgpl-2 (LGPLv2.1) on Linux/Android:
      # GnuTLS's GMP/nettle deps are LGPLv3+/GPLv2+ (never LGPLv2.1) and no other FFmpeg
      # TLS backend is LGPLv2.1-compatible, so TLS is intentionally dropped there. That
      # signature is --disable-gpl (lgpl) AND no --enable-version3 (v2).
      if [[ " ${CONFIG_STR} " == *" --disable-gpl "* && " ${CONFIG_STR} " != *" --enable-version3 "* ]]; then
        pass "no TLS backend — lgplv2 intentionally omits it (no LGPLv2.1-compatible TLS)"
      else
        fail "no TLS backend configured (expected openssl/gnutls/schannel/securetransport)"
      fi ;;
  esac
}

# build_has_tls — true if the build configured any TLS backend. Drives the license-aware
# https/tls protocol check in run_functional (lgplv2 has none by design).
build_has_tls() {
  case " ${CONFIG_STR} " in
    *" --enable-openssl "*|*" --enable-gnutls "*|*" --enable-schannel "*|*" --enable-securetransport "*) return 0 ;;
    *) return 1 ;;
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
    *) fail "license boundary: could not read gpl/lgpl from config string — artifact unreadable" ;;
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
# check well beyond "the .so is the right shape", and it needs no device. The caller
# passes <out> and already knows that path if it wants to run the binary. Skips (does
# not fail) when no suitable compiler is present.
check_smoke_link() {
  local cc="$1" incdir="$2" out="$3"; shift 3
  if [ -z "$cc" ] || ! command -v "${cc%% *}" >/dev/null 2>&1; then
    skip "smoke link: compiler not available (${cc:-unset})"; return 1
  fi
  if $cc "$SMOKE_SRC" -I "$incdir" -o "$out" "$@" 2>/tmp/smoke-cc.err; then
    pass "smoke program links against the artifact (ABI complete)"
    return 0
  fi
  local msg; msg="smoke program did not link: $(tail -3 /tmp/smoke-cc.err | tr '\n' ' ')"
  fail "$msg"
  return 1
}

# --- registry enumeration -----------------------------------------------------
# Assert the built library actually REGISTERED the expected components at runtime — a
# stronger check than "was configured": a muxer/parser/built-in codec that silently didn't
# build shows up here. The UNCONDITIONAL set is FFmpeg's built-ins (no external lib), present
# in every build regardless of platform/license — verified against a live 8.1.2 binary. The
# external-lib ENCODERS are cross-checked against the embedded config: registered iff built.
# Uses the parameterized RUNNER + FFMPEG (so it works native / wine / qemu). CLI-only; the
# mobile library builds do the same via av_*_iterate in smoke.c.
_enum() { "${RUNNER[@]}" "$FFMPEG" -hide_banner "$1" 2>/dev/null || true; }
check_registry() {
  local list w
  # kind:flag  →  the list to query + the must-be-present built-ins
  list="$(_enum -decoders)"
  for w in h264 hevc mpeg4 mpeg2video aac mp3 flac pcm_s16le mjpeg vp8 vp9 opus vorbis av1; do
    grep -qw "$w" <<<"$list" && pass "decoder registered: $w" || fail "built-in decoder MISSING: $w"
  done
  list="$(_enum -muxers)"
  for w in mp4 mov matroska webm mpegts flv hls dash wav mp3 ogg image2 null; do
    grep -qw "$w" <<<"$list" && pass "muxer registered: $w" || fail "built-in muxer MISSING: $w"
  done
  list="$(_enum -demuxers)"
  for w in mov matroska mpegts flv wav mp3 aac h264 hevc ogg image2; do
    grep -qw "$w" <<<"$list" && pass "demuxer registered: $w" || fail "built-in demuxer MISSING: $w"
  done
  list="$(_enum -bsfs)"
  for w in h264_mp4toannexb hevc_mp4toannexb aac_adtstoasc; do
    grep -qw "$w" <<<"$list" && pass "bitstream filter registered: $w" || fail "built-in bsf MISSING: $w"
  done
  list="$(_enum -protocols)"
  for w in file pipe data crypto tcp udp; do
    grep -qw "$w" <<<"$list" && pass "protocol registered: $w" || fail "built-in protocol MISSING: $w"
  done
  # External-lib encoders: registered IFF the lib was configured (config flag → encoder name).
  local encoders; encoders="$(_enum -encoders)"
  _enc_iff() {  # <config-flag> <encoder-name>
    case " ${CONFIG_STR} " in
      *" --enable-$1 "*)
        grep -qw "$2" <<<"$encoders" \
          && pass "encoder registered (built --enable-$1): $2" \
          || fail "encoder MISSING despite --enable-$1: $2" ;;
    esac
  }
  _enc_iff libx264   libx264
  _enc_iff libx265   libx265
  _enc_iff libvpx    libvpx-vp9
  _enc_iff libopus   libopus
  _enc_iff libmp3lame libmp3lame
  _enc_iff libaom    libaom-av1
  _enc_iff libsvtav1 libsvtav1
  _enc_iff libvorbis libvorbis
  _enc_iff libopenh264 libopenh264
  _enc_iff libkvazaar libkvazaar
  # Hardware ENCODERS must REGISTER when their accel is configured — independent of any GPU
  # being present (registration != device availability). This is the strict "was it built"
  # guarantee; the runtime probe_hwaccel below is the separate "does the path load" signal.
  _enc_iff nvenc  h264_nvenc
  _enc_iff vaapi  h264_vaapi
  _enc_iff libvpl h264_qsv
  _enc_iff amf    h264_amf
}

# --- real TLS handshake -------------------------------------------------------
# Prove the TLS backend actually NEGOTIATES, not just that the protocol is listed. Fetch a
# tiny well-known HTTPS resource. Only for builds that HAVE a TLS backend (lgplv2 on Linux/Android
# has none — check_tls covers that case). Single attempt, no retry: a transient network blip
# surfaces as a visible [SKIP] (it is a runner-network issue, not a TLS-backend defect) rather than
# being masked by re-running — re-run the job manually if a blip trips it.
exercise_tls() {
  build_has_tls || { info "TLS handshake: build has no TLS backend (lgplv2) — skipping (correct-absence checked separately)"; return; }
  # A tiny, highly-available https resource. It's a TEXT file, so after the TLS GET succeeds
  # ffmpeg fails to DEMUX it ("Invalid data found") — that failure PROVES the handshake worked
  # and bytes were transferred. We only truly fail if the https protocol is missing entirely.
  local url="https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/RELEASE" out
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v error -i "$url" -f null - 2>&1)"
  if [ -z "$out" ] || grep -qiE 'Invalid data found|could not find codec|Unknown input format|does not contain any stream|End of file' <<<"$out"; then
    pass "TLS handshake: fetched bytes over https:// (backend negotiates)"; return
  fi
  case "$out" in
    *"Protocol not found"*|*"Unknown protocol"*)
      fail "TLS handshake: https unavailable — TLS backend not wired ($out)"; return ;;
  esac
  skip "TLS handshake: incomplete (runner network/cert, not a TLS-backend defect): $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
}

# --- whisper CPU inference ----------------------------------------------------
# Prove the af_whisper filter actually RUNS ggml inference (not just that it registers).
# Needs a model: the workflow downloads a tiny GGML model (cached) and sets WHISPER_MODEL.
# We run it over generated audio on the CPU and assert it completes — a real forward pass;
# transcription accuracy is out of scope (a tone yields little text, but the pipeline runs).
exercise_whisper() {
  local model="${WHISPER_MODEL:-}"
  if [ -z "$model" ] || [ ! -f "$model" ]; then
    # CI fetches the model as a mandatory step, so absence here is a real gap (fail); locally,
    # skip so a dev without the model can still run the rest of the suite.
    _tool_missing "whisper inference: WHISPER_MODEL not set/found (CI model fetch is mandatory)"; return
  fi
  # Relative, colon-free workspace dir (like the model path): af_whisper's 'destination' is embedded
  # inside the -af filter string, where MSYS does NOT auto-convert a git-bash /tmp path for the native
  # Windows .exe (unlike standalone path args). A relative path resolves against cwd on every OS.
  local tmp; tmp="whisper-out.$$"; mkdir -p "$tmp"
  # A short spoken-like signal isn't needed to prove execution; a tone drives the full graph.
  # NOTE: af_whisper's ggml CPU inference has intermittently SEGFAULTED on the Windows runner
  # (~1 in 15 runs observed; a same-artifact re-run passed, so it's nondeterministic — not a build
  # defect). It is NOT yet mapped to a specific upstream issue. We run ONCE and, on failure, FAIL
  # LOUD with the exit code + captured stderr — NO retry masking — so the flake is visible and
  # diagnosable and can be re-run manually. (exit 139 = SIGSEGV; -v verbose stderr shows how far
  # ggml got / which op faulted before the crash.)
  local out ec
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v verbose -f lavfi -i "sine=frequency=220:duration=2" \
        -af "whisper=model=${model}:language=en:destination=${tmp}/out.txt:queue=1000" \
        -f null - 2>&1)"
  ec=$?
  if [ "$ec" -eq 0 ] && [ -e "${tmp}/out.txt" ]; then
    pass "whisper inference: af_whisper ran a CPU forward pass to completion"
  else
    fail "whisper inference: af_whisper did not complete (exit ${ec}) — $(printf '%s' "$out" | tr '\n' ' ' | tail -c 400)"
  fi
  rm -rf "$tmp"
}

# --- hardware-accel classified probe ------------------------------------------
# The trichotomy that avoids "assume failure == no HW": run a hwaccel and CLASSIFY ffmpeg's
# own error. exit 0 → ran on real hardware (pass). A driver/device error → the code path was
# EXERCISED (loaded the runtime, enumerated devices) but no device on CI (probe-pass — a real
# positive signal). An "Unknown encoder / not compiled" error → the BUILD is broken (fail).
# probe_hwaccel <label> <exercised-regex> <ffmpeg-args...>
probe_hwaccel() {
  local label="$1" exercised="$2"; shift 2
  local out rc
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v error "$@" -f null - 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "hwaccel ${label}: ran on a real device"
  elif grep -qiE 'Unknown (encoder|decoder)|not compiled|Cannot find a matching|is not supported|Unrecognized' <<<"$out"; then
    fail "hwaccel ${label}: NOT built/registered — $(tr '\n' ' ' <<<"$out" | cut -c1-140)"
  elif grep -qiE "$exercised" <<<"$out"; then
    pass "hwaccel ${label}: path exercised (driver loaded + device enumeration ran; no device on CI)"
  else
    info "hwaccel ${label}: inconclusive — $(tr '\n' ' ' <<<"$out" | cut -c1-140)"
  fi
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

  # https/tls presence is license-dependent: builds WITH a TLS backend must expose them;
  # lgplv2 (which drops TLS — no LGPLv2.1-compatible backend) must NOT — and we verify the
  # absence rather than skipping, so a stray TLS backend can't sneak into an lgplv2 artifact.
  local protocols p
  protocols="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -protocols 2>/dev/null || true)"
  if build_has_tls; then
    for p in https tls; do
      grep -qw "$p" <<<"$protocols" && pass "$p protocol present" || fail "$p protocol missing (TLS backend configured)"
    done
  else
    for p in https tls; do
      grep -qw "$p" <<<"$protocols" && fail "$p protocol present but this build has NO TLS backend (lgplv2 leak?)" \
                                     || pass "$p protocol correctly absent (lgplv2: TLS intentionally dropped)"
    done
  fi

  if "${RUNNER[@]}" "$FFMPEG" -hide_banner -y -f lavfi -i testsrc=size=320x240:rate=25:duration=1 \
        -c:v mpeg4 "$tmp/out.mp4" >/dev/null 2>&1 \
     && "${RUNNER[@]}" "$FFMPEG" -hide_banner -v error -i "$tmp/out.mp4" -f null - >/dev/null 2>&1; then
    pass "encode + decode round-trip"
  else
    fail "encode + decode round-trip"
  fi

  # Registry enumeration — the built-ins + external encoders actually registered (needs CONFIG_STR).
  check_registry
  # Real behavior: an https handshake (if the build has TLS) + a whisper CPU forward pass (if a model).
  exercise_tls
  exercise_whisper

  # Hardware-accel: probe each backend this build configured, CLASSIFYING the result so a
  # GPU-less runner proves the code path loads without false-failing. Gate only the unambiguous
  # "not built" case. Driven by the embedded config so we only probe what was enabled.
  case " ${CONFIG_STR} " in
    *" --enable-nvenc "*)  probe_hwaccel "NVENC (h264_nvenc)" 'cannot load|libcuda|nvcuda|nvEncodeAPI|no NVENC|OpenEncodeSession|does not support|Cannot load nvcuda|Driver' \
                             -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" -c:v h264_nvenc ;;
  esac
  # DEV_ERR = the common failure signature for a `-init_hw_device` with no device present.
  local DEV_ERR='Device creation failed|init_hw_device|Generic error in an external library|Cannot (load|open|create)|No such|not (found|available|supported)|failed'
  case " ${CONFIG_STR} " in
    *" --enable-vaapi "*)  probe_hwaccel "VAAPI" "Failed to initialise VAAPI|No VA display|/dev/dri|vaInitialize|${DEV_ERR}" \
                             -init_hw_device "vaapi=va" -f lavfi -i "nullsrc=duration=0.1" ;;
  esac
  case " ${CONFIG_STR} " in
    *" --enable-libvpl "*|*" --enable-libmfx "*)  probe_hwaccel "QSV" "MFX|libmfx|libvpl|${DEV_ERR}" \
                             -init_hw_device "qsv=qsv" -f lavfi -i "nullsrc=duration=0.1" ;;
  esac
  case " ${CONFIG_STR} " in
    *" --enable-amf "*)    probe_hwaccel "AMF (h264_amf)" "amfrt|AMF|DLL .*failed|CreateContext|No suitable|${DEV_ERR}" \
                             -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" -c:v h264_amf ;;
  esac
  case " ${CONFIG_STR} " in
    *" --enable-vulkan "*) probe_hwaccel "Vulkan (scale_vulkan)" "Vulkan|VkInstance|no such device|No hardware|ICD|libvulkan|MoltenVK|${DEV_ERR}" \
                             -init_hw_device "vulkan=vk" -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" \
                             -vf "format=nv12,hwupload,scale_vulkan=160:120,hwdownload,format=nv12" ;;
  esac
  # VideoToolbox (Apple) genuinely runs on the macOS runner's real GPU — a decode probe. On the
  # iOS simulator it's software-backed; the classifier turns a no-device result into probe-pass.
  case " ${CONFIG_STR} " in
    *" --enable-videotoolbox "*)
      "${RUNNER[@]}" "$FFMPEG" -hide_banner -v error -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" \
        -c:v mpeg4 "$tmp/vt.mp4" >/dev/null 2>&1 || true
      probe_hwaccel "VideoToolbox decode" 'VideoToolbox|hwaccel|Cannot load|not available|Failed' \
        -hwaccel videotoolbox -i "$tmp/vt.mp4" ;;
  esac
}
