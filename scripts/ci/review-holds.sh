#!/usr/bin/env bash
# Weekly review of dependency holds (run by .github/workflows/check-updates.yml).
#
# A hold (deps.json .defaults.<dep>.hold + its renovate.json allowedVersions rule) keeps Renovate
# from offering a version we have decided not to ship. Nothing about a hold ever expires, so
# without a prompt it outlives its reason -- which is how a dependency stagnates. This script is
# that prompt. It never lifts a hold or moves a date itself; it only makes the review impossible
# to miss, on the hold's own tracking issue:
#   - a CLOSED issue for a live hold is reopened (a closed issue is exactly how a hold is forgotten);
#   - once reviewAfter has passed, it comments ONCE per (dep, reviewAfter) -- a hidden marker makes
#     re-runs and interrupted runs idempotent -- and applies the hold-review-due label, which stays
#     until a human either lifts the hold or sets a new reviewAfter (the next run then removes it);
#   - every run lists all holds and their status in the job summary.
# It deliberately does not query upstream for newer versions: Renovate already does that, and a
# second version-comparison implementation here would be one more thing to be subtly wrong.
#
# Failures are real failures: a missing issue, an auth error or a malformed ledger fails the job,
# because a reminder that silently does nothing is the failure this exists to prevent.
#
# Env: GH_TOKEN, GH_REPO (owner/name) -- required unless DRY_RUN=1, which prints the actions
# instead of taking them. TODAY (YYYY-MM-DD) overrides the date for testing; under DRY_RUN,
# DRY_RUN_LABELLED lists the issue numbers to treat as already carrying the label.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
LEDGER="${LEDGER:-deps.json}"
TODAY="${TODAY:-$(date -u +%F)}"
DRY_RUN="${DRY_RUN:-0}"
LABEL="hold-review-due"
# Job summary when run by Actions; plain stdout locally.
summ() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >> "${GITHUB_STEP_SUMMARY}"; else cat; fi; }

if [ "${DRY_RUN}" != 1 ]; then
  : "${GH_REPO:?set GH_REPO (owner/name)}"
  export GH_REPO
fi

run() { # print in dry-run, execute otherwise
  if [ "${DRY_RUN}" = 1 ]; then printf 'DRY_RUN:'; printf ' %q' "$@"; echo; else "$@"; fi
}

# dep, issue, reviewAfter, allowedVersions, tag, liftWhen -- joined on US (0x1f), not @tsv: @tsv
# escapes backslashes, which would double every one in a regex cap like /^n13\.0\./.
# Captured in a checked substitution first: inside `mapfile < <(jq ...)` a missing or malformed
# ledger would read as "no holds" and exit 0, the silent no-op this script exists to prevent.
rows="$(jq -r '.defaults | to_entries[] | select(.value.hold != null)
  | [.key, .value.hold.issue, .value.hold.reviewAfter, .value.hold.allowedVersions, (.value.tag // "-"), .value.hold.liftWhen]
  | map(tostring) | join("\u001f")' "${LEDGER}")" \
  || { echo "review-holds: could not read holds from ${LEDGER}" >&2; exit 1; }
HOLDS=()
[ -z "${rows}" ] || mapfile -t HOLDS <<<"${rows}"

if [ "${DRY_RUN}" != 1 ]; then
  run gh label create "${LABEL}" --color D93F0B \
    --description "A dependency hold in deps.json is past its reviewAfter date" --force >/dev/null
fi

# Issues with at least one due hold. The label is per issue, so it comes off an issue only when
# NONE of the holds pointing at it are due -- including when no hold points at it any more.
declare -A DUE_ISSUE=()
for row in ${HOLDS[@]+"${HOLDS[@]}"}; do
  IFS=$'\x1f' read -r _ issue review _ _ _ <<<"${row}"
  [[ "${TODAY}" < "${review}" ]] || DUE_ISSUE[${issue}]=1
done

{
  echo "### Dependency holds (${TODAY})"
  echo
  if [ "${#HOLDS[@]}" -eq 0 ]; then
    echo "No dependency holds."
  else
    echo "| dep | pinned | cap | issue | review after | status |"
    echo "|---|---|---|---|---|---|"
  fi
} | summ

overdue=0
for row in ${HOLDS[@]+"${HOLDS[@]}"}; do
  IFS=$'\x1f' read -r dep issue review allowed tag lift <<<"${row}"

  if [ "${DRY_RUN}" = 1 ]; then
    state=OPEN; labels=""; bodies=""
  else
    state="$(gh issue view "${issue}" --json state --jq .state)"
    labels="$(gh issue view "${issue}" --json labels --jq '.labels[].name')"
    bodies="$(gh api --paginate "repos/${GH_REPO}/issues/${issue}/comments" --jq '.[].body')"
  fi

  if [ "${state}" = CLOSED ]; then
    run gh issue reopen "${issue}" --comment "Reopened by the weekly hold review: \`deps.json\` still holds **${dep}** at \`${allowed}\` (pinned \`${tag}\`). This issue tracks that hold, so it closes when the hold is lifted -- remove \`.defaults[\"${dep}\"].hold\` and its \`renovate.json\` rule -- not before."
  fi

  if [[ "${TODAY}" < "${review}" ]]; then
    status="ok"
  else
    status="**review due**"; overdue=$((overdue+1))
    marker="<!-- hold-review:${dep}:${review} -->"
    if ! grep -qF "${marker}" <<<"${bodies}"; then
      run gh issue comment "${issue}" --body "${marker}
**Hold review due** for \`${dep}\` (review date ${review}).

- pinned: \`${tag}\`
- Renovate cap: \`${allowed}\`
- review when: ${lift}

Decide one of:
1. **Lift it** -- remove \`.defaults[\"${dep}\"].hold\` from \`deps.json\` and its \`allowedVersions\` rule from \`renovate.json\`, then close this issue.
2. **Keep it** -- set a new \`hold.reviewAfter\` in \`deps.json\` and note here why it stays.

The \`${LABEL}\` label stays until one of those lands. Nothing is changed automatically."
    fi
    grep -qxF "${LABEL}" <<<"${labels}" || run gh issue edit "${issue}" --add-label "${LABEL}"
    echo "::warning::dependency hold on ${dep} is past its review date (${review}) -- see issue #${issue}"
  fi
  echo "| ${dep} | \`${tag}\` | \`${allowed}\` | #${issue} | ${review} | ${status} |" | summ
done

# Clear the label from every issue (open or closed) that carries it but has no due hold: a hold
# whose date was moved, and one that was lifted -- whose issue no remaining hold points at, so
# the loop above never visits it.
if [ "${DRY_RUN}" = 1 ]; then
  labelled="${DRY_RUN_LABELLED:-}"
else
  labelled="$(gh issue list --label "${LABEL}" --state all --limit 1000 --json number --jq '.[].number')"
fi
for n in ${labelled}; do
  [ -n "${DUE_ISSUE[${n}]:-}" ] || run gh issue edit "${n}" --remove-label "${LABEL}"
done
echo "review-holds: ${#HOLDS[@]} hold(s), ${overdue} due for review"
