#!/usr/bin/env bash
# Assert every dependency in deps.json's .defaults is tracked by exactly one Renovate
# custom manager.
#
# Why this exists: the managers match deps.json with regexes that require the ledger's
# fields to stay contiguous and in order (origin, tag, releasesUrl, releasesStyle, or
# origin, commit, digestBranch). Reordering keys or inserting a field between them is
# harmless JSON and passes every other gate, but it silently drops the dep out of
# Renovate — the exact failure that left libmp3lame on 3.100 and libgsm on 1.0.22 while
# newer releases shipped. Adding a dep without wiring it up fails here too.
#
# The regexes are read FROM renovate.json rather than duplicated, so this tests the
# config that actually ships.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# Resolve an interpreter that actually RUNS: on Windows `python3` is often a Microsoft
# Store alias stub that sits on PATH but exits non-zero, so presence alone is not enough.
# Same probe as gen-matrix.sh.
PYBIN=""
for _py in python3 python; do
  if command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c 'import sys' >/dev/null 2>&1; then
    PYBIN="${_py}"; break
  fi
done
[ -n "${PYBIN}" ] || { echo "renovate-coverage-test: no working python3/python on PATH." >&2; exit 1; }

"${PYBIN}" - <<'PY'
import json, re, sys

deps_raw = open("deps.json", encoding="utf-8").read()
deps = json.loads(deps_raw)
cfg  = json.load(open("renovate.json", encoding="utf-8"))

defaults = deps["defaults"]
managers = [m for m in cfg.get("customManagers", []) if m.get("customType") == "regex"]

# Renovate's "recursive" strategy: apply matchStrings[0], then run the next expression
# against what it captured. Mirror that so the scoping (defaults only, never overrides)
# is exercised here the same way Renovate exercises it.
def matches(manager):
    ms = manager.get("matchStrings", [])
    if not ms:
        return []
    scopes = [deps_raw]
    for i, pat in enumerate(ms):
        rx = re.compile(pat.replace("(?<", "(?P<"))
        nxt = []
        for s in scopes:
            for m in rx.finditer(s):
                nxt.append(m.group(1) if (i < len(ms) - 1 and m.groups()) else m.group(0))
        scopes = nxt
    return scopes

owner = {}
problems = []
for man in managers:
    if man.get("depNameTemplate") == "FFmpeg":
        continue                      # tracks the .ffmpeg array, not a defaults entry
    for hit in matches(man):
        m = re.search(r'"(?P<dep>[A-Za-z0-9._-]+)"\s*:\s*\{', hit)
        name = m.group("dep") if m else None
        if name is None:
            m = re.search(r'"origin"\s*:\s*"(?P<o>[^"]+)"', hit)
            if m:
                name = next((k for k, v in defaults.items() if v.get("origin") == m.group("o")), None)
        if name is None:
            problems.append(f"manager matched text it could not attribute to a dep: {hit[:80]!r}")
            continue
        owner.setdefault(name, []).append(man.get("datasourceTemplate", "?"))

untracked = sorted(set(defaults) - set(owner))
multi     = sorted(k for k, v in owner.items() if len(v) > 1)
foreign   = sorted(set(owner) - set(defaults))

if untracked:
    problems.append("NOT tracked by any Renovate manager: " + ", ".join(untracked))
for k in multi:
    problems.append(f"{k} matched by {len(owner[k])} managers ({', '.join(owner[k])}) — it would be proposed twice")
if foreign:
    problems.append("matched outside .defaults (overrides must never be touched): " + ", ".join(foreign))

if problems:
    for p in problems:
        print("renovate-coverage: " + p, file=sys.stderr)
    sys.exit(1)

print(f"ok: all {len(defaults)} ledger deps tracked by exactly one Renovate manager")
PY
