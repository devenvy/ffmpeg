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
# The overriding rule here is FAIL LOUDLY RATHER THAN EMIT A PARTIAL MANIFEST: `sha256sum -c`
# silently skips any file it finds no line for, so a short manifest is more dangerous than no
# manifest at all. Every early-exit below exists to honour that.
#
# Sourcing with GEN_MANIFEST_LIB_ONLY=1 defines the functions without running anything, so
# gen-manifest-test.sh can stub the two I/O points (list_release_assets, download_and_hash).

# I/O point 1: emits one "<name><TAB><digest>" line per asset; digest empty when the API has
# none. Uses gh's BUILT-IN --jq engine, so no external jq binary is required.
#
# NOTE: @tsv escapes backslash, tab, CR and LF inside the name field, and GNU sha256sum has its
# own, different backslash convention — so an asset name containing any of those would be
# written in a form `sha256sum -c` misreads. GitHub normalizes asset names, so this cannot
# occur for the names this repo publishes; documented rather than coded around.
list_release_assets() { # <tag> <repo>
  gh release view "$1" --repo "$2" --json assets \
    --jq '.assets[] | [.name, (.digest // "")] | @tsv'
}

# I/O point 2: fallback for an asset the API gave no digest for.
# `--pattern` is a filepath.Match glob: a name containing * or ? would over-match (harmless —
# we still hash the exact path below), and one containing [ makes gh exit non-zero, which
# aborts. Fail-safe in both directions.
download_and_hash() { # <tag> <repo> <asset-name>  -> <hex> on stdout
  local tmp; tmp="$(mktemp -d)"
  # trap, not a trailing rm: a sha256sum failure below must not leak the temp dir.
  trap 'rm -rf "${tmp}"' RETURN
  gh release download "$1" --repo "$2" --pattern "$3" --dir "${tmp}" --clobber >&2 || return 1
  sha256sum "${tmp}/$3" | awk '{print $1}'
}

generate_manifest() { # <tag> <repo>
  local tag="$1" repo="$2" name digest hex raw
  local out=""
  local tab=$'\t'

  # Slurp FIRST and check the producer's exit status. Reading straight from a process
  # substitution (`done < <(list_release_assets ...)`) discards that status — pipefail does not
  # apply — so a `gh` that printed some lines and then died (auth expiry, rate limit, truncated
  # response) would end the loop normally and produce a SHORT MANIFEST with exit 0.
  raw="$(list_release_assets "${tag}" "${repo}")" || {
    echo "ERROR: could not list assets for ${tag} - refusing to emit a partial manifest" >&2
    return 1; }
  [ -n "${raw}" ] || { echo "ERROR: release ${tag} has no assets to hash" >&2; return 1; }

  # `<<<` guarantees a trailing newline, so a final line lacking one cannot be silently
  # dropped the way `while read` would drop it when reading a stream directly.
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
  done <<<"${raw}"

  [ -n "${out}" ] || { echo "ERROR: release ${tag} yielded no manifest lines" >&2; return 1; }
  # Sort by filename so the manifest is stable across reruns and diffable between releases.
  # -b ignores leading blanks in the key, so a name with leading whitespace cannot sort by
  # blank count instead of by name.
  LC_ALL=C sort -b -k2 <<<"${out%$'\n'}"
}

[ -n "${GEN_MANIFEST_LIB_ONLY:-}" ] && return 0
[ "$#" -eq 2 ] || { echo "usage: $0 <tag> <repo>" >&2; exit 1; }
generate_manifest "$1" "$2"
