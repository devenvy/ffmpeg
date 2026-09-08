#!/usr/bin/env bash
# Unit test for the release checksum-manifest generator. Stubs the GitHub API call and the
# per-asset download so the generator runs with no network, no gh, and no jq.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

# Source FIRST, then override. gen-manifest.sh DEFINES list_release_assets and
# download_and_hash, so stubs installed before the source would be silently overwritten and the
# test would hit the real GitHub API.
# shellcheck source=/dev/null
GEN_MANIFEST_LIB_ONLY=1 . "${HERE}/gen-manifest.sh"
# gen-manifest.sh's own `set -euo pipefail` ran in THIS shell when sourced. Re-assert the
# suite's options: with -e left on, the first case that calls generate_manifest bare and
# expects a non-zero exit would kill the run with no FAIL: line.
set +e
set -uo pipefail

# --- 1. happy path ------------------------------------------------------------------------
# Two assets with API digests, one without (forces the download fallback), and a pre-existing
# SHA256SUMS that must be excluded from its own manifest.
list_release_assets() {
  printf '%s\t%s\n' \
    ffmpeg-9.0.1-linux-x64-lgplv3.tar.gz sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    ffmpeg-9.0.1-win-x64-gplv2.tar.gz    sha256:2222222222222222222222222222222222222222222222222222222222222222 \
    ffmpeg-9.0.1-ios-lgplv2.tar.gz       "" \
    SHA256SUMS                           sha256:9999999999999999999999999999999999999999999999999999999999999999
}
download_and_hash() { echo "3333333333333333333333333333333333333333333333333333333333333333"; }

got="$(generate_manifest v9.0.1 example/repo)"
# Expected order is the generator's LC_ALL=C sort by FILENAME: ios < linux < win.
want="$(printf '%s  %s\n' \
  3333333333333333333333333333333333333333333333333333333333333333 ffmpeg-9.0.1-ios-lgplv2.tar.gz \
  1111111111111111111111111111111111111111111111111111111111111111 ffmpeg-9.0.1-linux-x64-lgplv3.tar.gz \
  2222222222222222222222222222222222222222222222222222222222222222 ffmpeg-9.0.1-win-x64-gplv2.tar.gz)"
check "manifest lines, sorted by filename, SHA256SUMS excluded" "$got" "$want"

# --- 2. a filename containing a space survives intact --------------------------------------
# GNU sha256sum -c parses the rest of the line as the name, so spaces are legal and must not
# be split by the reader or mangled by the sort.
list_release_assets() {
  printf '%s\t%s\n' \
    "ffmpeg 9.0 win.tar.gz" sha256:4444444444444444444444444444444444444444444444444444444444444444
}
got="$(generate_manifest v9.0.1 example/repo)"
want="4444444444444444444444444444444444444444444444444444444444444444  ffmpeg 9.0 win.tar.gz"
check "filename containing a space is preserved" "$got" "$want"

# --- 3. an unterminated final line must NOT be dropped -------------------------------------
# `while read` on a raw stream silently discards a last line with no trailing newline, which
# would be a short manifest with exit 0 — the exact failure this tool must never produce.
list_release_assets() {
  printf 'a.tar.gz\tsha256:5555555555555555555555555555555555555555555555555555555555555555\n'
  printf 'b.tar.gz\tsha256:6666666666666666666666666666666666666666666666666666666666666666'
}
got="$(generate_manifest v9.0.1 example/repo | wc -l | tr -d ' ')"
check "final line without a trailing newline is still emitted" "$got" "2"

# --- 4. a producer that fails mid-stream must abort, not truncate ---------------------------
# Process substitution hides the producer's exit status; reading it that way would emit the
# lines printed before the failure and exit 0.
list_release_assets() {
  printf 'a.tar.gz\tsha256:7777777777777777777777777777777777777777777777777777777777777777\n'
  return 1
}
if generate_manifest v9.0.1 example/repo >/dev/null 2>&1; then
  check "producer failing mid-stream aborts" produced-manifest aborted
else
  check "producer failing mid-stream aborts" aborted aborted
fi

# --- 5. an empty asset list is an error, not an empty manifest ------------------------------
list_release_assets() { :; }
if generate_manifest v9.0.1 example/repo >/dev/null 2>&1; then
  check "empty asset list aborts" produced-manifest aborted
else
  check "empty asset list aborts" aborted aborted
fi

# --- 6. an unhashable digest-less asset aborts rather than shortening the manifest ----------
list_release_assets() {
  printf '%s\t%s\n' \
    a.tar.gz sha256:8888888888888888888888888888888888888888888888888888888888888888 \
    b.tar.gz ""
}
download_and_hash() { return 1; }
if generate_manifest v9.0.1 example/repo >/dev/null 2>&1; then
  check "unhashable asset aborts" produced-manifest aborted
else
  check "unhashable asset aborts" aborted aborted
fi

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
