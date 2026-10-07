#!/usr/bin/env bash
# Dependency holds: deps.json and renovate.json must agree, and the pin must satisfy its own cap.
#
# A hold is split across two files on purpose. The CAP is a renovate.json packageRule
# (allowedVersions), because that is what Renovate obeys. The WHY / WHEN is a `hold` record in
# deps.json (.defaults.<dep>.hold: allowedVersions, issue, reviewAfter, liftWhen), because
# metadata keys on a packageRule make Renovate refuse to start (renovate-config-test.sh), and
# check-updates.yml reads the record to raise the review on the issue. Two files means two ways
# to drift, each of which turns a hold into something nobody revisits or nothing enforces:
#   - a record with no rule: the review reminder fires, but Renovate was never capped;
#   - a rule with no record: Renovate is capped forever and nothing ever asks why;
#   - a rule with extra match conditions, or a second rule for the same package, can narrow or
#     contradict the cap without either file looking wrong;
#   - a pin outside its own cap (an accidental mbedTLS 4 pin) passes everything else.
# So: every ledger hold has EXACTLY ONE renovate rule constraining its origin, unconditional
# (matchPackageNames == [origin], nothing else to match on) with the identical allowedVersions;
# every allowedVersions rule that touches a ledger dep is some hold's rule; and the pinned tag
# satisfies the cap (and a regex `versioning`, when the rule sets one).
#
# Runs fixture cases first, then the real files. Shape (types, dates) is ledger-validate.sh's job.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "holds-test: python3 required" >&2; exit 2; }

check_holds() { # <ledger> <renovate.json>  -> exit 0 if consistent, prints problems
  python3 - "$1" "$2" <<'PY'
import json, re, sys

ledger = json.load(open(sys.argv[1]))
rules = json.load(open(sys.argv[2])).get("packageRules", [])
defaults = ledger.get("defaults", {})
entries = list(defaults.items()) + [(k, v) for o in ledger.get("overrides", {}).values() for k, v in o.items()]
origins = {v.get("origin") for _, v in entries if v.get("origin")}
names = {k for k, _ in entries}
problems = []

def vtuple(tag):
    m = re.match(r"^[^0-9]*([0-9]+(?:\.[0-9]+)*)", tag)
    return tuple(int(x) for x in m.group(1).split(".")) if m else None

def cmp(a, b):
    n = max(len(a), len(b)); a += (0,) * (n - len(a)); b += (0,) * (n - len(b))
    return (a > b) - (a < b)

def satisfies(tag, constraint):
    """Renovate allowedVersions: a /regex/ against the raw tag, or numeric comparators.
    Anything else is rejected rather than guessed at -- extend this when a hold needs more."""
    if len(constraint) > 1 and constraint.startswith("/") and constraint.endswith("/"):
        return re.search(constraint[1:-1], tag) is not None, None
    v = vtuple(tag)
    if v is None:
        return False, f"tag {tag!r} has no numeric version to compare"
    parts = [p for p in re.split(r"[,\s]+", constraint.strip()) if p]
    for p in parts:
        m = re.fullmatch(r"(<=|>=|<|>|=)v?([0-9]+(?:\.[0-9]+)*)", p)
        if not m:
            return False, f"unsupported allowedVersions syntax {constraint!r} (holds-test understands /regex/ and <,<=,>,>=,= comparators)"
        c = cmp(v, tuple(int(x) for x in m.group(2).split(".")))
        if not {"<": c < 0, "<=": c <= 0, ">": c > 0, ">=": c >= 0, "=": c == 0}[m.group(1)]:
            return False, None
    return True, None

def touches(rule):
    return (set(rule.get("matchPackageNames", [])) & origins) or (set(rule.get("matchDepNames", [])) & names)

hold_rules = set()
for dep, e in defaults.items():
    h = e.get("hold")
    if not isinstance(h, dict):
        continue
    origin, want = e.get("origin"), h.get("allowedVersions")
    capping = [i for i, r in enumerate(rules) if "allowedVersions" in r and
               (origin in r.get("matchPackageNames", []) or dep in r.get("matchDepNames", []))]
    if len(capping) != 1:
        problems.append(f"{dep}: hold needs exactly one renovate allowedVersions rule for {origin}, found {len(capping)}")
        continue
    i = capping[0]; r = rules[i]; hold_rules.add(i)
    extra = set(r) - {"description", "matchPackageNames", "allowedVersions", "versioning"}
    if r.get("matchPackageNames") != [origin] or extra:
        problems.append(f"{dep}: its renovate rule must be unconditional -- matchPackageNames exactly [{origin}] and no other match keys (has {sorted(extra) or r.get('matchPackageNames')})")
    if r.get("allowedVersions") != want:
        problems.append(f"{dep}: deps.json hold allows {want!r} but renovate.json allows {r.get('allowedVersions')!r}")
    tag = e.get("tag")
    if tag is None:
        problems.append(f"{dep}: a hold needs a tag pin to check against the cap")
        continue
    ok, why = satisfies(tag, want or "")
    if why:
        problems.append(f"{dep}: {why}")
    elif not ok:
        problems.append(f"{dep}: pinned tag {tag} is OUTSIDE its own hold {want!r}")
    ver = r.get("versioning", "")
    if ver.startswith("regex:"):
        pat = re.sub(r"\(\?<", "(?P<", ver[len("regex:"):])
        if not re.fullmatch(pat, tag):
            problems.append(f"{dep}: pinned tag {tag} does not match the rule's versioning {ver!r}, so Renovate cannot order it")

for i, r in enumerate(rules):
    if "allowedVersions" in r and i not in hold_rules and touches(r):
        problems.append(f"renovate.json packageRules[{i}] caps a ledger dep ({sorted(touches(r))}) with no deps.json hold record (add .defaults.<dep>.hold with issue/reviewAfter/liftWhen)")

for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
PY
}

FIX="$(mktemp -d)"; trap 'rm -rf "${FIX}"' EXIT
pass=0; fail=0
case_() { # <label> <want 0|1> <ledger-json> <rules-json>
  printf '%s\n' "$3" > "${FIX}/deps.json"; printf '{ "packageRules": %s }\n' "$4" > "${FIX}/renovate.json"
  check_holds "${FIX}/deps.json" "${FIX}/renovate.json" > "${FIX}/out" 2>&1; local got=$?
  if { [ "$2" -eq 0 ] && [ "${got}" -eq 0 ]; } || { [ "$2" -ne 0 ] && [ "${got}" -ne 0 ]; }; then
    echo "ok: $1"; pass=$((pass+1))
  else
    echo "FAIL: $1 -> got exit ${got}, want ${2}"; sed 's/^/    /' "${FIX}/out"; fail=$((fail+1))
  fi
}
O='https://example.test/nvh.git'
HOLD='"hold": { "allowedVersions": "/^n13\\.0\\./", "issue": 1, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
RANGE='"hold": { "allowedVersions": "<4.0.0", "issue": 1, "reviewAfter": "2027-04-07", "liftWhen": "x" }'
VER='"versioning": "regex:^n(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)\\.(?<build>\\d+)$"'
RULE="[ { \"matchPackageNames\": [\"${O}\"], ${VER}, \"allowedVersions\": \"/^n13\\\\.0\\\\./\" } ]"
led() { printf '{ "defaults": { "nvh": { "origin": "%s", "tag": "%s", %s } } }' "${O}" "$1" "$2"; }

case_ "regex hold with matching rule passes"        0 "$(led n13.0.19.1 "${HOLD}")" "${RULE}"
case_ "pin outside regex hold fails"                1 "$(led n13.1.15.0 "${HOLD}")" "${RULE}"
case_ "hold with no rule fails"                     1 "$(led n13.0.19.1 "${HOLD}")" '[]'
case_ "rule with no hold fails"                     1 "$(led n13.0.19.1 '"datasource": "x"')" "${RULE}"
case_ "rule by depName with no hold fails"          1 "$(led n13.0.19.1 '"datasource": "x"')" '[ { "matchDepNames": ["nvh"], "allowedVersions": "<14" } ]'
case_ "mismatched constraint fails"                 1 "$(led n13.0.19.1 "${HOLD}")" "[ { \"matchPackageNames\": [\"${O}\"], \"allowedVersions\": \"/^n13\\\\./\" } ]"
case_ "conditional rule fails"                      1 "$(led n13.0.19.1 "${HOLD}")" "[ { \"matchPackageNames\": [\"${O}\"], \"matchCurrentVersion\": \"/^n13/\", \"allowedVersions\": \"/^n13\\\\.0\\\\./\" } ]"
case_ "second capping rule fails"                   1 "$(led n13.0.19.1 "${HOLD}")" "[ { \"matchPackageNames\": [\"${O}\"], \"allowedVersions\": \"/^n13\\\\.0\\\\./\" }, { \"matchPackageNames\": [\"${O}\", \"https://other\"], \"allowedVersions\": \"<99\" } ]"
case_ "range hold, pin inside, passes"              0 "$(led v3.6.7 "${RANGE}")" "[ { \"matchPackageNames\": [\"${O}\"], \"allowedVersions\": \"<4.0.0\" } ]"
case_ "range hold, pin outside (4.0.0), fails"      1 "$(led v4.0.0 "${RANGE}")" "[ { \"matchPackageNames\": [\"${O}\"], \"allowedVersions\": \"<4.0.0\" } ]"
case_ "pin not matching regex versioning fails"     1 "$(led n13.0.19 "${HOLD}")" "${RULE}"
case_ "unrelated allowedVersions rule is ignored"   0 "$(led n13.0.19.1 "${HOLD}")" "[ { \"matchPackageNames\": [\"${O}\"], ${VER}, \"allowedVersions\": \"/^n13\\\\.0\\\\./\" }, { \"matchDepNames\": [\"alpine\"], \"allowedVersions\": \"/^3/\" } ]"

# The nv-codec rule's versioning must order the FOURTH component: under the default
# semver-coerced scheme n13.0.19.1 and n13.0.19.2 both coerce to 13.0.19, so a build-number
# release would never be offered. Read the real rule and prove 19.2 > 19.1 under it.
if python3 - renovate.json <<'PY'
import json, re, sys
r = [r for r in json.load(open(sys.argv[1]))["packageRules"]
     if r.get("matchPackageNames") == ["https://github.com/FFmpeg/nv-codec-headers.git"]][0]
pat = re.compile(re.sub(r"\(\?<", "(?P<", r["versioning"][len("regex:"):]))
key = lambda t: tuple(int(pat.fullmatch(t).group(g)) for g in ("major", "minor", "patch", "build"))
sys.exit(0 if key("n13.0.19.2") > key("n13.0.19.1") and re.search(r["allowedVersions"][1:-1], "n13.0.19.2") else 1)
PY
then echo "ok: nv-codec versioning orders the fourth component (n13.0.19.2 > n13.0.19.1)"; pass=$((pass+1))
else echo "FAIL: nv-codec versioning does not order n13.0.19.2 above n13.0.19.1"; fail=$((fail+1)); fi

echo "holds-test: checking deps.json against renovate.json"
if check_holds deps.json renovate.json; then
  echo "ok: every hold has exactly one unconditional rule, constraints agree, pins satisfy their caps"; pass=$((pass+1))
else
  echo "FAIL: deps.json holds and renovate.json disagree (above)"; fail=$((fail+1))
fi
echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
