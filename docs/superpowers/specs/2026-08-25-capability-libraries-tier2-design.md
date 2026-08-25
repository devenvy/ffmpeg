# Capability Libraries (Tier-2 additions) — Design

**Status:** approved design, pre-plan
**Branch:** `feat/capability-libs-tier2` → one PR to `main`
**Predecessor:** [Tier-1 design](2026-08-24-capability-libraries-design.md) (merged as PR #9)
**Goal:** Enable four additional FFmpeg external libraries — ICC color
management, JPEG 2000, the VMAF quality-metric filter, and JPEG XL de/encode —
and complete libplacebo's color pipeline by turning on its lcms2 support now
that lcms2 is present. Closes the next tier of `—` rows in the coverage matrix.

## Scope

Four FFmpeg-facing libraries + two internal sub-dependencies + one libplacebo
enhancement, delivered in one branch / one PR:

| # | Library | FFmpeg flag | Nature | Build | Cells |
|---|---------|-------------|--------|-------|-------|
| 1 | **lcms2** | `--enable-lcms2` | new dependency | meson | all cells |
| 2 | **openjpeg** | `--enable-libopenjpeg` | new dependency | cmake | all cells |
| 3 | **libvmaf** | `--enable-libvmaf` | new dependency (C++) | meson | all cells |
| 4 | **brotli** | *(none — libjxl dep)* | new sub-dependency | cmake | all cells |
| 5 | **highway** | *(none — libjxl dep)* | new sub-dependency (C++) | cmake | all cells |
| 6 | **libjxl** | `--enable-libjxl` | new dependency (C++) | cmake; needs brotli + highway + lcms2 | all cells |
| 7 | **libplacebo lcms flip** | *(already `--enable-libplacebo`)* | enhancement | meson arg change | v3 Vulkan cells only |

Unlike Tier 1, all four FFmpeg-facing libs sit in FFmpeg's **normal**
external-library list (no `--enable-version3`, no `--enable-gpl`) and carry
permissive upstream licenses. **There is no per-license or per-platform
gating** — every one builds identically on all 40 cells. This is what made
these the "easy/medium" tier.

**License compatibility (verified — matters because these land statically in
the v2 / App-Store LGPLv2.1 lane, which must stay free of the Apache-2.0
incompatibility that keeps OpenSSL out):**

| Dep | License | v2-lane safe? |
|-----|---------|----------------|
| lcms2 | MIT | ✓ |
| openjpeg | BSD-2-Clause | ✓ |
| libvmaf | **BSD-2-Clause-Patent** | ✓ — its own text states it's "compatible with the GPL, version 2" + express patent grant |
| brotli | MIT | ✓ |
| **highway** | **dual Apache-2.0 OR BSD-3-Clause** | ✓ — we **elect BSD-3-Clause**; the Apache-2.0 option (v2-incompatible) is never exercised |
| libjxl | BSD-3-Clause | ✓ |

The only trap is **highway**: it is Apache-2.0-*or*-BSD-3, and Apache-2.0 is
exactly what bars OpenSSL from the v2 lane. Because highway offers BSD-3 as an
alternative, electing that option keeps libjxl (which links highway) clean on
all 40 cells. No dep here forces version3.

Out of scope (deferred to a later PR): **SRT and librist** (network transports;
their encryption/licensing surface needs its own decision — nocrypto-uniform vs
crypto-where-available — and is being deferred deliberately). `fdk-aac` remains
permanently excluded (nonfree).

## Global Constraints

- **Local-first validation (hard rule).** Every library is sanity-checked with
  the local WSL + Docker builds **before** GitHub Actions: `linux-x64`
  (manylinux), `win-x64` (ubuntu + mingw), and `android-*` (ubuntu + NDK) — the
  three families that are locally vettable. A lib is not "done" for its task
  until a local build compiles it AND `ffmpeg -buildconf` shows its `--enable-*`
  took. Only `osx`/`ios` genuinely need CI. (Tier-1 lesson: win/linux/android
  must be vetted locally before the PR opens.)
- **No lint suppression across the board.** shellcheck findings are fixed, or
  disabled **inline for the single line** with a reason comment — never a
  file-wide or repo-wide disable.
- **No license regressions.** All six new libs are (L)GPL-compatible on every
  cell; none is version3- or GPL-gated, so none may narrow a cell's license
  token. The coverage matrix must show the new `✓`s with zero drift.
- **Static, PIC, no shared.** Static libs into `${DEPS_DIR}`, `-fPIC`,
  discovered by FFmpeg via pkg-config, following the existing dep pattern.
- **C++ runtime is self-supplied.** libvmaf, highway, and libjxl are C++. Their
  dep scripts append the toolchain C++ runtime to `EXTRA_LIBS`
  (`-lstdc++` on GNU/Linux + mingw, `-lc++` on Apple + Android NDK), the same
  way `libplacebo.sh` does — and they must do it **themselves**, because libjxl
  is enabled on all 40 cells including the v2 / non-Vulkan cells where
  libplacebo is not built. Redundant appends are harmless.
- **Ledger-tracked versions.** Every new git-cloned lib is pinned in `deps.json`
  `.defaults` with `origin` + `tag` + `datasource` so Renovate tracks it. All
  six (lcms2, openjpeg, libvmaf, libjxl, brotli, highway) get entries.
- **Coverage matrix regenerates.** After wiring, `bash scripts/gen-matrix.sh`
  must produce zero drift; the `docs-matrix` CI gate enforces it.

## Architecture / how it fits

Identical mechanism to Tier 1 — a chain of sourced `scripts/deps/<lib>.sh`
scripts, each self-skipping on a `BUILD_*` flag and appending its `--enable-*`
to `CONFIGURE_FLAGS`. Per library:

1. **`deps.json`** — add the pin under `.defaults`.
2. **`scripts/steps/02_configure.sh`** — declare `BUILD_<LIB>=1` (all cells; no
   gating), each with the inline `# shellcheck disable=SC2034 # …sourced sibling`
   comment the existing `BUILD_*` vars carry.
3. **`scripts/deps/<lib>.sh`** — the build recipe + (for FFmpeg-facing libs)
   `CONFIGURE_FLAGS+=(--enable-<lib>)`. Sub-deps (brotli, highway) append no
   flag; they only install into `${DEPS_DIR}` for libjxl to find.
4. **`scripts/steps/06_build_libraries.sh`** — source in dependency order.
5. **`bash scripts/gen-matrix.sh`** — regenerate the matrices.

### Dependency ordering

The one non-trivial chain is libjxl. Source order in `06_build_libraries.sh`:

```
… lcms2 …            # early: before libjxl AND before libplacebo (Task 7)
… brotli → highway → libjxl …   # libjxl last of its chain
… libvmaf … openjpeg …          # independent, anywhere
… shaderc → libplacebo          # existing; libplacebo now sees lcms2 (Task 7)
```

lcms2 must be sourced before both libjxl and libplacebo. brotli and highway
must be sourced before libjxl.

### Per-library detail

**Task 1 — lcms2 `--enable-lcms2`.** New `scripts/deps/lcms2.sh`, meson build
(Little CMS 2 ships `meson.build`; FFmpeg needs `lcms2 >= 2.13`, pin
`lcms2.19.1`). Args: `-Djpeg=disabled -Dtiff=disabled -Dtests=disabled
-Dutils=false -Dversionedlibs=false`. **License landmine:** lcms2's two meson
plugins `fastfloat` and `threaded` are **GPL-3.0** (upstream option text: "use
only if GPL 3.0 is acceptable") — both default to `false` and **must stay
off**; enabling either would inject GPLv3 into every cell and break both the v2
lane and all LGPL builds. So the core MIT library only. `versionedlibs=false`
per upstream's Android-cross guidance (moot under `--default-library=static`,
set for safety). Enables FFmpeg's ICC profile support → `iccdetect` / `iccgen`
filters + ICC in avcodec. `BUILD_LCMS2=1` all cells. Also unblocks Tasks 6 and
7. Risk: low.

**Task 2 — openjpeg `--enable-libopenjpeg`.** New `scripts/deps/openjpeg.sh`,
`build_cmake_dep openjpeg -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF` (core
`libopenjp2` has no required external deps; `BUILD_CODEC=OFF` drops the
png/tiff-linked CLI tools). FFmpeg needs `libopenjp2 >= 2.1.0`. Adds external
JPEG 2000 encode/decode. `BUILD_LIBOPENJPEG=1` all cells. Risk: low.

**Task 3 — libvmaf `--enable-libvmaf`.** New `scripts/deps/libvmaf.sh`, meson
build (source lives in `libvmaf/` subdir of the repo — `meson setup` runs from
there). `-Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true -Denable_float=true`; VMAF's
default prediction models are compiled into the library, so no runtime model
files ship. C++ → append the C++ runtime to `EXTRA_LIBS`. FFmpeg needs
`libvmaf >= 2.0.0`; adds the `vmaf` quality-metric filter. Skip the optional
`libvmaf_cuda` probe (no CUDA in our deps). `BUILD_LIBVMAF=1` all cells.
Risk: low–moderate (meson subdir + C++ runtime).

**Task 4 — brotli (sub-dep, no FFmpeg flag).** New `scripts/deps/brotli.sh`,
`build_cmake_dep brotli -DBROTLI_DISABLE_TESTS=ON`. Installs
`libbrotlicommon/enc/dec` + pkg-config for libjxl. C library — no C++ runtime.
`BUILD_BROTLI=1` all cells. No `CONFIGURE_FLAGS` change. Risk: low.

**Task 5 — highway (sub-dep, no FFmpeg flag).** New `scripts/deps/highway.sh`,
`build_cmake_dep highway -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF
-DHWY_ENABLE_CONTRIB=OFF`. Installs `libhwy` + pkg-config for libjxl. C++ SIMD
→ append the C++ runtime to `EXTRA_LIBS`. `BUILD_HIGHWAY=1` all cells. No
`CONFIGURE_FLAGS` change. Risk: low–moderate (SIMD cross-compile per arch).

**Task 6 — libjxl `--enable-libjxl`.** New `scripts/deps/libjxl.sh`,
`build_cmake_dep libjxl` with the system deps forced on and everything else off:
`-DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF
-DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF
-DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JPEGLI=OFF
-DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON
-DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DBUILD_TESTING=OFF`.
Uses the brotli (Task 4), highway (Task 5), and lcms2 (Task 1) we built — no
vendored submodules. C++ → append the C++ runtime to `EXTRA_LIBS`. FFmpeg needs
`libjxl >= 0.7.0` **and** `libjxl_threads >= 0.7.0` (both pkg-config modules
come from the one build). Adds JPEG XL de/encode. `BUILD_LIBJXL=1` all cells.
Risk: moderate (the multi-dep chain — de-risk with a local spike before wiring,
same as Tier-1 libplacebo).

**Task 7 — libplacebo lcms flip.** In `scripts/deps/libplacebo.sh`, change
`-Dlcms=disabled` → `-Dlcms=enabled`. libplacebo now links the lcms2 built in
Task 1 for ICC / Dolby-Vision-aware tone-mapping. Only affects the v3 Vulkan
cells libplacebo already builds on; lcms2 is present there (all cells). Verify
libplacebo's meson finds `lcms2.pc` and the build still links. Risk: low.

## Testing

- **Per-task local gate:** WSL build of the affected cell(s) on linux-x64 (+
  win-x64 / android for anything with cross-compile edges — highway SIMD,
  libjxl); assert the lib compiles and `ffmpeg -buildconf` contains the new
  `--enable-*`. Capability probes:
  - lcms2 → `ffmpeg -filters | grep -E 'iccdetect|iccgen'`
  - openjpeg → `ffmpeg -encoders | grep jpeg2000` / `-decoders | grep jpeg2000`
    shows the `libopenjpeg` variant
  - libvmaf → `ffmpeg -filters | grep vmaf`
  - libjxl → `ffmpeg -codecs | grep jpegxl` (de/encode via libjxl)
  - libplacebo (Task 7) → still lists `libplacebo` filter; build log shows
    lcms2 enabled
- **Matrix:** `gen-matrix.sh` zero-drift after wiring; new `✓`s appear on all
  cells (and libplacebo unchanged).
- **Existing gates unchanged:** ledger validator + `select-versions-test.sh` +
  shellcheck stay green; the six new `deps.json` entries must validate.
- **Full proof:** the branch's GitHub CI matrix (all 40 cells × build+test) is
  the final cross-platform sign-off, run once local gates pass.

## Risks / open questions

1. **libjxl dependency chain** — the only non-trivial piece; brotli + highway +
   lcms2 must all be found by libjxl's cmake via `JPEGXL_FORCE_SYSTEM_*`.
   De-risk with a local spike (build the chain on linux-x64, confirm
   `--enable-libjxl` survives configure) before wiring the gating/matrix.
2. **highway SIMD cross-compile** — highway dispatches per-arch SIMD; confirm it
   cross-compiles cleanly for arm64/armhf/android and the mingw/NDK toolchains
   (it's widely used and supports these, but it's the most arch-sensitive dep).
3. **lcms2 meson version** — ensure the pinned tag ships `meson.build` and is
   `>= 2.13` (2.14+ have meson; pick a current 2.1x tag).
4. **libvmaf meson subdir** — source is under `libvmaf/`; the setup must run
   from the subdir, not the repo root (a known libvmaf packaging quirk).
5. **C++ runtime on all-cells libs** — libjxl ships on v2 / non-Vulkan cells
   where libplacebo doesn't; its dep script must self-supply `-lstdc++`/`-lc++`
   rather than lean on libplacebo/whisper having added it.
