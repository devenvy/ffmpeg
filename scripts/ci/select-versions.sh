#!/usr/bin/env bash
# Decide which tracked FFmpeg versions a push/PR should build + release, from the diff between
# a base ref and HEAD. Everything lives in deps.json now — the ledger holds the FFmpeg versions
# in .ffmpeg, library versions in .defaults, and per-line holds in .overrides. ci.yml (PR) and
# release.yml (push) share this ONE tested implementation. Rules (unioned):
#   - a build-recipe change (scripts/**, except scripts/test/**) -> ALL tracked versions
#   - a .ffmpeg entry added/changed  -> that version line (an FFmpeg point bump)
#   - a .defaults/.overrides change  -> only lines whose RESOLVED dep set changed (a line that
#     whole-line-pins the bumped dep is NOT affected — see impacted-versions.sh)
# Emits the selected versions, one per line (empty output = nothing to build).
# Usage: select-versions.sh <base-ref> <version>...
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="$1"; shift
tracked=("$@")

# No usable base (first push / unknown) -> can't diff, so rebuild everything.
if [ -z "${base}" ] || [[ "${base}" =~ ^0+$ ]] || ! git rev-parse -q --verify "${base}^{commit}" >/dev/null 2>&1; then
  printf '%s\n' "${tracked[@]}"; exit 0
fi

changed="$(git diff --name-only "${base}" HEAD)"

# Build-recipe change affects every line's artifacts.
if printf '%s\n' "${changed}" | grep -E '^scripts/' | grep -qv '^scripts/test/'; then
  printf '%s\n' "${tracked[@]}"; exit 0
fi

declare -A pick=()

if printf '%s\n' "${changed}" | grep -qx 'deps.json'; then
  if git cat-file -e "${base}:deps.json" 2>/dev/null; then
    before="$(mktemp)"; git show "${base}:deps.json" > "${before}"
    # (a) FFmpeg version lines added or changed: a tracked version not present in the base .ffmpeg
    #     is a bump (9.0.1 -> 9.0.2) or a newly added line.
    mapfile -t before_ff < <(jq -r '.ffmpeg[]?' "${before}")
    for v in "${tracked[@]}"; do
      seen=false
      for b in "${before_ff[@]:-}"; do [ "${v}" = "${b}" ] && seen=true && break; done
      ${seen} || pick["${v}"]=1
    done
    # (b) lines whose resolved LIBRARY set changed (.defaults / .overrides).
    while read -r v; do [ -n "${v}" ] && pick["${v}"]=1; done \
      < <(bash "${HERE}/impacted-versions.sh" "${before}" deps.json "${tracked[@]}")
    rm -f "${before}"
  else
    for v in "${tracked[@]}"; do pick["${v}"]=1; done   # no base ledger -> all
  fi
fi

for v in "${!pick[@]}"; do printf '%s\n' "${v}"; done
