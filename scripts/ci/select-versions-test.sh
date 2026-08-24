#!/usr/bin/env bash
# Regression tests for the release-selection helpers:
#   impacted-versions.sh — which FFmpeg lines a ledger change actually affects
#   select-versions.sh    — which lines a push/PR should build+release, from a git diff
# These two decide whether a merge cuts a release, and for WHICH version lines, so a
# wrong answer either ships an unchanged line or silently skips a changed one. Run in CI
# (shellcheck.yml, "Dependency ledger checks" step).
#
# Part A tests impacted-versions.sh with pure JSON fixtures (no git).
# Part B tests select-versions.sh end-to-end in throwaway git repos.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPACTED="${HERE}/impacted-versions.sh"
SELECT="${HERE}/select-versions.sh"

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1"; printf '   got  [%s]\n   want [%s]\n' "$2" "$3"; fail=$((fail+1)); fi
}

# A temp dir we own and clean up. Guard hard (a past incident had a test's `cd` fail
# silently and run git writes in the real repo): everything destructive below uses an
# explicit `git -C`, never the cwd, but keep the guard as a second line of defense.
TMPROOT="$(mktemp -d)"
case "${TMPROOT}" in
  /tmp/*|/var/*|/private/*|"${TMPDIR:-/nonexistent}"/*) : ;;
  *) echo "refusing to run: temp dir '${TMPROOT}' is not under a temp root" >&2; exit 1;;
esac
trap 'rm -rf "${TMPROOT}"' EXIT

# Base ledger. Major 8 whole-line-pins libpinned (no platforms -> a libpinned default bump
# must NOT impact line 8). Major 9 platform-scopes libshared (default still applies
# elsewhere -> a libshared default bump DOES impact line 9). Variants are derived with jq
# so a fixture edit can't silently corrupt the JSON.
cat > "${TMPROOT}/base.json" <<'JSON'
{
  "ffmpeg": ["8.1.2", "9.0.1"],
  "defaults": {
    "libshared": { "origin": "o", "tag": "1.0" },
    "libpinned": { "origin": "o", "tag": "2.0" }
  },
  "overrides": {
    "8": { "libpinned": { "origin": "o", "tag": "1.9" } },
    "9": { "libshared": { "origin": "o", "tag": "1.0", "platforms": ["linux-arm64"] } }
  }
}
JSON
variant() { jq "$1" "${TMPROOT}/base.json"; }   # <jq-filter> -> mutated ledger on stdout

echo "=== Part A: impacted-versions.sh (resolution rules) ==="
a() { # <label> <jq-mutation> <expected newline-joined versions>
  variant "$2" > "${TMPROOT}/after.json"
  check "$1" "$(bash "${IMPACTED}" "${TMPROOT}/base.json" "${TMPROOT}/after.json" 8.1.2 9.0.1)" "$3"
}
a "shared-default bump impacts BOTH lines"          '.defaults.libshared.tag="1.1"'    "$(printf '8.1.2\n9.0.1')"
a "pinned-default bump impacts only the unpinned 9" '.defaults.libpinned.tag="2.1"'    "9.0.1"
a "override's own pin bump impacts only line 8"     '.overrides["8"].libpinned.tag="1.8"' "8.1.2"
a "no dependency change impacts nothing"            '.'                                 ""

echo "=== Part B: select-versions.sh (diff -> selection) ==="
# Build a throwaway repo: base commit (base.json + a scripts/ recipe file), then a second
# commit applying the change under test; echo the sorted selection for base..HEAD.
select_for() { # <jq-mutation | ''=no deps change> <recipe-change yes|no> <tracked...>
  local mut="$1" recipe="$2"; shift 2
  local repo; repo="$(mktemp -d "${TMPROOT}/repo.XXXXXX")"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  mkdir -p "$repo/scripts"
  cp "${TMPROOT}/base.json" "$repo/deps.json"
  printf 'echo build\n' > "$repo/scripts/build.sh"
  git -C "$repo" add -A; git -C "$repo" commit -qm base
  local base; base="$(git -C "$repo" rev-parse HEAD)"
  [ -n "$mut" ] && variant "$mut" > "$repo/deps.json"
  [ "$recipe" = yes ] && printf 'echo changed\n' > "$repo/scripts/build.sh"
  git -C "$repo" add -A; git -C "$repo" commit -qm change --allow-empty
  ( cd "$repo" && [ "$PWD" = "$repo" ] && bash "${SELECT}" "$base" "$@" | sort | paste -sd' ' - )
}

# A point bump replaces the entry, so the post-change tracked list (what ci.yml/release.yml
# read from HEAD's deps.json) carries the NEW version — that is what must release.
check "ffmpeg 9 point bump -> only line 9" \
  "$(select_for '.ffmpeg=["8.1.2","9.0.2"]' no 8.1.2 9.0.2)" "9.0.2"
check "new ffmpeg major line 10 added -> only line 10" \
  "$(select_for '.ffmpeg += ["10.0.0"]' no 8.1.2 9.0.1 10.0.0)" "10.0.0"
check "shared-default lib bump -> BOTH lines" \
  "$(select_for '.defaults.libshared.tag="1.1"' no 8.1.2 9.0.1)" "8.1.2 9.0.1"
check "pinned-default lib bump -> only unpinned line 9" \
  "$(select_for '.defaults.libpinned.tag="2.1"' no 8.1.2 9.0.1)" "9.0.1"
check "combined: 9 point bump + a lib that 8 pins -> only 9 (8 not impacted)" \
  "$(select_for '.ffmpeg=["8.1.2","9.0.2"] | .defaults.libpinned.tag="2.1"' no 8.1.2 9.0.2)" "9.0.2"
check "build-recipe change -> ALL lines" \
  "$(select_for '' yes 8.1.2 9.0.1)" "8.1.2 9.0.1"
check "no relevant change -> nothing" \
  "$(select_for '' no 8.1.2 9.0.1)" ""

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
