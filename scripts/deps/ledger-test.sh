#!/usr/bin/env bash
# Unit test for the dep ledger loader. Points the loader at a fixture ledger.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$(mktemp -d)"
export LEDGER="${FIX}/deps.json"
cat > "${LEDGER}" <<'JSON'
{
  "defaults": {
    "x265":   { "origin": "https://example.test/x265.git",  "tag": "4.0" },
    "libfoo": { "origin": "https://example.test/foo.git",   "commit": "abc123" },
    "libbar": { "origin": "https://example.test/bar.git",   "branch": "main", "reason": "no tags" },
    "libbad": { "origin": "https://example.test/bad.git",   "tag": "1.0", "branch": "dev" }
  },
  "overrides": {
    "8": { "x265": { "origin": "https://example.test/x265.git", "branch": "stable-8", "reason": "8.x caps libx265 at 3.x" } },
    "9": { "x265": { "origin": "https://example.test/x265.git", "tag": "3.6", "reason": "arm64 neon", "platforms": ["linux-arm64", "osx-arm64"] } }
  }
}
JSON
export ROOT_DIR="${FIX}"   # unused (LEDGER overrides), set for safety
unset BUILD_RID            # base cases are RID-agnostic; platform cases set it explicitly
# shellcheck source=/dev/null
. "${HERE}/lib.sh"

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

FFMPEG_VERSION=9.0.1 got="$(dep_source x265)";   check "9 default x265 (no RID)"  "$got" "$(printf 'https://example.test/x265.git\ttag\t4.0')"
FFMPEG_VERSION=8.1.2 got="$(dep_source x265)";   check "8 override (version-wide) switches ref type" "$got" "$(printf 'https://example.test/x265.git\tbranch\tstable-8')"
FFMPEG_VERSION=9.0.1 BUILD_RID=linux-arm64 got="$(dep_source x265)"; check "platform override applies on a listed RID" "$got" "$(printf 'https://example.test/x265.git\ttag\t3.6')"
FFMPEG_VERSION=9.0.1 BUILD_RID=linux-x64  got="$(dep_source x265)"; check "platform override skipped off-list -> default" "$got" "$(printf 'https://example.test/x265.git\ttag\t4.0')"
FFMPEG_VERSION=9.0.1 got="$(dep_source libfoo)"; check "commit ref"           "$got" "$(printf 'https://example.test/foo.git\tcommit\tabc123')"
FFMPEG_VERSION=9.0.1 got="$(dep_source libbar)"; check "branch ref"           "$got" "$(printf 'https://example.test/bar.git\tbranch\tmain')"
export FFMPEG_VERSION=9.0.1
if dep_source nope 2>/dev/null; then check "missing dep fails" present absent; else check "missing dep fails" ok ok; fi
if dep_source libbad 2>/dev/null; then check "malformed dep fails" present absent; else check "malformed dep fails" ok ok; fi
if LEDGER=/no/such/file dep_source x265 2>/dev/null; then check "missing ledger fails" present absent; else check "missing ledger fails" ok ok; fi

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
