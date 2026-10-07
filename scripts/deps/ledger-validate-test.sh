#!/usr/bin/env bash
# Unit test for the dep ledger validator. Points LEDGER at temp fixtures and
# runs ledger-validate.sh, asserting exit status for valid/invalid ledgers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="${HERE}/ledger-validate.sh"
FIX="$(mktemp -d)"

pass=0; fail=0
check() { # <label> <got-exit> <want: 0=pass|nonzero=fail>
  if { [ "$2" -eq 0 ] && [ "$3" -eq 0 ]; } || { [ "$2" -ne 0 ] && [ "$3" -ne 0 ]; }; then
    echo "ok: $1"; pass=$((pass+1))
  else
    echo "FAIL: $1 -> got exit [$2] want [$3]"; fail=$((fail+1))
  fi
}

# VALID: defaults + a reasoned override, each with origin + exactly one ref.
cat > "${FIX}/valid.json" <<'JSON'
{
  "defaults": {
    "x265":   { "origin": "https://example.test/x265.git", "tag": "4.0" },
    "libfoo": { "origin": "https://example.test/foo.git",  "commit": "abc123" }
  },
  "overrides": {
    "8": { "x265": { "origin": "https://example.test/x265.git", "branch": "stable-8", "reason": "8.x caps libx265 at 3.x" } }
  }
}
JSON
LEDGER="${FIX}/valid.json" bash "${VALIDATE}" >/dev/null 2>&1
check "valid ledger passes" "$?" 0

# Entry missing origin.
cat > "${FIX}/no-origin.json" <<'JSON'
{ "defaults": { "x265": { "tag": "4.0" } } }
JSON
LEDGER="${FIX}/no-origin.json" bash "${VALIDATE}" >/dev/null 2>&1
check "missing origin fails" "$?" 1

# Entry with TWO ref keys.
cat > "${FIX}/two-refs.json" <<'JSON'
{ "defaults": { "x265": { "origin": "https://example.test/x265.git", "tag": "4.0", "branch": "dev" } } }
JSON
LEDGER="${FIX}/two-refs.json" bash "${VALIDATE}" >/dev/null 2>&1
check "two ref keys fails" "$?" 1

# Entry with ZERO ref keys.
cat > "${FIX}/zero-refs.json" <<'JSON'
{ "defaults": { "x265": { "origin": "https://example.test/x265.git" } } }
JSON
LEDGER="${FIX}/zero-refs.json" bash "${VALIDATE}" >/dev/null 2>&1
check "zero ref keys fails" "$?" 1

# Override missing reason.
cat > "${FIX}/no-reason.json" <<'JSON'
{ "defaults": {}, "overrides": { "8": { "x265": { "origin": "https://example.test/x265.git", "branch": "stable-8" } } } }
JSON
LEDGER="${FIX}/no-reason.json" bash "${VALIDATE}" >/dev/null 2>&1
check "override missing reason fails" "$?" 1

# VALID: platform-scoped override with known RIDs.
cat > "${FIX}/plat-ok.json" <<'JSON'
{ "defaults": { "x265": { "origin": "https://example.test/x265.git", "tag": "4.2" } },
  "overrides": { "9": { "x265": { "origin": "https://example.test/x265.git", "tag": "3.6", "reason": "arm64 neon", "platforms": ["linux-arm64", "osx-arm64"] } } } }
JSON
LEDGER="${FIX}/plat-ok.json" bash "${VALIDATE}" >/dev/null 2>&1
check "platform-scoped override passes" "$?" 0

# Override with an unknown RID in platforms.
cat > "${FIX}/plat-bad.json" <<'JSON'
{ "defaults": {}, "overrides": { "9": { "x265": { "origin": "https://example.test/x265.git", "tag": "3.6", "reason": "x", "platforms": ["linux-arm64", "sparc-64"] } } } }
JSON
LEDGER="${FIX}/plat-bad.json" bash "${VALIDATE}" >/dev/null 2>&1
check "unknown RID in platforms fails" "$?" 1

# Override with an empty platforms array.
cat > "${FIX}/plat-empty.json" <<'JSON'
{ "defaults": {}, "overrides": { "9": { "x265": { "origin": "https://example.test/x265.git", "tag": "3.6", "reason": "x", "platforms": [] } } } }
JSON
LEDGER="${FIX}/plat-empty.json" bash "${VALIDATE}" >/dev/null 2>&1
check "empty platforms array fails" "$?" 1

# Holds: a well-formed one passes (an overdue reviewAfter included -- the reminder handles it);
# each malformed field, an extra key, and a hold placed in .overrides fail.
hold_case() { # <label> <want> <hold-json> [override]
  if [ "${4:-}" = override ]; then
    printf '{ "defaults": {}, "overrides": { "9": { "foo": { "origin": "https://example.test/foo.git", "tag": "1.0", "reason": "x", "hold": %s } } } }\n' "$3" > "${FIX}/hold.json"
  else
    printf '{ "defaults": { "foo": { "origin": "https://example.test/foo.git", "tag": "1.0", "hold": %s } } }\n' "$3" > "${FIX}/hold.json"
  fi
  LEDGER="${FIX}/hold.json" bash "${VALIDATE}" >/dev/null 2>&1
  check "$1" "$?" "$2"
}
H_OK='"allowedVersions": "<2.0.0", "issue": 7, "liftWhen": "upstream fixes it"'
hold_case "well-formed hold passes"            0 "{ ${H_OK}, \"reviewAfter\": \"2027-04-07\" }"
hold_case "overdue reviewAfter still passes"   0 "{ ${H_OK}, \"reviewAfter\": \"2020-01-01\" }"
hold_case "hold that is not an object fails"   1 '"<2.0.0"'
hold_case "hold missing allowedVersions fails" 1 '{ "issue": 7, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
hold_case "blank allowedVersions fails"        1 '{ "allowedVersions": " ", "issue": 7, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
hold_case "string issue fails"                 1 '{ "allowedVersions": "<2", "issue": "7", "reviewAfter": "2027-04-07", "liftWhen": "x" }'
hold_case "zero issue fails"                   1 '{ "allowedVersions": "<2", "issue": 0, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
hold_case "fractional issue fails"             1 '{ "allowedVersions": "<2", "issue": 7.5, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
hold_case "non-ISO reviewAfter fails"          1 "{ ${H_OK}, \"reviewAfter\": \"04/07/2027\" }"
hold_case "impossible date fails"              1 "{ ${H_OK}, \"reviewAfter\": \"2027-02-30\" }"
hold_case "missing reviewAfter fails"          1 "{ ${H_OK} }"
hold_case "blank liftWhen fails"               1 '{ "allowedVersions": "<2", "issue": 7, "reviewAfter": "2027-04-07", "liftWhen": "" }'
hold_case "unknown hold key fails"             1 "{ ${H_OK}, \"reviewAfter\": \"2027-04-07\", \"owner\": \"me\" }"
hold_case "hold in .overrides fails"           1 "{ ${H_OK}, \"reviewAfter\": \"2027-04-07\" }" override

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
