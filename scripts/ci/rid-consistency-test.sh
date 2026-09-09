#!/usr/bin/env bash
# Guard against the "added a RID, missed a site" defect class.
#
# A RID is enumerated in a dozen places — four workflow matrices, the coverage-matrix
# generator (twice: a bash array and an embedded Python list), the ledger validator, the
# build.sh usage comment, and a case arm in one of scripts/platform/*.sh. Adding one and
# missing a site does not fail loudly; it produces a job with no runner, a matrix column of
# blanks, or a build with no platform configuration. That has bitten this repo repeatedly:
# test.sh not passing $RID to android.sh, the android test scripts hardcoding aarch64, and
# test.yml gating the Alpine bootstrap on a literal RID were all this shape.
#
# build.yml's matrix is the SOURCE OF TRUTH here: it defines what this repo builds. Every
# other list is checked against it.
#
# Run in CI (shellcheck.yml, "Dependency ledger checks" step). Hermetic — no network, no
# toolchain, no sourcing of the build scripts.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${HERE}" || exit 1

# Resolve an interpreter that actually RUNS: on Windows `python3` is often a Microsoft
# Store alias stub that sits on PATH but exits non-zero, so presence alone is not enough.
PYBIN=""
for _py in python3 python; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import sys' >/dev/null 2>&1; then
    PYBIN="${_py}"; break
  fi
done
[ -n "${PYBIN}" ] || { echo "ERROR: no working python3/python on PATH." >&2; exit 1; }

"${PYBIN}" - <<'PY'
import re, sys, fnmatch
try:
    import yaml
except ImportError:
    print("SKIP: PyYAML unavailable; workflow checks skipped")
    sys.exit(0)

fails = []
def check(label, got, want):
    if got == want:
        print(f"ok: {label}")
    else:
        missing, extra = sorted(set(want) - set(got)), sorted(set(got) - set(want))
        fails.append(f"{label}\n     missing: {missing or '-'}\n     extra:   {extra or '-'}")
        print(f"FAIL: {label}\n     missing: {missing or '-'}\n     extra:   {extra or '-'}")

def wf(path):
    return yaml.safe_load(open(path))

# ---- canonical set: what build.yml builds -----------------------------------------------
build = wf(".github/workflows/build.yml")["jobs"]["build"]["strategy"]["matrix"]
CANON = set(build["rid"])
print(f"canonical RIDs (build.yml): {len(CANON)}")

# ---- every RID in every matrix needs an include entry naming a runner ---------------------
for f, job in (("build", "build"), ("test", "test"), ("test-mobile", "test")):
    m = wf(f".github/workflows/{f}.yml")["jobs"][job]["strategy"]["matrix"]
    inc = {e["rid"]: e for e in m.get("include", [])}
    check(f"{f}.yml: every matrix RID has an include entry", set(inc), set(m["rid"]))
    norunner = sorted(r for r, e in inc.items() if not e.get("runner"))
    check(f"{f}.yml: every include entry names a runner", norunner, [])

# ---- test coverage: build == test + test-mobile -------------------------------------------
t = set(wf(".github/workflows/test.yml")["jobs"]["test"]["strategy"]["matrix"]["rid"])
tm = set(wf(".github/workflows/test-mobile.yml")["jobs"]["test"]["strategy"]["matrix"]["rid"])
check("every built RID is tested (build == test + test-mobile)", t | tm, CANON)
check("test and test-mobile do not overlap", sorted(t & tm), [])

# ---- publish coverage: everything except the iOS slices, which publish-ios handles ---------
rel = wf(".github/workflows/release.yml")
pub = set(rel["jobs"]["publish"]["strategy"]["matrix"]["rid"])
check("release publishes every built RID except the iOS slices",
      pub, {r for r in CANON if not r.startswith("ios-")})

# ---- gen-matrix.sh: bash array AND the embedded Python list --------------------------------
gm = open("scripts/gen-matrix.sh").read()
bash_rids = set(re.search(r'^RIDS=\(([^)]*)\)', gm, re.M).group(1).split())
check("gen-matrix.sh bash RIDS array", bash_rids, CANON)
py_rids = set(re.findall(r'"([a-z0-9-]+)"',
              re.search(r'^RIDS = \[(.*?)\]', gm, re.M | re.S).group(1)))
check("gen-matrix.sh embedded Python RIDS list", py_rids, CANON)

# ---- ledger validator's known-RID list -----------------------------------------------------
lv = open("scripts/deps/ledger-validate.sh").read()
lv_rids = set(re.findall(r'"([a-z0-9-]+)"', re.search(r'\[([^]]*)\] as \$rids', lv, re.S).group(1)))
check("ledger-validate.sh known-RID list", lv_rids, CANON)

# ---- build.sh usage comment ----------------------------------------------------------------
bs = open("scripts/build.sh").read()
check("build.sh usage comment lists every RID",
      sorted(r for r in CANON if r not in bs), [])

# ---- every RID matches a real case arm in its platform script -------------------------------
FAMILY = {"linux-": "linux", "win-": "windows", "osx-": "apple",
          "ios-": "apple", "android-": "android"}
def family_of(rid):
    for pre, fam in FAMILY.items():
        if rid.startswith(pre):
            return fam
    return None

unmatched, nodefault = [], []
for fam in sorted(set(FAMILY.values())):
    src = open(f"scripts/platform/{fam}.sh").read()
    # Top-level case arms only: exactly two leading spaces. Nested case statements (e.g.
    # android.sh's per-arch triple lookup) are indented deeper, so they cannot contribute
    # arms — nor a '*)' that would falsely satisfy the rejecting-default check below.
    # The arm may carry its body on the same line ("*) echo ...; exit 1 ;;"), so do not
    # anchor on end-of-line.
    arms = []
    for m in re.finditer(r'^\s{2}([^\s()]+(?:\|[^\s()]+)*)\)', src, re.M):
        arms.extend(a.strip() for a in m.group(1).split("|"))
    if "*" not in arms:
        nodefault.append(fam)
    pats = [a for a in arms if a != "*"]
    for rid in sorted(r for r in CANON if family_of(r) == fam):
        if not any(fnmatch.fnmatch(rid, p) for p in pats):
            unmatched.append(f"{rid} (no arm in platform/{fam}.sh)")

check("every RID matches a case arm in its platform script", unmatched, [])
check("every platform script has a rejecting '*)' default", nodefault, [])

print()
if fails:
    print(f"Failed: {len(fails)}")
    sys.exit(1)
print("All RID enumerations agree.")
PY
