#!/usr/bin/env bash
# Assert every dependency in deps.json's .defaults is tracked by exactly one Renovate
# custom manager, by running the SAME JSONata queries Renovate runs.
#
# Why this exists: a dep that no manager claims silently stops getting updates -- the exact
# failure that once left libmp3lame on 3.100 and libgsm on 1.0.22 while newer releases
# shipped. Adding a dep without the key that opts it in (`datasource` for a tag pin,
# `releasesUrl` for a tarball, `digestBranch` for a commit pin) fails here. The queries are
# read FROM renovate.json rather than duplicated, so this tests the config that actually ships,
# and they are evaluated with the jsonata library Renovate itself uses.
#
# History: the managers used to be regexes over the ledger TEXT, which required each entry's
# keys to stay contiguous and in order; this test then mirrored Renovate's recursive regex
# strategy. With JSONata managers that whole class of failure is gone (the query sees the parsed
# document), so the test is now about coverage and result shape, not key order.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "renovate-coverage-test: node/npm not available — skipping (install Node to run this locally)" >&2
  exit 0
fi

# jsonata is installed into a scratch prefix, never into the repo: a node_modules/ here would
# be a stray untracked tree, and `npx -p` puts the package on PATH but not on require's search
# path. Renovate 44 depends on jsonata ^2.x; pin the major so the test runs the same engine.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
if ! npm install --prefix "${tmp}" --no-save --no-audit --no-fund --silent jsonata@2 >/dev/null 2>&1; then
  echo "renovate-coverage-test: could not install jsonata@2 (offline?) — cannot evaluate the managers" >&2
  exit 1
fi

NODE_PATH="${tmp}/node_modules" node - <<'JS'
const fs = require("node:fs");
const jsonata = require("jsonata");

const deps = JSON.parse(fs.readFileSync("deps.json", "utf8"));
const cfg = JSON.parse(fs.readFileSync("renovate.json", "utf8"));
const defaults = deps.defaults;

const problems = [];
const owner = {};          // depName -> [manager label]
let ffmpegSeen = 0;

const managers = (cfg.customManagers || []).filter((m) => m.customType === "jsonata");
if (managers.length === 0) problems.push("renovate.json has no customType=jsonata managers at all");

// Renovate's jsonata manager ALSO accepts the regex managers' file pattern shape; make sure
// every JSONata manager here is aimed at the ledger, since that is what this test is about.
for (const m of managers) {
  const pats = m.managerFilePatterns || [];
  if (!pats.some((p) => /deps\\\.json/.test(p))) {
    problems.push(`jsonata manager "${(m.description || "").slice(0, 40)}..." does not target deps.json`);
  }
  if (m.fileFormat !== "json") problems.push(`jsonata manager targeting deps.json must have fileFormat json, has ${m.fileFormat}`);
}

(async () => {
  for (const m of managers) {
    const label = m.datasourceTemplate || "?";
    for (const q of m.matchStrings || []) {
      let result;
      try {
        result = await jsonata(q).evaluate(deps);
      } catch (e) {
        problems.push(`query failed to evaluate (${label}): ${e.message}`);
        continue;
      }
      const items = result === undefined ? [] : Array.isArray(result) ? result : [result];
      for (const r of items) {
        if (r === undefined || r === null) continue;
        // The fields Renovate requires of a jsonata result, allowing for *Template fallbacks.
        const name = r.depName ?? r.packageName ?? m.depNameTemplate ?? m.packageNameTemplate;
        if (!name) { problems.push(`(${label}) result has no depName/packageName: ${JSON.stringify(r)}`); continue; }
        if (!(r.datasource || m.datasourceTemplate)) problems.push(`(${label}) ${name}: no datasource`);
        if (r.currentValue === undefined && r.currentDigest === undefined) problems.push(`(${label}) ${name}: neither currentValue nor currentDigest`);
        if (m.depNameTemplate === "FFmpeg") { ffmpegSeen++; continue; }   // tracks .ffmpeg, not a defaults entry
        if (!(name in defaults)) { problems.push(`(${label}) matched "${name}", which is not a .defaults entry (overrides must never be touched)`); continue; }
        // Tarball deps: an entry the $lookup table does not know yields no extractVersion, and
        // Renovate would then take EVERY link on the listing as a candidate version.
        if (label === "custom.tarball-listing") {
          if (!r.extractVersion) problems.push(`${name}: tarball dep has no extractVersion — add it to the $lookup table in renovate.json`);
          if (!r.registryUrl) problems.push(`${name}: tarball dep has no registryUrl`);
        }
        // Commit pins must carry both halves or the git-refs datasource cannot bump the digest.
        if (label === "git-refs" && !(r.currentDigest && r.currentValue)) problems.push(`${name}: commit pin needs currentDigest (commit) AND currentValue (digestBranch)`);
        (owner[name] ||= []).push(label);
      }
    }
  }

  const untracked = Object.keys(defaults).filter((k) => !(k in owner)).sort();
  const multi = Object.keys(owner).filter((k) => owner[k].length > 1).sort();
  if (untracked.length) problems.push("NOT tracked by any Renovate manager: " + untracked.join(", "));
  for (const k of multi) problems.push(`${k} matched by ${owner[k].length} managers (${owner[k].join(", ")}) — it would be proposed twice`);
  if (ffmpegSeen !== (deps.ffmpeg || []).length) problems.push(`FFmpeg manager yielded ${ffmpegSeen} entries for ${(deps.ffmpeg || []).length} tracked lines`);

  if (problems.length) {
    for (const p of problems) console.error("renovate-coverage: " + p);
    process.exit(1);
  }
  console.log(`ok: all ${Object.keys(defaults).length} ledger deps tracked by exactly one Renovate manager (jsonata), plus ${ffmpegSeen} FFmpeg line(s)`);
})();
JS
