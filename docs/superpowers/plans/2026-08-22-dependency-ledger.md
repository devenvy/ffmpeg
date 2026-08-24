# Dependency Version Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every build dependency's version out of the shell scripts into one readable ledger (`deps.json`) with per-FFmpeg-major overrides, resolved by a loader the scripts call, and kept current by self-hosted Renovate.

**Architecture:** A root `deps.json` holds `defaults` (one pinned ref per upstream) and per-major `overrides` (deliberate holds). A `clone_dep` loader in `scripts/deps/lib.sh` resolves override-else-default by the FFmpeg major being built and clones+checks-out. Each `deps/*.sh` builds exactly one upstream and calls `clone_dep`. Renovate (a scheduled self-hosted Action) edits only the `defaults` block and opens bump PRs that CI validates across all FFmpeg lines.

**Tech Stack:** POSIX/bash shell, `jq`, GitHub Actions, Renovate (`renovatebot/github-action`).

**Spec:** `docs/superpowers/specs/2026-08-22-dependency-ledger-design.md`

## Global Constraints

- **Ledger location:** `deps.json` at repo root. Read via `jq`. Path resolved as `${LEDGER:-${ROOT_DIR}/deps.json}` so tests can override it.
- **Entry shape:** each ledger entry has `origin` (clone URL) + exactly one ref key: `tag` | `branch` | `commit`. Override entries also carry `reason` (required); `issue` (integer) present ⇒ temporary blocker, absent ⇒ permanent compat fact.
- **Resolution rule:** for FFmpeg major `M` and dep `N`, use `overrides[M][N]` if present, else `defaults[N]`. Missing/malformed ⇒ **fail the build**, never clone a guess.
- **FFmpeg major** derives from `FFMPEG_VERSION` (first `.`-delimited component); this var is already exported in the build env.
- **Sequencing invariant:** the ledger is first populated **faithfully** (each default = the script's *current* pin) so builds are byte-identical and CI stays green before any version changes. Bumping to latest is a later, separately-validated task.
- **One upstream per `deps/*.sh`.** No version string may remain in any `deps/*.sh` after Task 6.
- **`jq` is a build prerequisite** in every build environment (ubuntu, macOS, alpine musl, manylinux, windows-cross host).

---

### Task 1: Loader (`dep_source` / `clone_dep`) with unit tests

**Files:**
- Modify: `scripts/deps/lib.sh` (append the loader functions)
- Create: `scripts/deps/ledger-test.sh` (self-contained shell unit test)

**Interfaces:**
- Produces:
  - `dep_source <name>` → prints `"<origin>\t<reftype>\t<refval>"` (reftype ∈ `tag|branch|commit`); returns non-zero + stderr message if the dep is absent or malformed.
  - `clone_dep <name> <destdir>` → resolves via `dep_source` and clones+checks-out into `<destdir>`.
  - Reads ledger at `${LEDGER:-${ROOT_DIR}/deps.json}`.

- [ ] **Step 1: Write the failing test** — Create `scripts/deps/ledger-test.sh`:

```bash
#!/usr/bin/env bash
# Unit test for the dep ledger loader. Points the loader at a fixture ledger.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$(mktemp -d)"
export LEDGER="${FIX}/deps.json"
cat > "${LEDGER}" <<'JSON'
{
  "defaults": {
    "x265":   { "origin": "https://example.test/x265.git",  "tag": "4.0" },
    "libfoo": { "origin": "https://example.test/foo.git",   "commit": "abc123" },
    "libbar": { "origin": "https://example.test/bar.git",   "branch": "main", "reason": "no tags" }
  },
  "overrides": { "8": { "x265": { "tag": "3.6", "reason": "8.x caps libx265 at 3.x" } } }
}
JSON
ROOT_DIR="${FIX}"   # unused (LEDGER overrides), set for safety
# shellcheck source=/dev/null
. "${HERE}/lib.sh"

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1"; pass=$((pass+1))
  else echo "FAIL: $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

FFMPEG_VERSION=9.0.1 got="$(dep_source x265)";   check "9 uses default x265"  "$got" "$(printf 'https://example.test/x265.git\ttag\t4.0')"
FFMPEG_VERSION=8.1.2 got="$(dep_source x265)";   check "8 uses override x265" "$got" "$(printf 'https://example.test/x265.git\ttag\t3.6')"
FFMPEG_VERSION=9.0.1 got="$(dep_source libfoo)"; check "commit ref"           "$got" "$(printf 'https://example.test/foo.git\tcommit\tabc123')"
FFMPEG_VERSION=9.0.1 got="$(dep_source libbar)"; check "branch ref"           "$got" "$(printf 'https://example.test/bar.git\tbranch\tmain')"
if FFMPEG_VERSION=9.0.1 dep_source nope 2>/dev/null; then check "missing dep fails" present absent; else check "missing dep fails" ok ok; fi

echo "Passed: ${pass}  Failed: ${fail}"
[ "${fail}" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/deps/ledger-test.sh`
Expected: FAIL — `dep_source: command not found` / non-zero exit (function not defined yet).

- [ ] **Step 3: Write minimal implementation** — Append to `scripts/deps/lib.sh`:

```bash
# --- Dependency ledger loader -------------------------------------------------
# Single source of truth for dep versions is deps.json (see docs/.../specs).
# dep_source resolves override-for-this-FFmpeg-major else default; clone_dep clones it.
_ledger_path() { printf '%s' "${LEDGER:-${ROOT_DIR}/deps.json}"; }
_ffmpeg_major() { printf '%s' "${FFMPEG_VERSION%%.*}"; }

# dep_source <name> -> "<origin>\t<tag|branch|commit>\t<refval>"
dep_source() {
  local name="$1" ledger major entry origin reftype refval
  ledger="$(_ledger_path)"; major="$(_ffmpeg_major)"
  command -v jq >/dev/null 2>&1 || { echo "dep_source: jq not found (build prerequisite)" >&2; return 2; }
  [ -f "${ledger}" ] || { echo "dep_source: ledger not found: ${ledger}" >&2; return 2; }
  entry="$(jq -c --arg m "${major}" --arg n "${name}" \
            '(.overrides[$m][$n] // .defaults[$n]) // empty' "${ledger}")" || return 2
  [ -n "${entry}" ] || { echo "dep_source: '${name}' not in ledger (defaults or overrides.${major})" >&2; return 2; }
  origin="$(jq -r '.origin // empty' <<<"${entry}")"
  reftype="$(jq -r 'to_entries | map(select(.key=="tag" or .key=="branch" or .key=="commit")) | .[0].key // empty' <<<"${entry}")"
  refval="$(jq -r --arg k "${reftype}" '.[$k] // empty' <<<"${entry}")"
  { [ -n "${origin}" ] && [ -n "${reftype}" ] && [ -n "${refval}" ]; } \
    || { echo "dep_source: '${name}' malformed (need origin + exactly one of tag/branch/commit)" >&2; return 2; }
  printf '%s\t%s\t%s\n' "${origin}" "${reftype}" "${refval}"
}

# clone_dep <name> <destdir> -> shallow clone + checkout the resolved ref
clone_dep() {
  local name="$1" dest="$2" origin reftype refval
  IFS=$'\t' read -r origin reftype refval < <(dep_source "${name}") || return $?
  echo "clone_dep: ${name} <- ${origin} @ ${reftype}:${refval}"
  case "${reftype}" in
    tag|branch) git clone --depth 1 --branch "${refval}" "${origin}" "${dest}" ;;
    commit)     git clone "${origin}" "${dest}" && git -C "${dest}" checkout --detach "${refval}" ;;
    *)          echo "clone_dep: bad reftype '${reftype}'" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/deps/ledger-test.sh`
Expected: PASS — `Passed: 5  Failed: 0`, exit 0.

- [ ] **Step 5: Run shellcheck on the new/changed files**

Run: `shellcheck scripts/deps/lib.sh scripts/deps/ledger-test.sh`
Expected: no errors (matches the repo's gating ShellCheck job).

- [ ] **Step 6: Commit**

```bash
git add scripts/deps/lib.sh scripts/deps/ledger-test.sh
git commit -m "feat(deps): ledger loader (dep_source/clone_dep) + unit test"
```

---

### Task 2: Ledger validator + wire the test into CI

**Files:**
- Create: `scripts/deps/ledger-validate.sh`
- Modify: `.github/workflows/shellcheck.yml` (add a step to run the ledger test + validator)

**Interfaces:**
- Consumes: `deps.json` (created in Task 3; validator must handle "file absent" gracefully until then — skip, don't fail).
- Produces: `ledger-validate.sh` — asserts every entry has `origin` + exactly one ref; every override has `reason`; JSON parses.

- [ ] **Step 1: Write the failing test** — Create `scripts/deps/ledger-validate.sh`:

```bash
#!/usr/bin/env bash
# Validate deps.json structure. No-op (pass) if the ledger doesn't exist yet.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="${ROOT_DIR}/deps.json"
[ -f "${LEDGER}" ] || { echo "ledger-validate: ${LEDGER} absent — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "ledger-validate: jq required" >&2; exit 2; }
jq -e . "${LEDGER}" >/dev/null || { echo "ledger-validate: invalid JSON" >&2; exit 1; }

# Every defaults + overrides entry: origin present, exactly one ref key.
bad="$(jq -r '
  [ (.defaults // {}) | to_entries[]
  , (.overrides // {}) | to_entries[] | .value | to_entries[] ]
  | .[] | .value as $e | .key as $k
  | ($e | [has("tag"),has("branch"),has("commit")] | map(select(.)) | length) as $refs
  | select(($e.origin|not) or ($refs != 1))
  | $k' "${LEDGER}")"
if [ -n "${bad}" ]; then echo "ledger-validate: bad entries (need origin + one ref): ${bad}" >&2; exit 1; fi

# Every override must carry a reason.
noreason="$(jq -r '(.overrides // {}) | to_entries[] | .value | to_entries[] | select(.value.reason|not) | .key' "${LEDGER}")"
if [ -n "${noreason}" ]; then echo "ledger-validate: overrides missing reason: ${noreason}" >&2; exit 1; fi
echo "ledger-validate: OK"
```

- [ ] **Step 2: Run to verify it passes with no ledger yet**

Run: `bash scripts/deps/ledger-validate.sh`
Expected: `ledger-validate: ... absent — skipping`, exit 0.

- [ ] **Step 3: Add both scripts to the ShellCheck workflow** — In `.github/workflows/shellcheck.yml`, after the checkout step, add a step:

```yaml
      - name: Dependency ledger checks
        shell: bash
        run: |
          bash scripts/deps/ledger-test.sh
          bash scripts/deps/ledger-validate.sh
```

- [ ] **Step 4: Verify shellcheck-clean**

Run: `shellcheck scripts/deps/ledger-validate.sh`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/deps/ledger-validate.sh .github/workflows/shellcheck.yml
git commit -m "feat(deps): ledger validator + run ledger checks in CI"
```

---

### Task 3: Populate `deps.json` faithfully (current pins) + minimal overrides

**Files:**
- Create: `deps.json`

**Interfaces:**
- Consumes: the loader (Task 1) + validator (Task 2).
- Produces: `deps.json` whose `defaults` reproduce each script's **current** pin exactly (no version change), `overrides` empty except any pin a script *already* applies per-nothing (none expected yet).

- [ ] **Step 1: Transcribe every current pin.** For each `scripts/deps/*.sh`, read its clone/tarball line and record `origin` + current ref into `defaults`. Rules: a `--branch <tag>` → `tag`; a moving branch (`x264 stable`, and every floater with no ref) → `branch` with that branch name **plus** a `reason: "TODO pin — currently tracks <branch>; pin in bump task"`; a `VER=` tarball dep (gmp/gnutls/nettle/libtasn1/openssl) → `tag` using the upstream tag that matches that version. Split-out upstreams (libpng, libexpat, Vulkan-Headers, SPIRV-Headers, Vulkan-Loader) get their own entries here even though their scripts are split in Task 5. Create `deps.json`:

```jsonc
{
  "defaults": {
    "dav1d":      { "origin": "https://code.videolan.org/videolan/dav1d.git",        "tag": "1.4.3",  "datasource": "gitlab-tags", "registryUrl": "https://code.videolan.org" },
    "fribidi":    { "origin": "https://github.com/fribidi/fribidi.git",              "tag": "v1.0.16", "datasource": "github-tags" },
    "harfbuzz":   { "origin": "https://github.com/harfbuzz/harfbuzz.git",            "tag": "8.5.0",   "datasource": "github-tags" },
    "kvazaar":    { "origin": "https://github.com/ultravideo/kvazaar.git",           "tag": "v2.3.1",  "datasource": "github-tags" },
    "libass":     { "origin": "https://github.com/libass/libass.git",               "tag": "0.17.3",  "datasource": "github-tags" },
    "libdrm":     { "origin": "https://gitlab.freedesktop.org/mesa/drm.git",         "tag": "libdrm-2.4.123", "datasource": "gitlab-tags", "registryUrl": "https://gitlab.freedesktop.org" },
    "libogg":     { "origin": "https://github.com/xiph/ogg.git",                     "tag": "v1.3.5",  "datasource": "github-tags" },
    "libva":      { "origin": "https://github.com/intel/libva.git",                 "tag": "2.22.0",  "datasource": "github-tags" },
    "libvorbis":  { "origin": "https://github.com/xiph/vorbis.git",                 "tag": "v1.3.7",  "datasource": "github-tags" },
    "libvpx":     { "origin": "https://chromium.googlesource.com/webm/libvpx.git",  "tag": "v1.14.1", "datasource": "git-refs" },
    "x265":       { "origin": "https://bitbucket.org/multicoreware/x265_git.git",   "tag": "3.6",     "datasource": "bitbucket-tags", "registryUrl": "https://bitbucket.org" },
    "moltenvk":   { "origin": "https://github.com/KhronosGroup/MoltenVK.git",       "tag": "v1.2.11", "datasource": "github-tags" },
    "openh264":   { "origin": "https://github.com/cisco/openh264.git",             "tag": "v2.4.1",  "datasource": "github-tags" },
    "openssl":    { "origin": "https://github.com/openssl/openssl.git",            "tag": "openssl-3.5.1", "datasource": "github-tags" },
    "whisper":    { "origin": "https://github.com/ggml-org/whisper.cpp.git",       "tag": "v1.8.6",  "datasource": "github-tags" },
    "zimg":       { "origin": "https://github.com/sekrit-twc/zimg.git",            "tag": "release-3.0.5", "datasource": "github-tags" },
    "zlib":       { "origin": "https://github.com/madler/zlib.git",               "tag": "v1.3.1",  "datasource": "github-tags" },
    "gmp":        { "origin": "https://github.com/alisw/GMP.git",                 "tag": "v6.3.0",  "datasource": "github-tags", "reason": "TODO confirm upstream mirror + tag format during transcription" },
    "gnutls":     { "origin": "https://gitlab.com/gnutls/gnutls.git",             "tag": "3.8.6",   "datasource": "gitlab-tags", "registryUrl": "https://gitlab.com" },
    "nettle":     { "origin": "https://git.lysator.liu.se/nettle/nettle.git",     "tag": "nettle_3.10_release_20240616", "datasource": "git-refs", "reason": "TODO confirm exact tag during transcription" },
    "libtasn1":   { "origin": "https://gitlab.com/gnutls/libtasn1.git",           "tag": "v4.19.0", "datasource": "gitlab-tags", "registryUrl": "https://gitlab.com" },
    "libexpat":   { "origin": "https://github.com/libexpat/libexpat.git",         "tag": "R_2_6_2", "datasource": "github-tags" },
    "fontconfig": { "origin": "https://gitlab.freedesktop.org/fontconfig/fontconfig.git", "tag": "2.15.0", "datasource": "gitlab-tags", "registryUrl": "https://gitlab.freedesktop.org" },
    "libpng":     { "origin": "https://github.com/pnggroup/libpng.git",           "branch": "libpng16", "datasource": "github-tags", "reason": "TODO pin — transcribe current freetype.sh libpng ref" },
    "freetype":   { "origin": "https://gitlab.freedesktop.org/freetype/freetype.git", "branch": "master", "datasource": "gitlab-tags", "registryUrl": "https://gitlab.freedesktop.org", "reason": "TODO pin — transcribe current freetype.sh ref" },

    "amf":        { "origin": "https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git", "branch": "master", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "aom":        { "origin": "https://aomedia.googlesource.com/aom.git",          "branch": "main", "datasource": "git-refs", "reason": "TODO pin — transcribe current aom.sh ref/origin" },
    "libmp3lame": { "origin": "https://github.com/rbrito/lame.git",               "branch": "master", "datasource": "github-tags", "reason": "TODO confirm origin (currently a tarball) + pin" },
    "libvpl":     { "origin": "https://github.com/intel/libvpl.git",              "branch": "main", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "libwebp":    { "origin": "https://chromium.googlesource.com/webm/libwebp.git","branch": "main", "datasource": "git-refs", "reason": "TODO pin — currently floats HEAD" },
    "nv-codec":   { "origin": "https://github.com/FFmpeg/nv-codec-headers.git",   "branch": "master", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "opus":       { "origin": "https://github.com/xiph/opus.git",                 "branch": "main", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "soxr":       { "origin": "https://github.com/dofuuz/soxr.git",               "branch": "master", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "svtav1":     { "origin": "https://gitlab.com/AOMediaCodec/SVT-AV1.git",      "branch": "master", "datasource": "gitlab-tags", "registryUrl": "https://gitlab.com", "reason": "TODO pin — currently floats HEAD" },
    "x264":       { "origin": "https://code.videolan.org/videolan/x264.git",      "branch": "stable", "datasource": "git-refs", "reason": "x264 publishes no release tags; tracks stable — pin a reviewed commit in bump task" },
    "vulkan-headers": { "origin": "https://github.com/KhronosGroup/Vulkan-Headers.git", "branch": "main", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "vulkan-loader":  { "origin": "https://github.com/KhronosGroup/Vulkan-Loader.git",  "branch": "main", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" },
    "spirv-headers":  { "origin": "https://github.com/KhronosGroup/SPIRV-Headers.git",  "branch": "main", "datasource": "github-tags", "reason": "TODO pin — currently floats HEAD" }
  },
  "overrides": { "8": {}, "9": {} }
}
```

> NOTE: several `origin`/`tag` values above are marked `TODO ... transcribe` — the implementer MUST replace each with the exact value read from the corresponding `deps/*.sh`, so this step is a *faithful* transcription (no behavior change). Do not invent versions; copy them.

- [ ] **Step 2: Validate the ledger**

Run: `bash scripts/deps/ledger-validate.sh`
Expected: `ledger-validate: OK`.

- [ ] **Step 3: Spot-check resolution for both majors**

Run: `FFMPEG_VERSION=9.0.1 bash -c '. scripts/deps/lib.sh; dep_source x265'`
Expected: `https://bitbucket.org/multicoreware/x265_git.git<TAB>tag<TAB>3.6`
Run: `bash scripts/deps/ledger-test.sh`
Expected: still `Failed: 0` (fixture test unaffected).

- [ ] **Step 4: Commit**

```bash
git add deps.json
git commit -m "feat(deps): add deps.json ledger (faithful current pins)"
```

---

### Task 4: Make `jq` a build prerequisite everywhere

**Files:**
- Modify: `scripts/steps/03_install_packages.sh` (add `jq` to installs)
- Modify: `.github/workflows/build.yml` (Alpine bootstrap step — add `jq`)
- Modify: `.github/workflows/test.yml` (Alpine bootstrap — add `jq` if that env sources deps; else skip)

**Interfaces:**
- Consumes: nothing.
- Produces: `jq` present before any `deps/*.sh` runs, in every build environment.

- [ ] **Step 1: Add `jq` to the package installer.** In `scripts/steps/03_install_packages.sh`, add `jq` to each platform's package list (apt: `jq`; dnf/yum: `jq`; apk: `jq`; brew: `jq`; the Windows-cross host is ubuntu so apt covers it). Match the file's existing per-manager structure.

- [ ] **Step 2: Add `jq` to the Alpine container bootstrap.** In `.github/workflows/build.yml`, the `Bootstrap Alpine container` step's `apk add --no-cache ...` line — append `jq`.

- [ ] **Step 3: Verify locally the loader errors clearly without jq (negative check).**

Run: `PATH=/nonexistent bash -c '. scripts/deps/lib.sh; FFMPEG_VERSION=9 LEDGER=deps.json dep_source x265; echo rc=$?'`
Expected: stderr `dep_source: jq not found ...`, `rc=2`.

- [ ] **Step 4: Commit**

```bash
git add scripts/steps/03_install_packages.sh .github/workflows/build.yml .github/workflows/test.yml
git commit -m "build(deps): install jq in every build environment (ledger prerequisite)"
```

---

### Task 5: Split multi-upstream dep scripts into single-purpose scripts

**Files:**
- Create: `scripts/deps/libpng.sh`, `scripts/deps/libexpat.sh`, `scripts/deps/vulkan-headers.sh`, `scripts/deps/vulkan-loader.sh`, `scripts/deps/spirv-headers.sh` (as needed by what the originals inline)
- Modify: `scripts/deps/freetype.sh`, `scripts/deps/fontconfig.sh`, `scripts/deps/vulkan.sh`, `scripts/deps/whisper.sh` (remove the inlined sub-upstream clone; keep only their own build)
- Modify: `scripts/steps/06_build_libraries.sh` (source the new scripts in dependency order)

**Interfaces:**
- Consumes: nothing yet (still hardcoded clones — rewired to `clone_dep` in Task 6). This task only *relocates* the sub-upstream clone into its own script.
- Produces: one upstream per `deps/*.sh`.

- [ ] **Step 1: For each multi-upstream script, cut the sub-upstream's clone+build block into a new `deps/<sub>.sh`** that mirrors the surrounding style (same env, same install prefix). Example — `freetype.sh` currently clones libpng then freetype; move the libpng block verbatim into `deps/libpng.sh`.

- [ ] **Step 2: Update `06_build_libraries.sh`** to source the new script(s) immediately before the dependent one (e.g. `. "${D}/libpng.sh"` before `. "${D}/freetype.sh"`; `libexpat` before `fontconfig`; `vulkan-headers` before `vulkan-loader`; `vulkan-headers`+`spirv-headers` before `whisper` where its ggml backend needs them).

- [ ] **Step 3: Validate build wiring locally as far as possible.**

Run: `bash -n scripts/deps/*.sh scripts/steps/06_build_libraries.sh`
Expected: no syntax errors.
Run: `shellcheck scripts/deps/libpng.sh scripts/deps/libexpat.sh scripts/deps/vulkan-headers.sh scripts/deps/vulkan-loader.sh scripts/deps/spirv-headers.sh`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/deps/ scripts/steps/06_build_libraries.sh
git commit -m "refactor(deps): one upstream per script (split freetype/fontconfig/vulkan/whisper)"
```

- [ ] **Step 5: Full-build validation (integration).** Push the branch and let `ci.yml` build the matrix; confirm green (identical artifacts — no version changed, only relocation). If red, fix the split ordering and re-push before proceeding.

---

### Task 6: Rewire every `deps/*.sh` to `clone_dep` (remove all hardcoded versions)

**Files:**
- Modify: every `scripts/deps/*.sh` that clones/downloads an upstream.

**Interfaces:**
- Consumes: `clone_dep` (Task 1), `deps.json` (Task 3).
- Produces: no version string in any `deps/*.sh`; all sourcing goes through the ledger.

- [ ] **Step 1: Replace each hardcoded clone with `clone_dep`.** Pattern (worked example, `dav1d.sh`):

```bash
# BEFORE
git clone --depth 1 --branch 1.4.3 https://code.videolan.org/videolan/dav1d.git "${WORK_DIR}/dav1d"
# AFTER
clone_dep dav1d "${WORK_DIR}/dav1d"
```

For tarball deps (gmp/gnutls/nettle/libtasn1/openssl), convert to a `clone_dep` git clone of the matching tag (origin already in the ledger), or — if a tarball is required — add a `dep_source`-driven download; prefer the git clone for uniformity. Apply to **every** dep script including the ones split in Task 5.

- [ ] **Step 2: Grep-assert no versions remain.**

Run: `grep -rnE "git clone.*--branch|_VER=|VERSION=[0-9]|/archive/|releases/download" scripts/deps/ | grep -v ledger`
Expected: **no output** (every version now lives only in `deps.json`).

- [ ] **Step 3: Syntax + shellcheck.**

Run: `bash -n scripts/deps/*.sh && shellcheck scripts/deps/*.sh`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/deps/
git commit -m "refactor(deps): resolve all dep sources via the ledger (clone_dep)"
```

- [ ] **Step 5: Full-build validation (integration).** Push; `ci.yml` must be green across 8.x and 9.x with byte-comparable artifacts (versions unchanged from Task 3's faithful pins). This proves the ledger mechanism end-to-end. Fix and re-push until green.

---

### Task 7: Bump defaults to latest + add overrides where a line breaks

**Files:**
- Modify: `deps.json` (`defaults` → latest; `overrides` as needed)

**Interfaces:**
- Consumes: the full working mechanism (Tasks 1–6).
- Produces: `defaults` at latest upstream release; every `TODO pin` replaced with a real tag/commit; overrides added only where CI proves a line can't take latest.

- [ ] **Step 1: For each `defaults` entry, look up the latest upstream release** (its datasource host) and set the ref to that tag. Replace every `TODO pin`/`branch` floater with a concrete tag (or a reviewed commit for tagless upstreams like x264). Record what changed in the commit body ("what we were behind on").

- [ ] **Step 2: Validate + resolve-check.**

Run: `bash scripts/deps/ledger-validate.sh`
Expected: OK, and **no remaining `reason: "TODO ...` entries** (grep to confirm): `grep -n 'TODO' deps.json` → no output.

- [ ] **Step 3: Full-build validation (integration).** Push; `ci.yml` builds 8.x and 9.x against latest.

- [ ] **Step 4: For each failing (major, dep), add an override** holding the last-good ref, with `reason`; add `issue: <n>` only if it's a genuine bug (file the issue first). Re-push. Repeat until 8.x and 9.x are both green.

- [ ] **Step 5: Commit** (may be several commits across the iteration)

```bash
git add deps.json
git commit -m "feat(deps): bump defaults to latest; hold <dep> on <major> where required"
```

---

### Task 8: Self-hosted Renovate on the `defaults` block

**Files:**
- Create: `renovate.json`
- Create: `.github/workflows/renovate.yml`

**Interfaces:**
- Consumes: `deps.json` (`defaults` block).
- Produces: scheduled bump PRs for defaults only; overrides untouched.

- [ ] **Step 1: Create `renovate.json`** with a customManager scoped to the `defaults` block:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/^deps\\.json$/"],
      "matchStringsStrategy": "combination",
      "matchStrings": [
        "\"(?<depName>[a-z0-9-]+)\":\\s*\\{\\s*\"origin\":\\s*\"(?<packageName>[^\"]+?)(?:\\.git)?\",\\s*\"(?:tag|commit)\":\\s*\"(?<currentValue>[^\"]+)\"(?:[^}]*\"datasource\":\\s*\"(?<datasource>[^\"]+)\")?(?:[^}]*\"registryUrl\":\\s*\"(?<registryUrl>[^\"]+)\")?"
      ],
      "datasourceTemplate": "{{#if datasource}}{{datasource}}{{else}}git-refs{{/if}}"
    }
  ],
  "packageRules": [
    { "description": "Never touch the overrides block (deliberate holds).",
      "matchFileNames": ["deps.json"], "matchDepNames": ["/^$/"], "enabled": false }
  ],
  "schedule": ["before 6am on monday"],
  "prConcurrentLimit": 5
}
```

> NOTE: the regex must match entries in `defaults` and NOT in `overrides`. If the combination strategy can't cleanly exclude overrides by structure, split `defaults` into its own file (`deps.defaults.json`) that Renovate manages and `deps.json` `$ref`s / merges — decide during implementation and update the loader path accordingly. Verify with `npx --yes renovate-config-validator` and a dry run.

- [ ] **Step 2: Validate the Renovate config.**

Run: `npx --yes --package renovate -- renovate-config-validator`
Expected: "Config validated successfully".

- [ ] **Step 3: Create the scheduled workflow** `.github/workflows/renovate.yml`:

```yaml
name: Renovate
on:
  schedule: [{ cron: "0 5 * * 1" }]
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  renovate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: renovatebot/github-action@v40
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
        env:
          RENOVATE_REPOSITORIES: ${{ github.repository }}
```

- [ ] **Step 4: Dry-run once via dispatch** (`RENOVATE_DRY_RUN=full` env) and confirm it proposes bumps for `defaults` entries and **no** changes to `overrides`. Remove the dry-run env once confirmed.

- [ ] **Step 5: Commit**

```bash
git add renovate.json .github/workflows/renovate.yml
git commit -m "ci(deps): self-hosted Renovate bumps deps.json defaults"
```

---

### Task 9: Document the flow in `DEVELOPMENT.md`

**Files:**
- Modify: `DEVELOPMENT.md` (add a "Dependency versions" section)

**Interfaces:**
- Consumes: the finished system.
- Produces: contributor docs.

- [ ] **Step 1: Add a "Dependency versions" section** covering: where versions live (`deps.json`, `defaults` vs `overrides`); how the loader resolves override-else-default by FFmpeg major; how to bump by hand and how Renovate does it; how to add an override (per-major hold, required `reason`, and the rule: **file an issue + set `issue` for a bug/blocker; omit it for a permanent compat fact**); how to remove a hold when the issue is fixed. Keep to the doc's existing voice/length.

- [ ] **Step 2: Commit**

```bash
git add DEVELOPMENT.md
git commit -m "docs: document the dependency version ledger flow"
```

---

## Self-Review

**Spec coverage:** ledger schema (Task 3) ✓; loader (Task 1) ✓; override policy incl. `issue` vs compat (Tasks 3/7/9) ✓; one-upstream-per-script split (Task 5) ✓; rewire (Task 6) ✓; Renovate defaults-only (Task 8) ✓; migration default-to-latest + validate (Tasks 3→7) ✓; jq prerequisite (Task 4) ✓; testing loader-unit + build-integration + ledger-validate (Tasks 1/2) ✓; DEVELOPMENT.md (Task 9) ✓; non-goal FFmpeg-tracking left out ✓.

**Placeholder scan:** the only `TODO` markers are *inside `deps.json` data* and are explicitly instructed to be replaced by transcribed/looked-up real values (Tasks 3 Step 1, Task 7 Step 1/2) — they are data-entry directives with an enforced grep-gate, not plan placeholders. No "add error handling"/"write tests for the above" steps; loader/validator/renovate all have real code.

**Type consistency:** `dep_source`/`clone_dep` names, the `<origin>\t<reftype>\t<refval>` contract, `${LEDGER:-${ROOT_DIR}/deps.json}` path, and `overrides[major][dep] // defaults[dep]` resolution are used identically across Tasks 1, 3, 6, 8.
