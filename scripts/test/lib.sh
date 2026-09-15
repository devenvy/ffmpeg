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
# STRINGS follows NM/READELF: prefer the LLVM tool, which reads ELF, Mach-O and PE regardless of
# host. check_claimed_capabilities_static reads cross-built libraries, so the host's own binutils
# may not understand the target format -- today android-* tests land on ubuntu and ios/catalyst on
# macOS, so plain strings would do, but that is a property of the runner matrix, not of the check.
# android.sh already puts the NDK's llvm-* on PATH ahead of this for the same reason.
STRINGS="$(command -v llvm-strings || command -v strings || true)"

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

# --- platform floors ---------------------------------------------------------
# These assert the PORTABILITY metadata already baked into the binary. Every other check
# answers "does it work on the runner"; these answer "will it work anywhere else", which
# is where the published artifacts actually failed: osx-arm64 shipped requiring macOS 26
# because it inherited the CI runner's OS, and the Android .so were 4 KB-aligned and so
# unloadable on 16 KB-page devices.

# check_macho_minos <file> <max-allowed>  — Mach-O deployment target must not exceed the
# floor we promise. A binary built on a newer runner silently raises this.
check_macho_minos() {
  local f="$1" want="$2" got
  [ -e "$f" ] || { fail "missing: $f"; return 1; }
  command -v llvm-objdump >/dev/null 2>&1 || command -v otool >/dev/null 2>&1     || { _tool_missing "minos check: no otool/llvm-objdump"; return 0; }
  if command -v otool >/dev/null 2>&1; then
    got="$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')"
  else
    got="$(llvm-objdump --macho --all-headers "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')"
  fi
  [ -n "$got" ] || { _tool_missing "minos check: no LC_BUILD_VERSION in $(basename "$f")"; return 0; }
  # numeric compare on major.minor
  if [ "$(printf '%s
%s
' "$got" "$want" | sort -V | head -1)" = "$got" ]; then
    pass "deployment target ok: $(basename "$f") minos ${got} (<= ${want})"
  else
    fail "deployment target too high: $(basename "$f") minos ${got} > ${want} — it would not launch on ${want}"
  fi
}

# check_elf_page_align <file> <bytes>  — LOAD segments must be aligned to at least <bytes>.
# Android 15+ devices may use 16 KB pages and refuse a 4 KB-aligned library.
check_elf_page_align() {
  local f="$1" want="$2" worst
  [ -e "$f" ] || { fail "missing: $f"; return 1; }
  command -v readelf >/dev/null 2>&1 || { _tool_missing "page-align check: no readelf"; return 0; }
  worst="$(readelf -lW "$f" 2>/dev/null | awk '$1=="LOAD"{print $NF}' | sort | head -1)"
  [ -n "$worst" ] || { _tool_missing "page-align check: no LOAD segments in $(basename "$f")"; return 0; }
  if [ "$(( worst ))" -ge "$(( want ))" ] 2>/dev/null; then
    pass "page alignment ok: $(basename "$f") $(printf '0x%x' "$worst") (>= $(printf '0x%x' "$want"))"
  else
    fail "page alignment too small: $(basename "$f") $(printf '0x%x' "$worst") < $(printf '0x%x' "$want") — unloadable on 16 KB-page devices"
  fi
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
  # --defined-only on BOTH passes. The fallback used to drop it, so a plain `nm` listing --
  # which includes UNDEFINED symbols -- would satisfy the match. That turns "this library
  # provides X" into "this library mentions X", and a capability that was never built but is
  # merely referenced would pass. The second pass exists only because some objects need the
  # non-dynamic table (-D misses static archives), not to relax what counts as present.
  syms="$(${NM} -D --defined-only "$f" 2>/dev/null)"
  grep -qE "$re" <<<"$syms" || syms="$(${NM} --defined-only "$f" 2>/dev/null)"
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
  # Whole-token match, not \b: in a configure string the flags are space-separated, and \b
  # matches at a "-" boundary -- so " --enable-vulkan\b" was satisfied by --enable-vulkan-static,
  # meaning a check for the bare flag passed on a build that only had the variant. Match
  # space-delimited tokens, exactly how check_claimed_capabilities reads them.
  case " ${CONFIG_STR} " in
    *" ${flag} "*) pass "configured: ${label} (${flag})" ;;
    *)             fail "not configured: ${label} (${flag})" ;;
  esac
}

# check_config_absent <flag> <label>  — the build must NOT have <flag> (license gate).
check_config_absent() {
  local flag="$1" label="${2:-$1}"
  if [ -z "$CONFIG_STR" ]; then fail "config check ($label): no embedded config string — artifact unreadable"; return; fi
  # Same whole-token rule as check_config, and it matters more here: this is the licence gate.
  case " ${CONFIG_STR} " in
    *" ${flag} "*) fail "unexpectedly configured: ${label} (${flag})" ;;
    *)             pass "absent as required: ${label} (${flag})" ;;
  esac
}

# check_tls  — every build must have exactly one TLS backend, and which one is
# platform-appropriate: OpenSSL on Linux/Android, SChannel on Windows,
# SecureTransport on macOS/iOS. Mac Catalyst is the exception among Apple targets --
# SecureTransport is unavailable on macabi, so it takes the Linux/Android ladder
# (v3 OpenSSL / gplv2 GnuTLS / lgplv2 none). Structural, so it also covers the mobile
# static libs.
check_tls() {
  if [ -z "$CONFIG_STR" ]; then fail "tls check: no embedded config string - artifact unreadable"; return; fi
  # COUNT the backends rather than stopping at the first `case` arm that matches. The function
  # claims "exactly one TLS backend", but a first-match case cannot tell one from two -- a build
  # that somehow configured both OpenSSL and GnuTLS would have reported the first and passed.
  local found=() b
  for b in openssl gnutls schannel securetransport; do
    case " ${CONFIG_STR} " in *" --enable-${b} "*) found+=("${b}") ;; esac
  done
  case "${#found[@]}" in
    1) pass "TLS backend: ${found[0]} (https/tls)" ;;
    0)
      # The only builds with NO TLS backend are lgpl-2 (LGPLv2.1) on Linux/Android/Catalyst:
      # GnuTLS's GMP/nettle deps are LGPLv3+/GPLv2+ (never LGPLv2.1) and no other FFmpeg TLS
      # backend is LGPLv2.1-compatible, so TLS is intentionally dropped there. That signature is
      # --disable-gpl (lgpl) AND no --enable-version3 (v2).
      if [[ " ${CONFIG_STR} " == *" --disable-gpl "* && " ${CONFIG_STR} " != *" --enable-version3 "* ]]; then
        pass "no TLS backend - lgplv2 intentionally omits it (no LGPLv2.1-compatible TLS)"
      else
        fail "no TLS backend configured (expected openssl/gnutls/schannel/securetransport)"
      fi ;;
    *) fail "more than one TLS backend configured (${found[*]}) - exactly one is expected" ;;
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
# _assert_encoder_absent <artifact-dir> <encoder-name> <label>
# Reads libavcodec directly, so it works on every RID including the cross-built slices with no
# CLI. The encoder's name string exists in libavcodec only when that encoder was compiled in;
# the configure string lives in libavUTIL, so it cannot produce a false positive here.
_assert_encoder_absent() {
  local d="$1" name="$2" label="$3" lib
  [ -n "${d}" ] || { info "license boundary: no artifact dir passed - registry check skipped"; return; }
  [ -n "${STRINGS:-}" ] || { fail "license boundary: no strings(1) - cannot verify ${label} is absent"; return; }
  lib="$(_find_lib "${d}" avcodec)"
  [ -n "${lib}" ] || { fail "license boundary: libavcodec not found under ${d}"; return; }
  if "${STRINGS}" -a -n 2 "${lib}" | grep -qx -- "${name}"; then
    fail "LICENSE VIOLATION: ${label} is compiled into libavcodec of an LGPL build"
  else
    pass "license boundary: ${label} absent from the artifact's registry, not just its config"
  fi
}

check_license_boundary() {
  local lean="${2:-}"   # a lean slice (e.g. ios-sim) intentionally omits x264/x265
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
      check_config_absent "--enable-libx265" "x265 (GPL)"
      # ...and prove it against the ARTIFACT, not just its configure line. Everything above reads
      # the embedded string, which records what we ASKED for. A stale DEPS_DIR carrying a previous
      # GPL cell's libx264.a would produce an LGPL-configured build with a GPL encoder inside it,
      # and every check above would still pass. This is the one check where being wrong is a
      # licensing problem, not a capability one.
      _assert_encoder_absent "${1:-}" libx264 "x264 (GPL)"
      _assert_encoder_absent "${1:-}" libx265 "x265 (GPL)" ;;
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
# --- pkg-config -------------------------------------------------------------
# The .pc files are how most Linux/macOS consumers integrate, and they were missing from
# every -dev archive. They also cannot be shipped verbatim: FFmpeg bakes the BUILD prefix
# in, so a copied .pc points at paths that do not exist on the consumer's machine. Assert
# both that they are present AND that their prefix was made relocatable, since a wrong
# prefix fails only later, in someone else's build.
check_pkgconfig() {
  local dir="$1" pc n bad=""
  if [ ! -d "${dir}/lib/pkgconfig" ]; then
    fail "no lib/pkgconfig in the artifact — the -dev archive would ship no pkg-config files"
    return
  fi
  n="$(find "${dir}/lib/pkgconfig" -name '*.pc' 2>/dev/null | wc -l)"
  [ "${n}" -ge 6 ] && pass "pkg-config files present (${n} .pc)" || fail "only ${n} .pc files (expected >= 6)"
  for pc in "${dir}"/lib/pkgconfig/*.pc; do
    [ -e "${pc}" ] || continue
    grep -q '^prefix=\${pcfiledir}' "${pc}" || bad="${bad} $(basename "${pc}")"
  done
  if [ -z "${bad}" ]; then
    pass "pkg-config prefixes are relocatable (\${pcfiledir})"
  else
    fail "pkg-config files keep a build-machine prefix (not relocatable):${bad}"
  fi
}

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
# Word-splits $1 on purpose: most rows query a single option (-filters, -encoders), but some
# capabilities have no enumerable component and are only visible through `-h full` (libsoxr
# registers no filter or codec -- it adds a RESAMPLER ENGINE, so the only honest CLI evidence is
# the "select SoX Resampler" line). Every value comes from capabilities.tsv, which is in-repo.
# Memoised: check_claimed_capabilities calls this once PER ROW, and the rows share a handful of
# options (-encoders, -decoders, -filters, ...). Without caching, every row added to
# capabilities.tsv costs another ffmpeg process, which makes broadening coverage quietly
# expensive. With it, the cost is one invocation per distinct option no matter how many rows use
# it, so the table can grow freely.
# shellcheck disable=SC2086  # deliberate word splitting; see above
_enum_raw() { "${RUNNER[@]}" "$FFMPEG" -hide_banner $1 2>/dev/null || true; }
_enum() {
  local key; key="_enumcache_$(tr -c '[:alnum:]' '_' <<<"$1")"
  if [ -z "${!key+x}" ]; then printf -v "${key}" '%s' "$(_enum_raw "$1")"; fi
  printf '%s' "${!key}"
}
# check_claimed_capabilities — assert the binary actually HAS what its configure line CLAIMS.
#
# This is the counterpart to check_config. check_config proves we asked; this proves we got it.
# The distinction is not academic: FFmpeg 8.1.2 shipped with every Vulkan filter missing on all
# 15 RIDs, and 9.0.1 on four of them, because configure silently disabled spirv_compiler when
# the host glslc was too old. --enable-vulkan was present in the configure line the whole time,
# so every check we had reported success.
#
# Expectations are read from the ARTIFACT's own configure string against scripts/test/
# capabilities.tsv, so there is no per-RID list to maintain and no way for the table to drift
# out of sync with what a given cell enabled.
check_claimed_capabilities() {
  # Locate the table relative to THIS file, not the caller's ${HERE}: lib.sh is sourced from
  # several scripts and should not depend on a variable each of them happens to set.
  local tsv flag opt re listing n claimed=0 missing=0
  tsv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/capabilities.tsv"
  [ -f "${tsv}" ] || { fail "capabilities.tsv missing - cannot verify claimed capabilities"; return; }
  [ -n "${CONFIG_STR:-}" ] || { fail "no embedded configure string - cannot verify capabilities"; return; }
  # This variant ASKS THE BINARY, so it needs a runnable one. Called before FFMPEG/RUNNER are
  # established it would silently see an empty listing and report every claimed capability as
  # missing -- ~30 bogus failures that look exactly like a catastrophic build regression. Fail
  # once, clearly, instead. (All three desktop scripts did call it too early; fixed alongside.)
  if [ -z "${FFMPEG:-}" ] || [ ! -e "${FFMPEG}" ]; then
    fail "check_claimed_capabilities called before FFMPEG is set (or the binary is missing) - capability verification did not run"
    return
  fi
  if [ -z "$(_enum -filters)" ]; then
    fail "ffmpeg produced no -filters listing under [${RUNNER[*]:-native}] - capability verification cannot run"
    return
  fi
  # Five fields now: the last two belong to check_claimed_capabilities_static and are unused
  # here, but they must still be READ or `read` folds them into ${re} and no regex matches.
  while IFS=$'\t' read -r flag opt re slib sname; do
    case "${flag}" in '#'*|"") continue ;; esac
    # "-" means this row has no CLI form (see capabilities.tsv: an unused field is a sentinel,
    # never empty, because TAB is IFS whitespace and adjacent empty fields collapse).
    [ -n "${opt}" ] && [ "${opt}" != "-" ] && [ -n "${re}" ] && [ "${re}" != "-" ] || continue
    : "${slib}" "${sname}"                    # consumed by the static variant, not here
    case " ${CONFIG_STR} " in *" ${flag} "*) ;; *) continue ;; esac
    claimed=$(( claimed + 1 ))
    listing="$(_enum "${opt}")"
    n="$(grep -cE "${re}" <<<"${listing}" || true)"
    if [ "${n}" -gt 0 ]; then
      pass "capability: ${flag} -> ${n} entr$([ "${n}" -eq 1 ] && echo y || echo ies) in ${opt}"
    else
      missing=$(( missing + 1 ))
      fail "capability: ${flag} is in the configure line but NOTHING matching /${re}/ is registered in ${opt} - silently dropped at build time"
    fi
  done < "${tsv}"
  if [ "${claimed}" -eq 0 ]; then
    fail "capability table matched no flags in this build's configure line - the table or the parse is broken"
  else
    info "capability check: ${claimed} claimed, ${missing} silently missing"
  fi
}

# ── The same check, for slices with no runnable CLI ───────────────────────
# check_claimed_capabilities above has to RUN ffmpeg to ask what is registered, so it covers only
# the RIDs whose binaries execute on a test runner. The mobile slices (Android .so, iOS/Catalyst
# frameworks) were therefore verified by INTENT alone -- test/android.sh asserted --enable-vulkan
# appears in the configure line and stopped there.
#
# That is exactly how this shipped. Measured in the published 9.0.1.7 and 8.1.2.7 artifacts:
# android-arm64, ios-arm64 and the maccatalyst slice each carry --enable-vulkan (iOS also
# --enable-vulkan-static) and ZERO Vulkan filters. No test noticed, because no test asked the
# binary anything.
#
# A cross-built library cannot be executed, but it can be READ. Every registered component's name
# is stored as a string in the library that registers it (the .name field of AVFilter / FFCodec /
# AVOutputFormat), so strings(1) finds it there, and finds nothing when the component was not
# compiled in. The ff_* registration symbols are NOT usable for this: they are hidden in a shared
# build and stripped besides (measured -- 0 hits via nm, nm -D and readelf on a library whose
# filters are definitely present).
#
# Matching is exact-line, never substring: "scale" as a substring occurs 67 times in libavfilter
# and would pass anything. Calibrated against real published artifacts -- present components
# score >= 1 (a universal Mach-O scores 2, once per arch slice), absent ones score exactly 0.
#
# TWO false-negative classes had to be handled, both found by measuring against artifacts whose
# CLI output disagreed with this check:
#
#   1. strings(1) defaults to a 4-character minimum, so a 3-character name like "srt" never
#      appears at all. Hence -n 2 below.
#   2. The linker tail-merges a string that is a SUFFIX of another one: libavformat on linux-x64
#      stores only "librist", so the protocol name "rist" has no standalone entry -- while the
#      same library on linux-arm64 does have one. `ffmpeg -protocols` lists rist on both. Same
#      shape as "flip_vulkan" inside "hflip_vulkan".
#
# Class 2 is indistinguishable from a genuine absence by reading strings alone, so when the exact
# name is missing BUT some string ends with it, the result is reported INCONCLUSIVE and does not
# fail. That keeps the check sound: it only fails when the name is absent and nothing could have
# absorbed it -- which is the case for scale_vulkan on the artifacts that really lack it.
#
# Usage: check_claimed_capabilities_static <libavutil> <libavcodec> <libavfilter> <libavformat>
# Explicit paths rather than a directory: the Android (lib/<abi>/libX.so) and Apple
# (X.xcframework/<slice>/X.framework/X) layouts share no shape.
# Resolve the four libav* libraries inside a staged artifact dir, whatever the platform names
# them (libavutil.so.61 / libavutil.61.dylib / avutil-61.dll / frameworks), and run the static
# check. Desktop RIDs run the CLI variant, which can only see rows that HAVE a CLI form -- so a
# static-only row (hevc_d3d11va, which ffmpeg lists nowhere) was unreachable on the exact
# platform it describes. Running both closes that: the CLI variant answers what ffmpeg reports,
# this one answers what is compiled in, and every row is covered on every RID.
# _find_lib <artifact-dir> <avcodec|avutil|...>  -> path, or empty.
# Covers every layout this repo stages: versioned .so, macOS .dylib, Windows .dll (flat or bin/),
# Android lib/<abi>/, and the Apple per-library .framework bundles.
_find_lib() {
  local d="$1" f="$2"
  ls -1 "${d}/lib${f}.so."* "${d}/lib${f}."*.dylib "${d}/${f}-"*.dll         "${d}/lib/lib${f}.so."* "${d}/lib/"*/"lib${f}.so" "${d}/bin/${f}-"*.dll         "${d}/frameworks/lib${f}.framework/lib${f}" "${d}/lib${f}.framework/lib${f}"         2>/dev/null | head -1
}

check_claimed_capabilities_in_dir() {   # <artifact-dir>
  local d="$1" f p=()
  for f in avutil avcodec avfilter avformat; do p+=("$(_find_lib "${d}" "${f}")"); done
  if [ -z "${p[0]}" ]; then
    fail "capability (static): no libavutil found under ${d} - cannot verify compiled-in components"
    return
  fi
  check_claimed_capabilities_static "${p[0]}" "${p[1]}" "${p[2]}" "${p[3]}"
}

check_claimed_capabilities_static() {
  local avutil="$1" avcodec="$2" avfilter="$3" avformat="$4"
  local tsv flag opt re slib sname cfg path n claimed=0 missing=0 inconclusive=0 d

  [ -n "${STRINGS:-}" ] || {
    fail "no strings(1)/llvm-strings - cannot verify capabilities on a non-executable slice"
    return
  }
  tsv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/capabilities.tsv"
  [ -f "${tsv}" ]    || { fail "capabilities.tsv missing"; return; }
  [ -f "${avutil}" ] || { fail "libavutil not found at ${avutil}"; return; }

  d="$(mktemp -d)"
  # The configure line lives in libavutil (av_configuration): the one string carrying --enable-.
  cfg="$("${STRINGS}" -a "${avutil}" | grep -m1 -- '--enable-' || true)"
  if [ -z "${cfg}" ]; then
    fail "no embedded configure string in ${avutil##*/} - cannot verify claimed capabilities"
    rm -rf "${d}"; return
  fi

  # One strings(1) pass per library, reused across every row.
  for path in "avcodec=${avcodec}" "avfilter=${avfilter}" "avformat=${avformat}"; do
    if [ -f "${path#*=}" ]; then "${STRINGS}" -a -n 2 "${path#*=}" > "${d}/${path%%=*}"
    else : > "${d}/${path%%=*}"; fi
  done

  while IFS=$'\t' read -r flag opt re slib sname; do
    case "${flag}" in '#'*|"") continue ;; esac
    : "${opt}" "${re}"                        # columns belonging to the CLI variant
    [ -n "${slib:-}" ] && [ "${slib}" != "-" ] || continue
    case " ${cfg} " in *" ${flag} "*) ;; *) continue ;; esac
    claimed=$(( claimed + 1 ))
    n="$(grep -cx -- "${sname}" "${d}/${slib}" || true)"
    if [ "${n}" -gt 0 ]; then
      pass "capability: ${flag} -> '${sname}' registered in lib${slib}"
    elif grep -qE -- "^.+${sname}\$" "${d}/${slib}"; then
      # Tail-merge candidate: a longer string ends with this name, so the linker may have folded
      # the standalone copy away. Cannot distinguish that from absence here -- do not fail.
      inconclusive=$(( inconclusive + 1 ))
      info "capability: ${flag} -> '${sname}' inconclusive in lib${slib} (absorbed by a longer string; not asserted)"
    else
      missing=$(( missing + 1 ))
      fail "capability: ${flag} is in the configure line but '${sname}' is NOT registered in lib${slib} - silently dropped at build time"
    fi
  done < "${tsv}"

  rm -rf "${d}"
  if [ "${claimed}" -eq 0 ]; then
    fail "capability table matched no flags in this slice's configure line - the table or the parse is broken"
  else
    info "capability check (static): ${claimed} claimed, ${missing} silently missing, ${inconclusive} inconclusive"
  fi
}


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
  local rc=0
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v error -i "$url" -f null - 2>&1)" || rc=$?
  # Positive evidence only. The resource is a TEXT file, so a working handshake ALWAYS ends in a
  # demux complaint -- that message is the proof bytes arrived. Empty output used to count as a
  # pass on its own; it cannot, because it is also what a silently-dead ffmpeg produces. Empty is
  # accepted only alongside a zero exit status.
  if grep -qiE 'Invalid data found|could not find codec|Unknown input format|does not contain any stream|End of file' <<<"$out"; then
    pass "TLS handshake: fetched bytes over https:// (backend negotiates)"; return
  fi
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
    pass "TLS handshake: https:// transfer completed cleanly (exit 0)"; return
  fi
  if [ -z "$out" ]; then
    fail "TLS handshake: ffmpeg exited ${rc} with no output on ${url} - cannot confirm a transfer"; return
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
  # NOTE: on SOME Windows runner instances, af_whisper SIGSEGVs during process TEARDOWN *after* the
  # inference completes successfully (verified: ffmpeg prints "Exiting with exit code 0" before the
  # crash). It's an upstream ggml/whisper teardown fault — NOT our harness (af_whisper inference is
  # synchronous, no thread we manage) and NOT the binary (0 crashes in ~300 local runs of the same
  # artifact; some runners are 0/60, others hit it — a runner/CPU lottery). Exact faulting op not yet
  # pinned (needs a debugger on a crashing runner — a later task). We run ONCE and FAIL LOUD on any
  # nonzero exit — no retry, no masking — capturing exit code + stderr (exit 139 = SIGSEGV). Re-run
  # the job if a bad runner trips it. (queue uses the 3s default — a DURATION; our clip is 2s.)
  local out ec
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v verbose -f lavfi -i "sine=frequency=220:duration=2" \
        -af "whisper=model=${model}:language=en:destination=${tmp}/out.txt" \
        -f null - 2>&1)"
  ec=$?
  if [ "$ec" -eq 0 ] && [ -e "${tmp}/out.txt" ]; then
    pass "whisper inference: af_whisper ran a CPU forward pass to completion"
  else
    fail "whisper inference: af_whisper did not complete (exit ${ec}; exit 139 is the known intermittent segfault, see issue #20 — re-run before investigating) — $(printf '%s' "$out" | tr '\n' ' ' | tail -c 400)"
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
  # 'No such filter' MUST be a hard failure, not a tolerated "no device here". It means the
  # filter is not in the binary at all -- the build silently dropped it -- which is a defect
  # in the artifact, not a property of the CI host. Without it, an FFmpeg 8.1.2 build whose
  # Vulkan filters were all disabled reported 'path exercised' and passed: the DEV_ERR
  # pattern below matches the bare 'No such', so a missing filter looked like a missing GPU.
  # That is precisely how every 8.1.2 cell shipped with zero Vulkan filters through a green
  # matrix. Ordered before the 'exercised' branch so it wins.
  elif grep -qiE 'No such filter|Unknown filter|Unknown (encoder|decoder)|not compiled|Cannot find a matching|is not supported|Unrecognized' <<<"$out"; then
    fail "hwaccel ${label}: NOT built/registered — $(tr '\n' ' ' <<<"$out" | cut -c1-140)"
  elif grep -qiE "$exercised" <<<"$out"; then
    pass "hwaccel ${label}: path exercised (driver loaded + device enumeration ran; no device on CI)"
  else
    info "hwaccel ${label}: inconclusive — $(tr '\n' ' ' <<<"$out" | cut -c1-140)"
  fi
}

# STRICT Vulkan check — the opposite of probe_hwaccel's tolerance. probe_hwaccel exists for
# hwaccels that genuinely have no device on a CI runner (VAAPI, QSV, AMF), so it classifies a
# "driver loaded, no device" message as a pass. That tolerance is wrong for Apple: MoltenVK is
# a software-reachable driver over Metal, and the macOS runner HAS Metal — so if Vulkan cannot
# initialise here, consumers cannot either, and we want a red build rather than a green one.
assert_vulkan_device() {
  local out rc
  out="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -v error \
          -init_hw_device "vulkan=vk" -f lavfi -i "testsrc=size=320x240:rate=25:duration=1" \
          -vf "format=nv12,hwupload,scale_vulkan=160:120,hwdownload,format=nv12" \
          -f null - 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "Vulkan: initialised a real device and ran scale_vulkan"
  else
    fail "Vulkan: FAILED to initialise on a Metal-capable host — $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  fi
}

# --- functional suite (parameterized launcher) --------------------------------
# Set RUNNER=() for native, (wine) for Windows, (qemu-aarch64 -L <sysroot>) etc.
# Requires FFMPEG and FFPROBE (paths) and RUNNER to be set by the caller.
run_functional() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  # Capture output+status instead of discarding them: when this gate trips it is the ONLY
  # signal, and ">/dev/null 2>&1" reduced a missing-DLL load failure to "does not run" with no
  # hint which library was absent. On Windows a failed module load prints nothing at all, so the
  # exit status carries the diagnosis (0xC0000135 / 3221225781 = STATUS_DLL_NOT_FOUND).
  local vout vrc prc pout
  vout="$("${RUNNER[@]}" "$FFMPEG" -hide_banner -version 2>&1)"; vrc=$?
  if [ "$vrc" -eq 0 ]; then
    pass "ffmpeg runs ($(head -1 <<<"$vout"))"
  else
    fail "ffmpeg does not run under [${RUNNER[*]:-native}] (exit ${vrc}): $(tr '\n' ' ' <<<"$vout" | cut -c1-300) — skipping remaining functional checks"
    return
  fi
  # Report WHY, like the ffmpeg check directly above. This discarded stdout and stderr and said
  # only "ffprobe does not run" -- useless, because ffmpeg had just run fine from the same
  # directory against the same libraries, so the difference was the whole story and the check
  # threw it away. A check that cannot say why it failed is the pattern this branch exists to
  # remove; it should not survive inside the suite that enforces it.
  prc=0
  pout="$("${RUNNER[@]}" "$FFPROBE" -hide_banner -version 2>&1)" || prc=$?
  if [ "${prc}" -eq 0 ]; then
    pass "ffprobe runs ($(head -1 <<<"$pout"))"
  else
    fail "ffprobe does not run under [${RUNNER[*]:-native}] (exit ${prc}): $(tr '\n' " " <<<"$pout" | cut -c1-300)"
    [ -e "$FFPROBE" ] || fail "  ...and $FFPROBE does not exist"
    [ -x "$FFPROBE" ] || fail "  ...and $FFPROBE is not executable"
  fi

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
