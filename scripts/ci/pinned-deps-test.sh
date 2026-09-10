#!/usr/bin/env bash
# Guard the dependency ledger's coverage: every pinned third-party version the build fetches
# must come FROM deps.json, so Renovate and check-updates.yml can offer a bump.
#
# The failure this prevents is silent. A hard-coded version in a download URL builds fine,
# passes every test, and simply never updates — it drifts until something breaks years later,
# and nothing in CI ever says so. Both known instances were found by eye, not by a check:
# patchelf sat hard-coded for the life of the repo, and the llvm-mingw toolchain added for
# win-arm64 nearly shipped the same way.
#
# Two rules:
#   1. every ledger key a build script references must exist in deps.json
#   2. no release-download URL in a build script may carry a literal version
#
# Run in CI (shellcheck.yml). Hermetic — reads files only, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${HERE}" || exit 1

# On Windows `python3` is often a Microsoft Store alias stub that sits on PATH but exits
# non-zero, so presence alone is not enough — probe for one that actually runs.
PYBIN=""
for _py in python3 python; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import sys' >/dev/null 2>&1; then
    PYBIN="${_py}"; break
  fi
done
[ -n "${PYBIN}" ] || { echo "ERROR: no working python3/python on PATH." >&2; exit 1; }

"${PYBIN}" - <<'PY'
import glob, json, os, re, sys

fails = []
def check(label, bad):
    if not bad:
        print(f"ok: {label}")
    else:
        fails.append(label)
        print(f"FAIL: {label}")
        for b in bad:
            print(f"     {b}")

ledger = json.load(open("deps.json", encoding="utf-8"))
keys = set(ledger.get("defaults", {}))

# Real build scripts only. The *-test.sh files drive the loader with fixture ledgers of their
# own invention (libfoo, libbar, ...), which are deliberately absent from deps.json.
files = [f for f in glob.glob("scripts/**/*.sh", recursive=True)
         if not os.path.basename(f).endswith("-test.sh")]

# --- rule 1: every referenced ledger key exists -------------------------------------------
ref = re.compile(r'\b(?:clone_dep|build_cmake_dep|dep_version|dep_source)\s+([a-z0-9][a-z0-9_-]*)')
bad = []
for f in files:
    # Strip comments first: this repo documents the loader in prose ("clone_dep clones into
    # ...", "dep_version yields ..."), which otherwise reads as a reference to a key named
    # 'clones' or 'yields'.
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        code = re.sub(r'#.*', '', line)
        for m in ref.finditer(code):
            k = m.group(1)
            if k not in keys and not k.startswith("$"):
                bad.append(f"{f}:{i}: references '{k}', which is not in deps.json .defaults")
check("every ledger key referenced by a build script exists", sorted(set(bad)))

# --- rule 2: no literal version in a release-download URL ---------------------------------
# A pinned fetch must interpolate a shell variable (in practice dep_version's result), so the
# version lives in deps.json where Renovate can see it.
url = re.compile(r'https?://[^\s"\']*releases/download/([^/\s"\']+)')
bad = []
for f in files:
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in url.finditer(line):
            ver = m.group(1)
            if "$" not in ver:
                bad.append(f"{f}:{i}: hard-coded version '{ver}' in a download URL — "
                           f"add it to deps.json and use \"$(dep_version <key>)\"")
check("no build script hard-codes a version in a download URL", bad)

print()
if fails:
    print(f"Failed: {len(fails)}")
    sys.exit(1)
print("Every pinned dependency is ledger-tracked.")
PY
