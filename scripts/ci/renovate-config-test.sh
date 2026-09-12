#!/usr/bin/env bash
# Validate renovate.json with Renovate's own config validator, at the EXACT version the
# workflow pins.
#
# Why: an invalid option is not a warning — Renovate refuses to run, which silently stops
# every dependency bump. That is indistinguishable from "nothing to update", and this repo
# has already lost months of updates to a Renovate that could not start. A committed
# `"issue": 18` on a packageRule (not a Renovate option) reproduced exactly that, and
# renovate-coverage-test.sh passed anyway because it checks ledger coverage, not config
# validity. The two tests are complementary: coverage says every dep is claimed by a
# manager, this says Renovate will actually load the file.
#
# The version is read from renovate.yml so there is one source of truth for the pin.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

VER="$(sed -n 's/^[[:space:]]*renovate-version:[[:space:]]*['"'"'"]\{0,1\}\([0-9][0-9.]*\)['"'"'"]\{0,1\}[[:space:]]*$/\1/p' \
        .github/workflows/renovate.yml | head -1)"
if [ -z "${VER}" ]; then
  echo "renovate-config-test: could not read renovate-version from .github/workflows/renovate.yml" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "renovate-config-test: npx not available — skipping (install Node to run this locally)" >&2
  exit 0
fi

echo "renovate-config-test: validating renovate.json against renovate@${VER}"
out="$(npx --yes --package "renovate@${VER}" renovate-config-validator renovate.json 2>&1)"
rc=$?
if [ "${rc}" -ne 0 ] || printf '%s' "${out}" | grep -q "Found errors in configuration"; then
  printf '%s\n' "${out}" | grep -v '^npm warn' >&2
  echo "renovate-config-test: renovate.json is INVALID for renovate@${VER} — Renovate would refuse to run" >&2
  exit 1
fi
echo "ok: renovate.json validates against renovate@${VER}"
