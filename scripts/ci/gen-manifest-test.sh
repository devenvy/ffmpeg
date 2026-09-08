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

# Fixture: two assets with API digests, one without (forces the download fallback), and a
# pre-existing SHA256SUMS that must be excluded from its own manifest.
list_release_assets() {
  printf '%s\t%s\n' \
    ffmpeg-9.0.1-linux-x64-lgplv3.tar.gz sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    ffmpeg-9.0.1-win-x64-gplv2.tar.gz    sha256:2222222222222222222222222222222222222222222222222222222222222222 \
    ffmpeg-9.0.1-ios-lgplv2.tar.gz       "" \
    SHA256SUMS                           sha256:9999999999999999999999999999999999999999999999999999999999999999
}
# Stub the fallback: pretend we downloaded the asset and hashed it.
download_and_hash() { echo "3333333333333333333333333333333333333333333333333333333333333333"; }

got="$(generate_manifest v9.0.1 example/repo)"

# Expected order is the generator's LC_ALL=C sort by FILENAME: ios < linux < win.
want="$(printf '%s  %s\n' \
  3333333333333333333333333333333333333333333333333333333333333333 ffmpeg-9.0.1-ios-lgplv2.tar.gz \
  1111111111111111111111111111111111111111111111111111111111111111 ffmpeg-9.0.1-linux-x64-lgplv3.tar.gz \
  2222222222222222222222222222222222222222222222222222222222222222 ffmpeg-9.0.1-win-x64-gplv2.tar.gz)"

check "manifest lines, sorted by filename, SHA256SUMS excluded" "$got" "$want"

# A digest-less asset whose download fails must abort, not emit a short manifest: a verifier
# silently skips any file it finds no line for, so a partial manifest is worse than none.
download_and_hash() { return 1; }
if generate_manifest v9.0.1 example/repo >/dev/null 2>&1; then
  check "unhashable asset aborts" produced-manifest aborted
else
  check "unhashable asset aborts" aborted aborted
fi

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
