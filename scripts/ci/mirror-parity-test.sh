#!/usr/bin/env bash
# Check every ledger "mirror" (deps.json .defaults.<dep>.mirror) still serves EXACTLY the pinned ref.
#
# clone_dep (scripts/deps/lib.sh) falls back to a dep's mirror when its origin is down. That is only
# safe while the mirror is a faithful copy: a tag pin must resolve to the same commit on both, and a
# commit pin must be on its digestBranch in a normal clone of the mirror. A mirror that lags a
# new tag is caught here as "missing on mirror" -- run this after a ledger bump (Renovate PR) and
# before relying on the fallback. Needs the network, so it is a tool, not an offline CI gate.
#
# Exit 1 if any mirror disagrees with its origin or lacks the pinned ref. An unreachable ORIGIN is
# reported but not a failure (that is exactly when the mirror is needed); the mirror is still checked.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
LEDGER_FILE="${LEDGER:-$(pwd)/deps.json}"
export GIT_TERMINAL_PROMPT=0

# Run git from / so a surrounding (or broken) repo -- e.g. a worktree whose .git points elsewhere --
# can never make a remote query fail and read as "missing on mirror".
peeled() {   # <url> <tag> -> commit the tag points at (peeled), or empty
  ( cd / && timeout 120 git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" 2>/dev/null ) | awk '{c=$1} END {print c}'
}
# A commit pin is only safe from a mirror if a NORMAL clone of it contains the commit on the pinned
# branch. Fetching the hash directly is not proof: GitHub serves objects shared across a fork network,
# so a stale mirror can "have" a commit no branch of it contains (mirror/x264 did exactly that).
on_branch() {   # <url> <commit> <branch> -> 0 if <commit> is an ancestor of <branch> on <url>
  local t rc=1; t="$(mktemp -d)"
  if ( cd / && timeout 600 git clone -q --bare --filter=blob:none --single-branch --branch "$3" "$1" "${t}/r" 2>/dev/null ); then
    git -C "${t}/r" merge-base --is-ancestor "$2" "refs/heads/$3" 2>/dev/null && rc=0
  fi
  rm -rf "${t}"; return "${rc}"
}

# Read the ledger FIRST and fail on error: fed through process substitution, a jq failure (missing
# file, bad JSON, no jq) produced zero rows and the check "passed" having checked nothing. Covers
# override entries too, so a mirror added to a hold is validated like a default one.
rows="$(jq -r '
    [ (.defaults // {} | to_entries[] | .value.name_ = .key | .value),
      ((.overrides // {}) | to_entries[] | .key as $mj | .value | to_entries[]
         | .value.name_ = "\(.key) (overrides.\($mj))" | .value) ]
    | .[] | select(.mirror)
    | [.name_, .origin, .mirror, (.tag // ""), (.commit // ""), (.digestBranch // "")] | join("|")
  ' "${LEDGER_FILE}")" || { echo "FAIL: could not read ledger ${LEDGER_FILE}" >&2; exit 1; }

bad=0 n=0
# '|' separator, not tab: tab is IFS whitespace, so an empty tag/commit field would collapse and
# shift the rest into the wrong variables.
while IFS='|' read -r dep origin mirror tag commit branch; do
  [ -n "${dep}" ] || continue
  n=$((n+1))
  if [ -n "${tag}" ]; then
    o="$(peeled "${origin}" "${tag}")"; m="$(peeled "${mirror}" "${tag}")"
    if [ -z "${m}" ]; then
      echo "FAIL ${dep}: tag ${tag} missing on mirror ${mirror}"; bad=1
    elif [ -z "${o}" ]; then
      echo "WARN ${dep}: origin unreachable; mirror has ${tag} -> ${m:0:12} (cannot compare)"
    elif [ "${o}" != "${m}" ]; then
      echo "FAIL ${dep}: ${tag} is ${o:0:12} on origin but ${m:0:12} on mirror"; bad=1
    else
      echo "ok   ${dep}: ${tag} -> ${o:0:12} on both"
    fi
  elif [ -n "${commit}" ] && [ -n "${branch}" ]; then
    if on_branch "${mirror}" "${commit}" "${branch}"; then
      echo "ok   ${dep}: commit ${commit:0:12} is on ${branch} in a clone of the mirror"
    else
      echo "FAIL ${dep}: commit ${commit:0:12} is not on ${branch} in a clone of ${mirror}"; bad=1
    fi
  else
    echo "FAIL ${dep}: mirror set but no tag, or commit without digestBranch"; bad=1
  fi
done <<< "${rows}"

echo "${n} mirror(s) checked"
[ "${bad}" -eq 0 ]
