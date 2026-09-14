#!/usr/bin/env bash
# Validate deps.json structure. No-op (pass) if the ledger doesn't exist yet.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="${LEDGER:-${ROOT_DIR}/deps.json}"
[ -f "${LEDGER}" ] || { echo "ledger-validate: ${LEDGER} absent — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "ledger-validate: jq required" >&2; exit 2; }
jq -e . "${LEDGER}" >/dev/null || { echo "ledger-validate: invalid JSON" >&2; exit 1; }

# Every defaults + overrides entry: origin present, exactly one ref key.
if ! bad="$(jq -r '
  ( [ (.defaults // {}) | to_entries[] ]
    + [ (.overrides // {}) | to_entries[] | .value | to_entries[] ] )
  | .[]
  | .key as $k | .value as $e
  | ($e | [.tag, .branch, .commit] | map(select(. != null)) | length) as $refs
  | select(($e.origin | not) or ($refs != 1))
  | $k' "${LEDGER}")"; then
  echo "ledger-validate: structure check errored (jq)" >&2; exit 1
fi
if [ -n "${bad}" ]; then echo "ledger-validate: bad entries (need origin + exactly one ref): ${bad}" >&2; exit 1; fi

# Every override must carry a reason.
if ! noreason="$(jq -r '(.overrides // {}) | to_entries[] | .value | to_entries[] | select(.value.reason|not) | .key' "${LEDGER}")"; then
  echo "ledger-validate: reason check errored (jq)" >&2; exit 1
fi
if [ -n "${noreason}" ]; then echo "ledger-validate: overrides missing reason: ${noreason}" >&2; exit 1; fi

# A platform-scoped override's "platforms" (optional) must be a non-empty array of known RIDs.
if ! badplat="$(jq -r '
  ["linux-x64","linux-arm64","linux-armhf","linux-musl-x64","linux-musl-arm64","win-x64","win-arm64",
   "osx-x64","osx-arm64","android-arm64","android-x64","ios-arm64","ios-sim-arm64",
       "maccatalyst-arm64","maccatalyst-x64"] as $rids
  | (.overrides // {}) | to_entries[] | .value | to_entries[]
  | .key as $k | .value.platforms as $p
  | select($p != null)
  | select(($p | type != "array") or ($p | length == 0) or ($p | any(. as $x | $rids | index($x) | not)))
  | $k' "${LEDGER}")"; then
  echo "ledger-validate: platforms check errored (jq)" >&2; exit 1
fi
if [ -n "${badplat}" ]; then echo "ledger-validate: overrides with bad platforms (must be a non-empty array of known RIDs): ${badplat}" >&2; exit 1; fi
# A tarball origin that embeds its own version rots on the first Renovate bump: the custom
# managers update `tag` only, so origin keeps naming the OLD file. libgsm demonstrated it --
# origin said gsm-1.0.22.tar.gz while tag was 1.0.24. Nothing breaks (the download URL is built
# from dep_version), but it is wrong in exactly the place a reader would check, which is how the
# librist/mbedTLS misdescription survived for months. Applied only to tarball-looking origins;
# git URLs legitimately contain no version, and capture() simply yields nothing for them.
if ! drift="$(jq -r '
   paths as $p | getpath($p) | objects
   | select(has("origin") and has("tag")) | select(.origin | type == "string")
   | select(.origin | test("[.](tar[.](gz|xz|bz2)|tgz)$"))
   | . as $e
   | ($e.origin | capture("(?<v>[0-9]+[.][0-9]+([.][0-9]+)?)")) as $c
   | select(($e.tag | tostring | contains($c.v)) | not)
   | "\($e.origin) names \($c.v) but tag is \($e.tag)"' "${LEDGER}" | sort -u)"; then
  echo "ledger-validate: origin/tag drift check errored (jq)" >&2; exit 1
fi
if [ -n "${drift}" ]; then
  echo "ledger-validate: tarball origin embeds a version that does not match its tag:" >&2
  echo "${drift}" | sed 's/^/  /' >&2
  echo "  Use an unversioned origin (the release directory) so it cannot go stale." >&2
  exit 1
fi
echo "ledger-validate: OK"
