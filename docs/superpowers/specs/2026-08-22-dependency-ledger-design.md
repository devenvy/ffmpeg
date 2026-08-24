# Dependency Version Ledger — Design

- **Date:** 2026-08-22
- **Status:** Draft (awaiting review)
- **Scope:** External build dependencies only. FFmpeg's own version tracking
  (`versions.txt` + `check-updates.yml`) is out of scope for v1 but the same
  mechanism could absorb it later.

## Problem

Dependency versions are pinned inconsistently and invisibly:

- **Buried in scripts.** Each `scripts/deps/<lib>.sh` hardcodes its own
  `git clone --branch <ver> <url>` (or `VER=x.y.z` + tarball). There is no single
  place to see or change what we build against.
- **Many float to HEAD.** `amf`, `aom`, `libmp3lame`, `libvpl`, `libwebp`,
  `nv-codec` (ffnvcodec), `opus`, `soxr`, `svtav1`, Vulkan-Headers, and `x264`
  (moving `stable` branch) have no fixed pin — every build can pull a different
  upstream commit. That is non-reproducible and a supply-chain gap.
- **No update mechanism.** `check-updates.yml` bumps *FFmpeg*; nothing checks the
  deps. Pinned deps silently rot — missing security fixes and new-FFmpeg compat.
- **No per-FFmpeg-version story.** With 8.x and 9.x maintained in parallel, a lib
  version that suits one line may not suit the other. There's nowhere to express
  "9.x tracks latest, 8.x holds an older tag."

## Goals

1. **One readable ledger** (`deps.json`) that is the single source of truth for
   every dependency's origin + version — not vars scattered across scripts.
2. **Per-FFmpeg-major overrides** so a line can deliberately hold a lib back
   without affecting the others.
3. **Reproducible pins** — every default is a fixed tag or commit, never a moving
   branch (branch allowed only as a documented exception for tagless upstreams).
4. **Automated, tested update proposals** — a tool watches each upstream and opens
   a bump PR; CI validates it across all FFmpeg lines before merge.
5. **Self-documenting pin rationale** — every override records *why*, and
   distinguishes a temporary bug-hold (tracked by an issue) from a permanent
   compat fact.

## Non-goals (v1)

- Tracking FFmpeg itself (stays on `check-updates.yml`).
- Auto-removing stale override holds (manual, via the linked issue — see below).
- Changing *what* libraries we build (that's the separate "capabilities" work).

## Current state (for migration)

~34 `deps/*.sh` scripts. Mix of: exact tag pins (`dav1d 1.4.3`, `x265 3.6`,
`openssl 3.5.1`, …), version-var + tarball (`gmp`, `gnutls`, `nettle`,
`libtasn1`, `openssl`), and the floaters listed above. Some scripts build **more
than one upstream** (e.g. `freetype.sh` → libpng + freetype; `fontconfig.sh` →
libexpat + fontconfig; `vulkan.sh` → Vulkan-Headers + Vulkan-Loader; `whisper.sh`
also pulls Vulkan-Headers + SPIRV-Headers for its ggml backend). These will be
**split** (§3) so the ledger is a clean **1:1** with single-purpose scripts.

## Design

### 1. The ledger — `deps.json` (repo root)

```jsonc
{
  "defaults": {
    "dav1d":  { "origin": "https://code.videolan.org/videolan/dav1d.git", "tag": "1.4.3", "datasource": "gitlab-tags", "registryUrl": "https://code.videolan.org" },
    "x264":   { "origin": "https://code.videolan.org/videolan/x264.git",  "commit": "<sha>", "datasource": "git-refs", "reason": "x264 has no release tags; pin a reviewed commit" },
    "openssl":{ "origin": "https://github.com/openssl/openssl.git", "tag": "openssl-3.5.1", "datasource": "github-tags" }
  },
  "overrides": {
    "8": {
      "x265": { "tag": "3.6", "reason": "8.x configure caps libx265 at 3.x" }        // compat → no issue
    },
    "9": {
      "libfoo": { "commit": "<sha>", "reason": "regression building against 9.x", "issue": 142 }  // blocker → issue
    }
  }
}
```

- **Entry shape:** `origin` (clone URL) + exactly one ref: `tag` | `branch` |
  `commit`. `branch` is the tagless-upstream exception and must carry a `reason`.
- **`datasource` / `registryUrl`:** hints for Renovate (see §4). Optional where
  Renovate can infer from the host (github.com); explicit for videolan/bitbucket/
  chromium/khronos where inference is unreliable.
- **`overrides.<major>.<dep>`:** only libs that differ from `defaults`. Carries
  the same ref fields plus:
  - **`reason`** — required, human-readable.
  - **`issue`** — present ⇒ *temporary blocker hold* to revisit (the issue is the
    reminder). Absent ⇒ *permanent compat fact*, nothing to fix.
- Renovate edits **`defaults` only**; `overrides` are hand-managed.

### 2. The loader — `dep_source` / `clone_dep` (in `scripts/deps/lib.sh`)

```sh
# dep_source <name>  -> echoes "<origin>\t<reftype>\t<refvalue>"
#   resolves overrides["$FFMPEG_MAJOR"]["$name"]  else  defaults["$name"]
# clone_dep <name> <destdir>  -> dep_source + git clone --depth 1 + checkout ref
```

- `FFMPEG_MAJOR` is derived from the build's `FFMPEG_VERSION` (first component).
- Resolution via `jq` against `deps.json` (repo-root path resolved from
  `ROOT_DIR`). Override for the current major wins; else the default.
- `clone_dep` maps reftype → checkout: `tag`/`branch` via `--branch`; `commit`
  via `git clone` + `git checkout <sha>` (can't `--branch` a bare sha with
  `--depth 1` on all hosts, so fetch-then-checkout).
- **Fail loud** if: the dep isn't in the ledger, the ref is missing/empty, or
  `jq` is unavailable — a mis-resolved dep must stop the build, not silently
  clone the wrong thing.

### 3. Rewire `deps/*.sh`

Each script drops its hardcoded clone and calls the loader:

```sh
# before:  git clone --depth 1 --branch 1.4.3 https://code.videolan.org/videolan/dav1d.git
# after:   clone_dep dav1d "${WORK_DIR}/dav1d"
```

**One upstream per script.** Scripts that currently clone more than one upstream
are split so each pinned lib has its own single-purpose `deps/<name>.sh` and its
own ledger entry (e.g. `freetype.sh` → `libpng.sh` + `freetype.sh`;
`fontconfig.sh` → `libexpat.sh` + `fontconfig.sh`; the Vulkan/SPIRV header helpers
become their own scripts). `06_build_libraries.sh` sources them in dependency
order (libpng before freetype, etc.). After migration, **no version string lives
in any `deps/*.sh`** — the ledger is authoritative and 1:1 with the scripts.

### 4. Renovate — self-hosted

- **`renovate.json`** with a `customManagers` (regex) entry that matches **only
  the `defaults` block** of `deps.json`, extracting `depName`, `currentValue`
  (tag/commit), `datasource`, and `registryUrl`. The `overrides` block is outside
  the match, so Renovate never touches a hold.
- **Runner:** a scheduled GitHub Actions workflow running
  `renovatebot/github-action` with `GITHUB_TOKEN` — self-hosted, no external
  service, same trust model as `check-updates.yml`.
- **Behavior:** on a new upstream tag, Renovate opens a PR bumping that default.
  `ci.yml` builds **every FFmpeg line** against it.

### 5. The update loop

1. Renovate bumps a `default` → PR.
2. CI builds all FFmpeg majors against the new version.
3. **Green** → merge; we're current.
4. **Red on a line** → add an `overrides.<major>.<dep>` hold (last-good ref +
   `reason`, plus `issue` if it's a bug) in the same PR → green → merge. The
   default stays current; that line is held.
5. When the blocker's issue is fixed upstream, delete the override (manual; the
   issue is the reminder).

## Data flow

`ci.yml` build job → `scripts/build.sh` → `06_build_libraries.sh` sources each
`deps/<lib>.sh` → `clone_dep <name>` → `dep_source` reads `deps.json` (jq),
resolves by `FFMPEG_MAJOR` → clone + checkout. Renovate (scheduled) reads the
same `deps.json` `defaults` and opens bump PRs.

## Error handling

- Missing dep / empty ref / malformed `deps.json` → `clone_dep` exits non-zero
  with a clear message (build fails fast).
- `jq` missing → treat as a build prerequisite; add `jq` to the package installs
  / container bootstraps (ubuntu, macOS, alpine musl, manylinux, win-cross host).
- Renovate opening a bad bump → caught by CI (build fails), never merged.

## Testing

- **Loader unit tests** (a small `bats`/shell test or a checked-in fixture
  `deps.json`): given a ledger + `FFMPEG_MAJOR`, `dep_source` returns the right
  origin/ref; override-wins-over-default; missing-dep fails; branch/tag/commit
  each resolve.
- **Integration:** the existing build matrix — a wrong/removed ref fails the
  build. Migration PR CI validates every dep at its new pin across 8.x and 9.x.
- **Ledger validity:** a tiny check (jq parse + schema-ish assertions: every
  entry has origin + exactly one ref; every override has a reason) run in CI /
  shellcheck job.

## Documentation

The end-to-end flow is documented in **`DEVELOPMENT.md`** (a dedicated
"Dependency versions" section), covering for a developer:

- Where dep versions live (`deps.json`) and its `defaults` / `overrides` shape.
- How to bump a dep by hand, and how Renovate does it automatically.
- How to add an override: the per-major hold, the required `reason`, and the
  rule — **file a tracking issue and set `issue` for a bug/blocker hold; omit it
  for a permanent compat fact** ("8.x can't take the newer API, 9.x can").
- How to remove a hold (manual, when the linked issue is fixed).
- How the loader (`clone_dep`) resolves override-else-default at build time.

This spec is the design record; `DEVELOPMENT.md` is the living contributor guide.

## Migration plan

1. Build `deps.json` `defaults` from the current scripts, but **set each default
   to the latest upstream release** (not the current pin) — this is also the
   "what are we behind on" audit.
2. Pin every floater (`amf`, `aom`, `libvpl`, `libwebp`, `nv-codec`, `opus`,
   `soxr`, `svtav1`, `x264`, Vulkan-Headers, …) to an explicit tag or reviewed
   commit.
3. **Split** the multi-upstream scripts into single-purpose ones (§3) and fix the
   `06_build_libraries.sh` source order.
4. Add the loader; rewire every `deps/*.sh` to it (no version strings left).
5. Add `jq` where missing.
6. Run CI across **8.x and 9.x**; add `overrides` only where a line genuinely
   can't take latest (with `reason`; `issue` if it's a bug).
7. Add Renovate (`renovate.json` + scheduled workflow) once the ledger is the
   source of truth.
8. Write the **`DEVELOPMENT.md`** "Dependency versions" section.

Expect steps 1/5 to be iterative — CI surfaces the real "8 needs old / 9 fine"
cases rather than us guessing.

## Open questions

- **Renovate datasource coverage** for every host (code.videolan.org,
  bitbucket, chromium.googlesource, gitlab.com, Khronos): confirm each during
  implementation; where a host is unsupported, fall back to `git-refs`/commit
  pinning (still Renovate-trackable via digest).
- **`versions.txt` absorption:** whether to later fold FFmpeg into `deps.json` +
  Renovate and retire part of `check-updates.yml`. Deferred.
