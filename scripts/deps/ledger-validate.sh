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
echo "ledger-validate: OK"
