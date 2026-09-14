#!/usr/bin/env bash
set -euo pipefail
# Assert the CI matrices agree with each other.
#
# Adding a RID means touching three matrices (build.yml, test.yml, test-mobile.yml) plus a
# runner mapping. Miss one and nothing fails loudly: a RID with no test entry is simply BUILT
# AND NEVER TESTED, and a stale entry in a test matrix looks for an artifact that was never
# produced and fails with a confusing download error instead of naming the real problem. Both
# are silent-by-default, which is why they get checked here rather than noticed later.
#
# Checks:
#   1. every RID in the build matrix has a runner mapping
#   2. no `include:` entry names a RID absent from the build list -- a GitHub matrix `include`
#      whose keys do not match an existing combination ADDS one, so a typo silently creates
#      half-configured jobs rather than erroring
#   3. every built RID is tested by exactly one of the two test workflows
#   4. no test matrix references a RID that is not built
#
# Run: bash scripts/ci/matrix-consistency-test.sh
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

command -v python3 >/dev/null 2>&1 || { echo "matrix-consistency: python3 required" >&2; exit 2; }

python3 - <<'PY'
import io, sys
try:
    import yaml
except ImportError:
    print("matrix-consistency: PyYAML required", file=sys.stderr); sys.exit(2)

def load(p):
    return yaml.safe_load(io.open(p, encoding="utf-8"))

fail = []

b = load(".github/workflows/build.yml")["jobs"]["build"]["strategy"]["matrix"]
build = list(b["rid"])
inc = [e["rid"] for e in b.get("include", []) if "rid" in e]

# 1 + 2: runner mappings
missing = [r for r in build if r not in inc]
if missing:
    fail.append("build RIDs with no runner mapping: %s" % ", ".join(missing))
phantom = [r for r in inc if r not in build]
if phantom:
    fail.append("include entries for RIDs not in the build list (these ADD jobs): %s" % ", ".join(phantom))

# 3 + 4: test coverage
t = set(load(".github/workflows/test.yml")["jobs"]["test"]["strategy"]["matrix"]["rid"])
m = set(load(".github/workflows/test-mobile.yml")["jobs"]["test"]["strategy"]["matrix"]["rid"])
bs = set(build)

untested = sorted(bs - t - m)
if untested:
    fail.append("RIDs built but NEVER tested: %s" % ", ".join(untested))
orphan = sorted((t | m) - bs)
if orphan:
    fail.append("RIDs in a test matrix but never built: %s" % ", ".join(orphan))
both = sorted(t & m)
if both:
    fail.append("RIDs tested by BOTH workflows (duplicated runner cost): %s" % ", ".join(both))

if fail:
    for f in fail:
        print("matrix-consistency: %s" % f, file=sys.stderr)
    sys.exit(1)

print("matrix-consistency: OK - %d RIDs built, %d desktop-tested, %d mobile-tested, no gaps"
      % (len(build), len(t), len(m)))
PY
