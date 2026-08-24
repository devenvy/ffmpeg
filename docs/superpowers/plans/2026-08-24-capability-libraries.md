# Capability Libraries (Tier-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable five FFmpeg external libraries — harfbuzz, fribidi, soxr, libxml2, libplacebo — closing the highest-value `—` rows in the coverage matrix (text shaping/bidi in `drawtext`, DASH/IMF demuxing, high-quality audio resampling, GPU HDR tone-map/scale).

**Architecture:** Each library is wired through the existing sourced-dep pattern: a `BUILD_*` flag (`02_configure.sh` / `scripts/platform/<family>.sh`), a `deps.json` pin, a `scripts/deps/<lib>.sh` recipe that appends `--enable-<lib>` to `CONFIGURE_FLAGS`, and a source line in `06_build_libraries.sh`. Two libs (harfbuzz, fribidi) are already built for libass and only need their flags exposed. Verification is a local WSL manylinux build per task, GitHub CI once at the end.

**Tech Stack:** Bash build scripts, `build_cmake_dep`/meson helpers, `deps.json` ledger + `jq` loader, Docker `manylinux_2_28_x86_64`, FFmpeg `configure`.

**Spec:** `docs/superpowers/specs/2026-08-24-capability-libraries-design.md`

## Global Constraints

- **All-or-nothing:** all five libraries ship fully working in one PR, or the PR does not merge. No partial libplacebo, no stub, and the other four do not ship without it. On a genuine libplacebo blocker, STOP and decide with the user.
- **Local-first validation (hard rule):** every task is proven with the local WSL manylinux `linux-x64` build below BEFORE any GitHub CI. A task is not done until the local build compiles the lib AND the built FFmpeg's `-buildconf` shows the new `--enable-*` flag.
- **The local cell build** (run in WSL Ubuntu, from the repo root, `MSYS_NO_PATHCONV=1` when invoked via git-bash→wsl):
  ```bash
  docker run --rm -v "$PWD:/work" -w /work \
    -e BUILD_RID=linux-x64 -e BUILD_LICENSE=gpl -e BUILD_LICENSE_VERSION=v3 \
    -e FFMPEG_VERSION=9.0.1 -e BUILD_CONTAINER=manylinux \
    quay.io/pypa/manylinux_2_28_x86_64 \
    bash -c 'chmod +x scripts/build.sh && ./scripts/build.sh'
  ```
  The enabled-libs proof is `artifacts/linux-x64/**/build-info.txt` (lists the FFmpeg configure line) or running the staged `ffmpeg -buildconf`.
- **Static, PIC, no shared libs** into `${DEPS_DIR}`, discovered by FFmpeg via pkg-config — follow the existing dep pattern exactly.
- **Ledger-tracked versions:** every new git-cloned lib is pinned in `deps.json` `.defaults` with `origin` + `tag` + `datasource: "git-tags"` so Renovate tracks it. No literal version strings in dep scripts.
- **No license regressions:** harfbuzz (MIT), fribidi (LGPL-2.1+), soxr (LGPL-2.1), libxml2 (MIT), libplacebo (LGPL-2.1+) are all (L)GPL-compatible. libplacebo is additionally Vulkan-gated (v3 only, no `lgplv2`, only cells where `BUILD_VULKAN=1` survives license selection).
- **Coverage matrix:** after wiring, `bash scripts/gen-matrix.sh` shows the new `✓`s and produces zero drift (the `docs-matrix` CI gate enforces it).
- **Keep existing gates green:** `scripts/deps/ledger-validate.sh`, `scripts/ci/select-versions-test.sh`, and `bash -n` on every touched script.

---

### Task 1: Expose harfbuzz + fribidi to FFmpeg

Both are already built (static) as libass dependencies; they just aren't advertised to FFmpeg. Same one-line shape for both, so they land together.

**Files:**
- Modify: `scripts/deps/harfbuzz.sh` (append the FFmpeg flag)
- Modify: `scripts/deps/fribidi.sh` (append the FFmpeg flag)
- Verify: `docs/matrix/` (regenerated)

**Interfaces:**
- Consumes: `CONFIGURE_FLAGS` array (from `build.sh` env), `BUILD_LIBASS` guard, `${DEPS_DIR}` pkg-config path — all already in scope in both scripts.
- Produces: FFmpeg configured with `--enable-libharfbuzz` and `--enable-libfribidi` whenever libass is built (every cell).

- [ ] **Step 1: Confirm the exact flag names**

Run against a checked-out FFmpeg (or the coverage source): the matrices list `libharfbuzz` and `libfribidi` as external libs, so the flags are `--enable-libharfbuzz` and `--enable-libfribidi`. Confirm with:
```bash
grep -E 'libharfbuzz|libfribidi' docs/matrix/ffmpeg-9-gplv3.md
```
Expected: both appear as rows (already verified). If a local FFmpeg tree is present, `./configure --help | grep -E 'libharfbuzz|libfribidi'` corroborates.

- [ ] **Step 2: Append the harfbuzz flag**

In `scripts/deps/harfbuzz.sh`, after the final `echo "harfbuzz built (libass dependency)."`, add (still inside the `BUILD_LIBASS` guard scope):
```bash
CONFIGURE_FLAGS+=(--enable-libharfbuzz)
echo "libharfbuzz (drawtext text shaping) enabled."
```

- [ ] **Step 3: Append the fribidi flag**

In `scripts/deps/fribidi.sh`, after its build/install completes and under the same guard, add:
```bash
CONFIGURE_FLAGS+=(--enable-libfribidi)
echo "libfribidi (drawtext bidirectional text) enabled."
```

- [ ] **Step 4: Syntax check**

Run: `bash -n scripts/deps/harfbuzz.sh scripts/deps/fribidi.sh`
Expected: no output (clean).

- [ ] **Step 5: Local cell build (the gate)**

Run the local cell build (Global Constraints). Then assert both flags took:
```bash
grep -oE 'enable-lib(harfbuzz|fribidi)' artifacts/linux-x64/*/build-info.txt | sort -u
```
Expected: both `enable-libharfbuzz` and `enable-libfribidi`. Sanity: the build completes and the `drawtext` filter is still present (`ffmpeg -filters | grep drawtext`).

- [ ] **Step 6: Regenerate the matrix**

Run: `bash scripts/gen-matrix.sh` then `git diff --stat docs/matrix/`
Expected: `libharfbuzz` and `libfribidi` rows flip to `✓` in the cells that build libass; no other drift.

- [ ] **Step 7: Commit**

```bash
git add scripts/deps/harfbuzz.sh scripts/deps/fribidi.sh docs/matrix
git commit -m "feat(deps): expose harfbuzz + fribidi to FFmpeg (drawtext shaping + bidi)"
```

---

### Task 2: Un-defer soxr (`--enable-libsoxr`) + fix the `-lm` link ordering

`scripts/deps/soxr.sh` is complete and soxr is already pinned in `deps.json`. Work is wiring + the link fix that caused the original deferral.

**Files:**
- Modify: `scripts/steps/06_build_libraries.sh` (uncomment the soxr source line)
- Modify: `scripts/steps/02_configure.sh` (set `BUILD_LIBSOXR=1`)
- Modify: `scripts/deps/soxr.sh` (ensure `-lm` is available to FFmpeg's static configure check)
- Verify: `docs/matrix/`

**Interfaces:**
- Consumes: `build_cmake_dep` (scripts/lib.sh), `BUILD_LIBSOXR` guard, `CONFIGURE_FLAGS`.
- Produces: FFmpeg configured with `--enable-libsoxr` on every cell; `-af aresample=resampler=soxr` accepted.

- [ ] **Step 1: Enable the build flag**

In `scripts/steps/02_configure.sh`, next to the other all-platform `BUILD_*=1` defaults (near `BUILD_LIBWEBP=1`), add:
```bash
BUILD_LIBSOXR=1
```

- [ ] **Step 2: Source the script**

In `scripts/steps/06_build_libraries.sh`, replace the two commented soxr lines (the `# . "${D}/soxr.sh" … deferred …` block) with an active source line placed near the other audio libs:
```bash
. "${D}/soxr.sh"         # high-quality audio resampling (soxr backend for aresample)
```

- [ ] **Step 3: Fix the `-lm` link ordering**

FFmpeg's static `--enable-libsoxr` configure check fails unless libm is linkable after `-lsoxr`. In `scripts/deps/soxr.sh`, after `build_cmake_dep soxr …` and before appending the flag, ensure soxr's pkg-config advertises libm so FFmpeg's `pkg-config --libs --static soxr` includes `-lm`:
```bash
# soxr links libm; make sure FFmpeg's static configure test for -lsoxr sees it.
SOXR_PC="${DEPS_DIR}/lib/pkgconfig/soxr.pc"
if [[ -f "${SOXR_PC}" ]] && ! grep -q 'Libs.private:.*-lm' "${SOXR_PC}"; then
  printf 'Libs.private: -lm\n' >> "${SOXR_PC}"
fi
```
(If soxr.pc already carries `Libs.private: -lm`, this is a no-op. If the resampler check still fails in the local build, fall back to adding `-lm` to FFmpeg's `--extra-libs` in `07_build_ffmpeg.sh` gated on `BUILD_LIBSOXR` — but try the .pc fix first.)

- [ ] **Step 4: Syntax check**

Run: `bash -n scripts/deps/soxr.sh scripts/steps/02_configure.sh scripts/steps/06_build_libraries.sh`
Expected: clean.

- [ ] **Step 5: Local cell build (the gate)**

Run the local cell build. Assert:
```bash
grep -o 'enable-libsoxr' artifacts/linux-x64/*/build-info.txt
```
Expected: `enable-libsoxr` present (proves the `-lm` fix worked — a failed check would silently drop the flag). Functional sanity, using the staged ffmpeg:
```bash
ffmpeg -hide_banner -f lavfi -i sine=r=44100:d=1 -af aresample=resampler=soxr:osr=48000 -f null - 2>&1 | tail -3
```
Expected: no "resampler=soxr" error; conversion runs.

- [ ] **Step 6: Regenerate the matrix**

Run: `bash scripts/gen-matrix.sh` then `git diff --stat docs/matrix/`
Expected: `SoX resampler` row flips to `✓` across cells; no other drift.

- [ ] **Step 7: Commit**

```bash
git add scripts/deps/soxr.sh scripts/steps/02_configure.sh scripts/steps/06_build_libraries.sh docs/matrix
git commit -m "feat(deps): enable libsoxr (high-quality resampling); fix -lm link order"
```

---

### Task 3: Add libxml2 (`--enable-libxml2`)

New cmake dependency; enables the DASH demuxer + IMF.

**Files:**
- Create: `scripts/deps/libxml2.sh`
- Modify: `deps.json` (add `.defaults.libxml2`)
- Modify: `scripts/steps/02_configure.sh` (`BUILD_LIBXML2=1`)
- Modify: `scripts/steps/06_build_libraries.sh` (source after zlib)
- Verify: `docs/matrix/`

**Interfaces:**
- Consumes: `build_cmake_dep <name> [cmake args]`, `BUILD_LIBXML2` guard, `CONFIGURE_FLAGS`, ledger loader (resolves `libxml2` from `deps.json`).
- Produces: FFmpeg configured with `--enable-libxml2`; DASH demuxer present.

- [ ] **Step 1: Pin the version in the ledger**

Find the current stable libxml2 tag:
```bash
git ls-remote --tags https://github.com/GNOME/libxml2.git 'refs/tags/v2.*' | sed 's|.*refs/tags/||' | grep -vE '\^|rc|alpha|beta' | sort -V | tail -3
```
Add to `deps.json` under `.defaults` (alphabetically among the `lib*` entries), using the chosen `v2.x.y` tag:
```json
"libxml2": { "origin": "https://github.com/GNOME/libxml2.git", "tag": "v2.x.y", "datasource": "git-tags" },
```
Validate: `bash scripts/deps/ledger-validate.sh` → OK.

- [ ] **Step 2: Write the dep script**

Create `scripts/deps/libxml2.sh` (model on `scripts/deps/libwebp.sh` for the flag-append pattern and `build_cmake_dep` usage):
```bash
#!/usr/bin/env bash
set -euo pipefail
# libxml2 — XML parser (MIT). Enables FFmpeg's DASH demuxer + IMF.
# SOURCED by scripts/build.sh (shares env; appends --enable-* to CONFIGURE_FLAGS).
# Not a standalone script.

[[ "${BUILD_LIBXML2}" == "1" ]] || { echo "Skipping libxml2 (not needed for ${RID})."; return 0; }

# Minimal static build: no python/icu/lzma; keep zlib (already built) for DASH.
build_cmake_dep libxml2 \
  -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_ZLIB=ON -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_MODULES=OFF
CONFIGURE_FLAGS+=(--enable-libxml2)
echo "libxml2 (DASH/IMF demuxing) enabled."
```

- [ ] **Step 3: Enable the flag + source it**

In `scripts/steps/02_configure.sh`, add `BUILD_LIBXML2=1` with the all-platform defaults. In `scripts/steps/06_build_libraries.sh`, add after the `zlib.sh` line:
```bash
. "${D}/libxml2.sh"      # XML parser — FFmpeg DASH demuxer + IMF
```

- [ ] **Step 4: Syntax + ledger checks**

Run: `bash -n scripts/deps/libxml2.sh && bash scripts/deps/ledger-validate.sh && bash scripts/ci/select-versions-test.sh`
Expected: clean / OK / tests pass.

- [ ] **Step 5: Local cell build (the gate)**

Run the local cell build. Assert:
```bash
grep -o 'enable-libxml2' artifacts/linux-x64/*/build-info.txt
ffmpeg -hide_banner -demuxers | grep -i dash
```
Expected: `enable-libxml2` present; the `dash` demuxer listed.

- [ ] **Step 6: Regenerate the matrix**

Run: `bash scripts/gen-matrix.sh` then `git diff --stat docs/matrix/`
Expected: libxml2 row → `✓`; Version column shows the pinned tag; no other drift.

- [ ] **Step 7: Commit**

```bash
git add scripts/deps/libxml2.sh deps.json scripts/steps/02_configure.sh scripts/steps/06_build_libraries.sh docs/matrix
git commit -m "feat(deps): add libxml2 (--enable-libxml2 for DASH/IMF demuxing)"
```

---

### Task 4: Add libplacebo (`--enable-libplacebo`) — spike, then wire (Vulkan-gated)

The long pole. libplacebo is a meson build needing Vulkan (already built for whisper) + a SPIR-V shader compiler (glslang/shaderc). Start with a spike on the `linux-x64` v3 cell to establish the recipe and the shader-compiler dependency, THEN wire the gating. **All-or-nothing: if the spike surfaces a genuine blocker, STOP and raise it with the user — do not stub, do not ship without it.**

**Files:**
- Create: `scripts/deps/libplacebo.sh`
- Modify: `deps.json` (add `.defaults.libplacebo`; possibly `.overrides` if 8 and 9 need different tags)
- Modify: `scripts/platform/linux.sh`, `scripts/platform/windows.sh`, `scripts/platform/apple.sh`, `scripts/platform/android.sh` (set `BUILD_LIBPLACEBO=1` in the same blocks that set `BUILD_VULKAN=1`, per the spike's platform findings)
- Modify: `scripts/steps/02_configure.sh` (`BUILD_LIBPLACEBO=0` default) and `scripts/steps/04_select_license.sh` (clear `BUILD_LIBPLACEBO` wherever it clears `BUILD_VULKAN` for v2/lgplv2)
- Modify: `scripts/steps/06_build_libraries.sh` (source after the Vulkan deps)
- Verify: `docs/matrix/`

**Interfaces:**
- Consumes: `clone_dep`, meson + `MESON_CROSS_FILE` pattern (see `scripts/deps/harfbuzz.sh`), `BUILD_LIBPLACEBO` guard, the already-built Vulkan-Headers/loader + SPIRV, `CONFIGURE_FLAGS`.
- Produces: FFmpeg configured with `--enable-libplacebo` on Vulkan-capable v3 cells; the `libplacebo` filter present.

- [ ] **Step 1: Spike — prove the build on linux-x64 v3**

Establish, on the local `linux-x64` gpl/v3 cell, the minimal meson recipe and the shader-compiler dependency. Determine whether the manylinux image's existing shader tooling (it builds `glslang`/`glslc` from source for the Vulkan whisper backend — see `03_install_packages.sh`) satisfies libplacebo, or whether glslang must be added as a dep. Pick a libplacebo tag that FFmpeg 8 AND 9 both accept (check FFmpeg's `configure` libplacebo API-version requirement per major). Record findings in the task report. If a genuine blocker appears, STOP per the all-or-nothing rule.

- [ ] **Step 2: Pin the version in the ledger**

From the spike's chosen tag, add to `deps.json` `.defaults`:
```json
"libplacebo": { "origin": "https://github.com/haasn/libplacebo.git", "tag": "vX.Y.Z", "datasource": "git-tags" },
```
If 8 and 9 need different tags, add an `.overrides.<major>.libplacebo` hold with a `reason`. Validate: `bash scripts/deps/ledger-validate.sh`.

- [ ] **Step 3: Write the dep script (from the spike)**

Create `scripts/deps/libplacebo.sh` using the meson pattern (model on `scripts/deps/harfbuzz.sh`), with the exact meson options the spike proved (static, `-Dvulkan=enabled`, `-Ddemos=false`, `-Dtests=false`, shaderc/glslang option per findings), guarded on `BUILD_LIBPLACEBO`, ending with:
```bash
CONFIGURE_FLAGS+=(--enable-libplacebo)
echo "libplacebo (GPU HDR tone-map + scaling) enabled."
```

- [ ] **Step 4: Wire the gating (track BUILD_VULKAN)**

`BUILD_LIBPLACEBO=0` default in `02_configure.sh`. In each `scripts/platform/<family>.sh` block that sets `BUILD_VULKAN=1` on a platform the spike confirmed viable, also set `BUILD_LIBPLACEBO=1`. In `scripts/steps/04_select_license.sh`, wherever `BUILD_VULKAN` is cleared for v2/lgplv2, also clear `BUILD_LIBPLACEBO`. Source `libplacebo.sh` in `06_build_libraries.sh` after the Vulkan/SPIRV deps.

- [ ] **Step 5: Syntax + ledger checks**

Run: `bash -n scripts/deps/libplacebo.sh scripts/platform/*.sh scripts/steps/04_select_license.sh && bash scripts/deps/ledger-validate.sh`
Expected: clean / OK.

- [ ] **Step 6: Local cell build (the gate) — v3 and v2**

Build the `linux-x64` gpl/**v3** cell (Global Constraints) and assert libplacebo is enabled:
```bash
grep -o 'enable-libplacebo' artifacts/linux-x64/*/build-info.txt
ffmpeg -hide_banner -filters | grep -i libplacebo
```
Expected: flag present; `libplacebo` filter listed. Then build the `linux-x64` gpl/**v2** cell (`BUILD_LICENSE_VERSION=v2`) and assert libplacebo is ABSENT (license gating works):
```bash
grep -c 'enable-libplacebo' artifacts/linux-x64/*/build-info.txt   # expect 0
```

- [ ] **Step 7: Regenerate the matrix**

Run: `bash scripts/gen-matrix.sh` then `git diff --stat docs/matrix/`
Expected: `libplacebo — GPU processing` row → `✓` only in the Vulkan v3 cells (and `—`/`✗` elsewhere, matching Vulkan); no other drift.

- [ ] **Step 8: Commit**

```bash
git add scripts/deps/libplacebo.sh deps.json scripts/platform docs/matrix scripts/steps/02_configure.sh scripts/steps/04_select_license.sh scripts/steps/06_build_libraries.sh
git commit -m "feat(deps): add libplacebo (--enable-libplacebo, Vulkan v3 cells)"
```

---

### Task 5: Full-branch validation + PR

All five libs are in and locally proven on `linux-x64`. Now prove every cell on GitHub CI and open the PR.

**Files:**
- Verify: `docs/matrix/` (final zero-drift), all touched scripts.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a green CI matrix and an open PR to `main`.

- [ ] **Step 1: Final local sweep**

Run: `bash scripts/deps/ledger-validate.sh && bash scripts/ci/select-versions-test.sh && bash scripts/gen-matrix.sh && git diff --stat docs/matrix/`
Expected: OK / tests pass / zero matrix drift (all matrix changes already committed in Tasks 1–4).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/capability-libs
```

- [ ] **Step 3: Watch CI (the cross-platform proof)**

Watch the branch's CI run to a conclusion (the full ~165-job matrix; it is slow — poll at long intervals, mind the API rate limit). Local builds already proved `linux-x64`; CI's job here is the other platforms — especially libplacebo on macOS/Windows/mobile (the Vulkan-gated cells). Any failure is a per-platform script fix (e.g., a missing shader-compiler on a cross target), not a scope problem — fix on the branch and re-push.

- [ ] **Step 4: Open the PR (only when CI is green)**

```bash
gh pr create --base main --head feat/capability-libs \
  --title "feat(deps): Tier-1 capability libraries (harfbuzz, fribidi, soxr, libxml2, libplacebo)" \
  --body "Enables five FFmpeg external libraries — harfbuzz + fribidi (drawtext shaping/bidi), soxr (HQ resampling), libxml2 (DASH/IMF), libplacebo (GPU HDR tone-map/scale, Vulkan v3 cells). Each locally vetted on linux-x64 then proven across the full CI matrix. Implements docs/superpowers/specs/2026-08-24-capability-libraries-design.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 5: Confirm merge behavior**

Note in the PR that merging will (correctly) release BOTH the 8.1.2 and 9.0.1 lines — this changes `scripts/**` and `deps.json`, a build-recipe change that impacts every line (per `select-versions.sh`). Expected and desired.

---

## Self-Review

**Spec coverage:** harfbuzz+fribidi (Task 1), soxr+`-lm` (Task 2), libxml2 (Task 3), libplacebo spike+gating+all-or-nothing (Task 4), local-first per task + full CI (all tasks + Task 5), matrix regen (every task), Renovate pins (Tasks 2–4 add `datasource` entries), license gating (Task 4 v3-only + v2 negative test). All spec sections map to a task.

**Placeholder scan:** version tags are pinned via a concrete `git ls-remote` lookup step (Tasks 3, 4) rather than a guessed literal — that is a real action, not a TBD. libplacebo's exact meson args come from the Task-4 spike, which is the correct way to handle an empirically-determined recipe (the spike step is concrete about what to determine). No "add error handling"-style placeholders.

**Consistency:** `BUILD_LIBSOXR`, `BUILD_LIBXML2`, `BUILD_LIBPLACEBO` flag names used consistently; `--enable-libsoxr/-libxml2/-libplacebo/-libharfbuzz/-libfribidi` match FFmpeg's configure spelling; `build_cmake_dep <name> [args]` signature matches `scripts/lib.sh`; the local-build command is defined once in Global Constraints and referenced by every task.
