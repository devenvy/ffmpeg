#!/usr/bin/env bash
set -euo pipefail
# Render a release's asset list as a GNU sha256sum-format manifest on stdout.
#
# Usage: gen-manifest.sh <tag> <repo>
#
# The GitHub release API already carries a per-asset `digest` ("sha256:<hex>"), so the common
# path is pure metadata — a release is ~64 assets and several GB, and re-downloading them to
# compute what the API already knows would be slow and wasteful. Assets whose digest is absent
# (older uploads predate the field) fall back to a single-asset download + hash.
#
# Sourcing with GEN_MANIFEST_LIB_ONLY=1 defines the functions without running anything, so
# gen-manifest-test.sh can stub the two I/O points (list_release_assets, download_and_hash).

# I/O point 1: emits one "<name><TAB><digest>" line per asset; digest empty when the API has
# none. Uses gh's BUILT-IN --jq engine, so no external jq binary is required.
list_release_assets() { # <tag> <repo>
  gh release view "$1" --repo "$2" --json assets \
    --jq '.assets[] | [.name, (.digest // "")] | @tsv'
}

# I/O point 2: fallback for an asset the API gave no digest for.
download_and_hash() { # <tag> <repo> <asset-name>  -> <hex> on stdout
  local tmp; tmp="$(mktemp -d)"
  gh release download "$1" --repo "$2" --pattern "$3" --dir "${tmp}" --clobber >&2 || {
    rm -rf "${tmp}"; return 1; }
  sha256sum "${tmp}/$3" | awk '{print $1}'
  rm -rf "${tmp}"
}

generate_manifest() { # <tag> <repo>
  local tag="$1" repo="$2" name digest hex
  local out=""
  local tab; tab="$(printf '\t')"
  # Plain-shell TSV read: no external jq, and no subprocess per asset.
  while IFS="${tab}" read -r name digest; do
    [ -n "${name}" ] || continue
    # Never list the manifest inside itself: its own hash cannot be known at write time, and a
    # stale line from a previous run would fail verification for everyone.
    [ "${name}" = "SHA256SUMS" ] && continue
    if [[ "${digest}" =~ ^sha256:([0-9a-f]{64})$ ]]; then
      hex="${BASH_REMATCH[1]}"
    else
      echo "note: no API digest for ${name}; downloading to hash it" >&2
      hex="$(download_and_hash "${tag}" "${repo}" "${name}")" || {
        echo "ERROR: could not hash ${name} - refusing to emit a partial manifest" >&2
        return 1; }
    fi
    out+="${hex}  ${name}"$'\n'
  done < <(list_release_assets "${tag}" "${repo}")

  [ -n "${out}" ] || { echo "ERROR: release ${tag} has no assets to hash" >&2; return 1; }
  # Sort by filename so the manifest is stable across reruns and diffable between releases.
  LC_ALL=C sort -k2 <<<"${out%$'\n'}"
}

[ -n "${GEN_MANIFEST_LIB_ONLY:-}" ] && return 0
[ "$#" -eq 2 ] || { echo "usage: $0 <tag> <repo>" >&2; exit 1; }
generate_manifest "$1" "$2"
