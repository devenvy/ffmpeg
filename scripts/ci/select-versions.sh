#!/usr/bin/env bash
# Decide which tracked FFmpeg versions a push/PR should build + release, from the diff
# between a base ref and HEAD. ci.yml (PR) and release.yml (push) share this ONE tested
# implementation. Rules (unioned):
#   - a build-recipe change (scripts/**, except scripts/test/**) -> ALL tracked versions
#   - a deps.json change -> only lines whose RESOLVED dependency set changed
#     (a line that whole-line-pins the bumped dep is NOT affected — see impacted-versions.sh)
#   - a versions.txt change -> the added/changed version lines
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
    while read -r v; do [ -n "${v}" ] && pick["${v}"]=1; done \
      < <(bash "${HERE}/impacted-versions.sh" "${before}" deps.json "${tracked[@]}")
    rm -f "${before}"
  else
    for v in "${tracked[@]}"; do pick["${v}"]=1; done   # no base ledger -> all
  fi
fi

if printf '%s\n' "${changed}" | grep -qx 'versions.txt'; then
  if git cat-file -e "${base}:versions.txt" 2>/dev/null; then
    mapfile -t prev < <(git show "${base}:versions.txt" | grep -vE '^[[:space:]]*(#|$)' | sed 's/[[:space:]]//g;/^$/d')
  else
    prev=()
  fi
  for v in "${tracked[@]}"; do
    found=false
    for p in "${prev[@]:-}"; do [[ "${v}" == "${p}" ]] && found=true && break; done
    ${found} || pick["${v}"]=1
  done
fi

for v in "${!pick[@]}"; do printf '%s\n' "${v}"; done
