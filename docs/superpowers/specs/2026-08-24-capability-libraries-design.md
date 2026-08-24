# Capability Libraries (Tier-1 additions) — Design

**Status:** approved design, pre-plan
**Branch:** `feat/capability-libs` → one PR to `main`
**Goal:** Enable five additional FFmpeg external libraries so the builds cover
text shaping/bidi (`drawtext`), DASH/IMF demuxing, high-quality audio
resampling, and GPU HDR tone-mapping/scaling — closing the highest-value `—`
rows in the coverage matrix.

## Scope

Five libraries, delivered in one branch / one PR, in ascending order of risk:

| # | Library | FFmpeg flag | Nature | Build | Cells |
|---|---------|-------------|--------|-------|-------|
| 1 | **harfbuzz** | `--enable-libharfbuzz` | expose an already-built lib | (already meson-built for libass) | every cell that builds libass |
| 2 | **fribidi** | `--enable-libfribidi` | expose an already-built lib | (already built for libass) | every cell that builds libass |
| 3 | **soxr** | `--enable-libsoxr` | un-defer existing script | `build_cmake_dep` (script exists) | all cells |
| 4 | **libxml2** | `--enable-libxml2` | new dependency | cmake, minimal | all cells |
| 5 | **libplacebo** | `--enable-libplacebo` | new dependency, heavy | meson; needs Vulkan + a SPIR-V shader compiler | Vulkan-capable cells only (mirrors existing Vulkan gating) |

Out of scope: Tier-2/3 libraries (libvmaf, libjxl, openjpeg, SRT/RIST, lcms2,
DNN backends, etc.) — separate future PRs. `fdk-aac` is permanently excluded
(nonfree, breaks the all-redistributable guarantee).

## Global Constraints

- **Local-first validation (hard rule).** Every library is sanity-checked with
  the local WSL + Docker `manylinux_2_28_x86_64` build (the `linux-x64` cell)
  **before** relying on GitHub Actions. A lib is not "done" for its task until a
  local build compiles it AND `ffmpeg -buildconf` (or `configure` output) shows
  its `--enable-*` flag actually took. GitHub CI is the final cross-platform
  proof, not the iteration loop. The all-platform libs (harfbuzz, fribidi, soxr,
  libxml2) are fully vettable locally; only libplacebo's non-x64 / mobile edges
  need CI.
- **No license regressions.** Each new lib's license must land only in cells it
  is compatible with. harfbuzz (MIT), fribidi (LGPL-2.1+), soxr (LGPL-2.1),
  libxml2 (MIT), libplacebo (LGPL-2.1+) are all (L)GPL-compatible in principle;
  libplacebo is additionally constrained by its Vulkan dependency (v3-only, no
  `lgplv2`, no Vulkan-less platforms) — see Task 5.
- **Static, PIC, no shared.** Follow the existing dep pattern: static libs into
  `${DEPS_DIR}`, `-fPIC`, discovered by FFmpeg via pkg-config.
- **Ledger-tracked versions.** Every new git-cloned lib is pinned in `deps.json`
  `.defaults` with `origin` + `tag` + `datasource`, so Renovate tracks it (add
  the recursive-manager coverage is automatic — it already scans all of
  `.defaults`). soxr and libplacebo/libxml2 pins must resolve via the loader.
- **Coverage matrix regenerates.** After wiring, `bash scripts/gen-matrix.sh`
  must show the new `✓`s and produce zero drift; the `docs-matrix` CI gate
  enforces it.
- **Cross-compat with impacted-release logic.** New default-block deps mean a
  future bump of any of them will (correctly) release every line that resolves
  it — no special handling needed; this is the existing behavior.

## Architecture / how it fits

The build is a chain of sourced `scripts/deps/<lib>.sh` scripts (`06_build_libraries.sh`
sources them in dependency order; each self-skips on a `BUILD_*` flag and appends
its `--enable-*` to `CONFIGURE_FLAGS`). Adding a library is a localized change:

1. **`deps.json`** — add the pin under `.defaults` (git-cloned libs only; soxr is
   already present).
2. **`scripts/steps/02_configure.sh`** — declare the `BUILD_*` default (usually
   `1` for all-platform libs; `0` then enabled per-platform for gated ones).
3. **`scripts/platform/<family>.sh`** — for a gated lib (libplacebo), turn the
   flag on only in the cells that qualify, next to the existing Vulkan gating.
4. **`scripts/deps/<lib>.sh`** — the build recipe (`build_cmake_dep` /
   meson / autotools helper) + `CONFIGURE_FLAGS+=(--enable-<lib>)`.
5. **`scripts/steps/06_build_libraries.sh`** — source it in dependency order.
6. **`bash scripts/gen-matrix.sh`** — regenerate the matrices.

### Per-library detail

**Task 1 — harfbuzz `--enable-libharfbuzz`.** harfbuzz is already meson-built in
`scripts/deps/harfbuzz.sh` (gated on `BUILD_LIBASS`). Append
`CONFIGURE_FLAGS+=(--enable-libharfbuzz)` there, under the same `BUILD_LIBASS`
guard, after install. Verify FFmpeg's pkg-config finds `harfbuzz.pc` in
`${DEPS_DIR}` and that `drawtext` reports harfbuzz. No `deps.json` change (already
pinned). Risk: near-zero.

**Task 2 — fribidi `--enable-libfribidi`.** Same shape as Task 1 in
`scripts/deps/fribidi.sh`. Append `--enable-libfribidi` under its existing guard.
Confirm the FFmpeg configure flag name against `configure --help` first (both
harfbuzz and fribidi appear as external-lib rows in the current matrices, so both
flags exist in FFmpeg 8 and 9). Risk: near-zero.

**Task 3 — soxr `--enable-libsoxr`.** The script `scripts/deps/soxr.sh` is
complete (`build_cmake_dep soxr … --enable-libsoxr`, gated on `BUILD_LIBSOXR`) and
soxr is already pinned in `deps.json`. Work: (a) uncomment the `soxr.sh` source
line in `06_build_libraries.sh`; (b) set `BUILD_LIBSOXR=1` in `02_configure.sh`
(all platforms); (c) **fix the deferred `-lm` link-ordering** — soxr's static link
needs libm; ensure FFmpeg's configure test passes by making soxr's pkg-config
expose `Libs.private: -lm` (or add `-lm` to `--extra-libs` for the static link).
The original deferral note is the reproduction: the `-lsoxr` configure check fails
on `-lm` ordering. Verify `--enable-libsoxr` survives configure locally. Risk: low
(one link-order detail).

**Task 4 — libxml2 `--enable-libxml2`.** New `scripts/deps/libxml2.sh` using
`build_cmake_dep libxml2` with a minimal feature set: no python, no icu, no lzma;
keep zlib (already built) if it helps DASH. Add `BUILD_LIBXML2=1` (all platforms)
in `02_configure.sh`, source it in `06_build_libraries.sh` after zlib, pin in
`deps.json` `.defaults` (origin `https://github.com/GNOME/libxml2.git`, a `v2.x`
tag, `git-tags` datasource), append `--enable-libxml2`. Enables the DASH demuxer
+ IMF. Risk: low–moderate (feature-flag tuning).

**Task 5 — libplacebo `--enable-libplacebo` (the long pole).** New
`scripts/deps/libplacebo.sh`, meson build. libplacebo needs (a) Vulkan headers +
loader (already built for whisper's ggml-vulkan) and (b) a runtime SPIR-V shader
compiler — **glslang or shaderc** — which is the main unknown: confirm what the
build environment already provides (the manylinux image builds `glslc`/glslang
from source for the Vulkan whisper backend; reuse it or add glslang as a
libplacebo dep). **Gate to Vulkan-capable cells only**: enable `BUILD_LIBPLACEBO`
in the same places `BUILD_VULKAN=1` is set (v3 family, non-mobile / platforms
where the Vulkan stack is built), inside `scripts/platform/<family>.sh` — never in
`lgplv2`/`v2` or on platforms without Vulkan. Pin in `deps.json`. Append
`--enable-libplacebo`. **This task starts with a local spike** to prove the
meson build + shader-compiler dependency on the `linux-x64` Vulkan cell before
wiring the gating — de-risking libplacebo early rather than at the end. **All or
nothing:** this PR ships all five libraries fully working or it does not merge.
If the spike surfaces a genuine blocker (shader-compiler chain too invasive, or
an unresolvable FFmpeg 8-vs-9 API conflict), we **stop and decide with the user**
— we do not merge a partial libplacebo, a stub, or the other four without it.
Risk: high.

## Testing

- **Per-task local gate:** WSL manylinux `linux-x64` build of the affected
  cell(s); assert the lib compiles and `ffmpeg -buildconf` contains the new
  `--enable-*`. For harfbuzz/fribidi, assert `drawtext` still runs. For soxr,
  assert `-af aresample=resampler=soxr` is accepted. For libxml2, assert the DASH
  demuxer is present (`ffmpeg -demuxers | grep dash`). For libplacebo, assert the
  `libplacebo` filter is listed (`ffmpeg -filters | grep libplacebo`).
- **Matrix:** `gen-matrix.sh` zero-drift after each task; new `✓`s appear in the
  right cells.
- **Existing gates unchanged:** ledger validator + `select-versions-test.sh` +
  shellcheck stay green (new deps.json entries must validate).
- **Full proof:** the branch's GitHub CI matrix (all 40 cells × build+test) is the
  final cross-platform sign-off, run once the local gates pass — not per iteration.

## Risks / open questions

1. **libplacebo shader compiler** — biggest unknown; resolved by the Task-5 spike.
   All-or-nothing: on a genuine blocker, stop and decide with the user — no
   partial merge, no shipping the other four without it.
2. **fribidi/harfbuzz flag names** — confirm exact `--enable-*` spelling against
   FFmpeg 8/9 `configure --help` in Task 1/2 (cheap).
3. **soxr `-lm`** — a known, bounded link-order fix; the deferral note is the repro.
4. **libplacebo API/version vs FFmpeg 8 and 9** — FFmpeg's `--enable-libplacebo`
   requires a minimum libplacebo API; pick a tag both majors accept (verify in the
   spike; may need a per-major `overrides` hold if 8 and 9 disagree).
