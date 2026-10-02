#!/usr/bin/env bash
# Assert every build/test container image is pinned tag@sha256 AND tracked by Renovate.
#
# Why this exists (issue #26): the musl, glibc and armhf builds run INSIDE these images, so the
# image is the toolchain. alpine:latest and an untagged manylinux ref let GCC/musl/glibc change
# between two runs of the same commit, with no diff to point at. Pinning fixes that only while
# every ref stays pinned -- one new `container: foo:latest`, or a ref reshaped so the Renovate
# regex no longer matches it, and the float (or a silently frozen pin) is back with every other
# gate green. This catches both.
#
# Image refs are the non-comment `container:` values and `_img="..."` assignments in build.yml and
# test.yml. `container: ${{ ... }}` is the job-level indirection onto the matrix value and is not
# itself an image. The Renovate regex is read FROM renovate.json, so this tests the config that
# actually ships.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# shellcheck source=scripts/lib.sh  # wrappers + resolve_python; nothing runs on source
. "$(pwd)/scripts/lib.sh"
PYBIN="$(resolve_python)" || exit 1

"${PYBIN}" - <<'PY'
import json, re, sys

FILES = [".github/workflows/build.yml", ".github/workflows/test.yml"]
cfg = json.load(open("renovate.json", encoding="utf-8"))

def file_rx(pat):  # renovate's "/regex/" managerFilePatterns form
    return re.compile(pat[1:-1] if pat.startswith("/") and pat.endswith("/") else pat)

managers = []
for m in cfg.get("customManagers", []):
    if m.get("datasourceTemplate") != "docker":
        continue
    fpats = [file_rx(p) for p in m.get("managerFilePatterns", [])]
    if all(any(p.search(f) for p in fpats) for f in FILES):
        managers += [re.compile(s.replace("(?<", "(?P<")) for s in m.get("matchStrings", [])]
if not managers:
    sys.exit("image-pins: no docker custom manager in renovate.json covers " + " and ".join(FILES))

REF = re.compile(r'^\s*(?:-\s+)?(?:container:\s*(?P<c>\S+)|.*\b_img="(?P<i>[^"]+)")')
PINNED = re.compile(r'^[^\s@:]+(?:/[^\s@:]+)*:[A-Za-z0-9][A-Za-z0-9._-]*@sha256:[a-f0-9]{64}$')

problems, seen = [], 0
for path in FILES:
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        m = REF.match(line)
        if not m:
            continue
        ref = m.group("c") or m.group("i")
        if ref.startswith("${{"):
            continue
        seen += 1
        where = f"{path}:{n}: {ref}"
        if not PINNED.match(ref):
            problems.append(f"not pinned tag@sha256:<64 hex>  -> {where}")
            continue
        hit = next((rx.search(ref) for rx in managers if rx.search(ref)), None)
        if not hit or hit.group(0) != ref:
            problems.append(f"not (fully) matched by the Renovate image manager -> {where}")

if seen == 0:
    problems.append("found no image refs at all -- the extraction pattern no longer fits the workflows")

if problems:
    for p in problems:
        print("image-pins: " + p, file=sys.stderr)
    sys.exit(1)
print(f"ok: all {seen} build/test image refs are pinned tag@sha256 and tracked by Renovate")
PY
