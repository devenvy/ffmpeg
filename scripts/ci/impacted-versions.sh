#!/usr/bin/env bash
# Print which tracked FFmpeg versions a dependency-ledger change actually affects.
#
# A version line (FFmpeg major M) is IMPACTED by a deps.json change iff its RESOLVED
# dependency set changed — so a lib bump does NOT trigger a release for a line that
# pins that lib to an unchanged version. Resolution mirrors the loader (scripts/deps/lib.sh):
#   - no override for M            -> M uses the default              (default bump  => impacted)
#   - platform-scoped override     -> default still applies elsewhere (default bump  => impacted)
#   - whole-line override (no platforms) -> M uses the pin            (default bump  => NOT impacted)
#
# Usage: impacted-versions.sh <before-deps.json> <after-deps.json> <version>...
#   emits the impacted <version> args, one per line (subset, order preserved).
set -euo pipefail
before="$1"; after="$2"; shift 2

_sig() { # <ledger-file> <major> -> canonical resolved signature for that major
  jq -er --arg m "$2" '
    def refof(e): (e | to_entries
      | map(select(.key=="tag" or .key=="branch" or .key=="commit")) | .[0]
      | "\(.key):\(.value)");
    [ (.defaults // {}) | keys[] ] as $names
    | [ $names[] as $n
        | (.overrides[$m][$n]) as $ov
        | (.defaults[$n])      as $def
        | if   $ov == null            then "\($n)=\(refof($def))"                       # default
          elif ($ov.platforms == null) then "\($n)=OVR:\(refof($ov))"                    # whole-line pin
          else                              "\($n)=\(refof($def))+OVR:\(refof($ov))"     # platform-scoped
          end
      ] | sort | join(";")
  ' "$1"
}

for v in "$@"; do
  m="${v%%.*}"
  if [ "$(_sig "$before" "$m")" != "$(_sig "$after" "$m")" ]; then
    printf '%s\n' "$v"
  fi
done
