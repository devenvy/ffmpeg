# Development

## Project structure

```
ffmpeg/
  versions.txt              # Maintained FFmpeg versions, one per line (e.g. 8.1.2)
  scripts/
    build.sh                # Orchestrator — sources the steps below, in order
    lib.sh                  # Shared build helpers (cmake wrapper, build_cmake_dep)
    steps/NN_*.sh           # One numbered file per build phase (configure → deps → ffmpeg →
                            #   stage → verify → legal); build.sh sources them in sequence
    deps/<lib>.sh           # One script per third-party library — self-guarding on a BUILD_*
                            #   flag, appends its --enable-* to the FFmpeg configure
    test.sh                 # Per-RID test dispatcher → test/<platform>.sh
    test/<platform>.sh      # Per-platform checks; test/lib.sh = shared helpers; smoke.c = the
                            #   portable runtime program run on device/emulator/simulator
    gen-matrix.sh           # Regenerates the coverage matrices from the scripts + each version's configure
    gen-coverage.sh         # Lists FFmpeg libraries we don't build (used by check-updates)
  docs/matrix/README.md     # Auto-generated matrix index (do not edit by hand)
  docs/matrix/              # Auto-generated coverage matrix per FFmpeg major × license
  .github/workflows/        # CI/CD workflows
```

**How the build is organized.** `scripts/build.sh` is a thin orchestrator: it resolves the
inputs, then sources each `steps/NN_*.sh` in order (they share one shell environment). Step 6
(`06_build_libraries.sh`) sources every active `deps/<lib>.sh`; each dependency script builds
one static library and appends its `--enable-<lib>` flag. To add a library you write one
`deps/*.sh`, add a `BUILD_*` switch in `02_configure.sh`, and list it in `06_build_libraries.sh`
— nothing else changes, and the coverage matrix + `build-info.txt` pick it up automatically.

**Maintaining multiple versions.** `versions.txt` is the source of truth for which FFmpeg
releases this repo builds — one exact upstream version per line. Each line is built and
released independently (see [Releases](README.md#releases)), so several major/minor lines
(e.g. `9.0` and `8.1.2`) can be maintained in parallel. Add a line to start maintaining a new
version; `check-updates.yml` bumps each line's point release and proposes new majors
automatically.

The build downloads a stock upstream FFmpeg release tarball and compiles it — there is no
vendored FFmpeg source and no patches. All customization is in the `scripts/` tree (which
third-party libraries to build and link, and the per-platform configure flags).

## Build variants

Each release covers every platform × license build variant. Each RID is built in **four**
license cells — `gplv3`, `gplv2`, `lgplv3`, `lgplv2` — not one:

| RID | Platform | Build method | Output |
|---|---|---|---|
| `linux-x64` | Linux glibc x86_64 | manylinux container | shared libs + `ffmpeg`/`ffprobe` |
| `linux-arm64` | Linux glibc ARM64 | manylinux container (ARM runner) | shared libs + `ffmpeg`/`ffprobe` |
| `linux-armhf` | Linux glibc ARMv7 (Raspberry Pi) | Cross-compiled | shared libs + `ffmpeg`/`ffprobe` |
| `linux-musl-x64` | Alpine / musl x86_64 | Native (Alpine container) | shared libs + `ffmpeg`/`ffprobe` |
| `win-x64` | Windows x86_64 | Cross-compiled (mingw-w64) | DLLs + `.lib` import libs + `ffmpeg.exe`/`ffprobe.exe` |
| `osx-x64` | macOS Intel | Native | dylibs + `ffmpeg`/`ffprobe` |
| `osx-arm64` | macOS Apple Silicon | Native | dylibs + `ffmpeg`/`ffprobe` |
| `android-arm64` | Android arm64-v8a | Cross-compiled (Android NDK) | `lib/arm64-v8a/*.so` (unversioned) + `include/`, no binaries |
| `ios-arm64` | iOS device (arm64) | Cross-compiled (iOS SDK, on macOS) | dynamic `*.dylib` + `include/`, no binaries |
| `ios-sim-arm64` | iOS simulator (Apple Silicon) | Cross-compiled (simulator SDK) | dynamic `*.dylib` + `include/` (lean slice) |

Each RID is built in 4 license cells: `{rid}-{gplv3,gplv2,lgplv3,lgplv2}` (10 RIDs × 4 = 40 build
jobs). The two axes are **family** — `gpl` (`--enable-gpl`, includes x264 + x265) vs `lgpl`
(`--disable-gpl`, kvazaar for HEVC, no x264/x265) — and **version** — `v3` (`--enable-version3`,
may link Apache-2.0 deps like OpenSSL and Vulkan) vs `v2` (GPLv2 / LGPLv2.1, no `--enable-version3`,
no Vulkan). The `lgplv2` series is the App-Store-safe one (v3's anti-tivoization terms are
incompatible with the Apple App Store); it exists chiefly for the iOS App Store build. The two iOS
slices (`ios-arm64`, `ios-sim-arm64`) are published as one combined `.xcframework` per license cell.
Desktop targets additionally ship a `-dev` archive (headers, plus MSVC import libraries on Windows).

**Why build the glibc Linux targets in a container?** `linux-x64` and `linux-arm64` build inside
the **stock** [`manylinux_2_28`](https://github.com/pypa/manylinux) image (AlmaLinux 8, glibc
2.28) — pulled unmodified from `quay.io/pypa`, no custom image to maintain — via `docker run`
from an ordinary Ubuntu runner. That pins the binaries' runtime **glibc floor low** (they run on
RHEL/Alma 8+, Debian 10+, Ubuntu 18.10+) while still compiling with a modern gcc-toolset-14 — a
combination a stock Ubuntu runner can't give (new Ubuntu = high glibc floor; old Ubuntu = a gcc
too old for the C++ deps). The bare image is provisioned at build time by `03_install_packages.sh`
(its `BUILD_CONTAINER=manylinux` branch: dnf toolchain + meson from a bundled CPython + patchelf
0.18 + glslc from source), so nothing is baked into an image. `checkout`/test/upload stay on the
host, so the test step also proves the low-floor binary runs on the runner's newer glibc. Every
other target keeps its runner (`linux-armhf`/`win-x64`(build)/`android` on Ubuntu, `linux-musl`
in an Alpine container, `osx`/`ios` on macOS).

**Why cross-compile Windows from Linux?** `win-x64` is built with the mingw-w64 toolchain on a
Linux runner — the same approach the upstream FFmpeg project and every major FFmpeg build
service use. It keeps Linux + Windows + Android on one host and one build script, and it loses
nothing: Media Foundation, D3D11VA/DXVA2, AMF, NVENC and QSV all compile against the mingw-w64
SDK headers. MSVC consumers are handled by generating a COFF import library (`.lib`) per DLL
via `gendef` + `llvm-dlltool`, so a Visual Studio / CMake project links the DLLs directly.

**Delivery format:**
- **Desktop** — flat runtime tarball: binaries, shared libraries, and `legal/` only (no
  headers). Dev files ship separately as `ffmpeg-{ver}-{variant}-dev.tar.gz` (the `include/`
  headers, plus `lib/*.lib` MSVC import libraries for Windows), so the runtime download stays
  lean and consumers don't pick up headers/import libs at runtime.
- **Android** — tarball with `include/` headers + jniLibs-style `lib/arm64-v8a/*.so` + `legal/`
  (link-only artifact, so headers stay in the main tarball).
  Sonames are normalized to unversioned `lib*.so` so Android's loader/Gradle accept them.
- **iOS** — one `.xcframework` per `libav*` library, bundling the device (`ios-arm64`) and
  simulator (`ios-sim-arm64`) slices, packaged per license with headers + `legal/`. The slices
  are **dynamic** dylibs (iOS's old static `.a` is gone — every platform now ships dynamic
  libraries). Dynamic is required for the App-Store `lgplv2` build: LGPLv2.1 §6 obliges the end
  user to be able to relink the app against a modified library, which a dynamic framework
  satisfies inherently but static linking cannot (it would force shipping object files). The
  individual iOS slices are **not** published on their own — they are delivered as xcframeworks.

Mobile builds drop the `ffmpeg`/`ffprobe` executables (the libraries are consumed directly)
and enable platform hardware decode (MediaCodec / VideoToolbox).

## LGPL vs GPL

**LGPL builds** can be used in proprietary/closed-source applications without releasing your
application source, as long as FFmpeg remains dynamically linked (shared libraries). LGPL
builds **cannot include GPL-licensed encoder libraries** like libx264 or libx265:

- H.264/H.265 **decoding** (software) works normally — FFmpeg's built-in decoders are
  LGPL-compatible.
- H.264/H.265 **hardware encoding** (NVENC, VAAPI, QSV, VideoToolbox, MediaFoundation, AMF)
  works normally — these are API wrappers, not GPL code.
- **Software H.264 encoding** is available in every build via **OpenH264** (BSD, no GPL
  obligation), and **software H.265 encoding** via **kvazaar** (BSD) — the permissive
  counterparts that give the LGPL builds software encoders without a GPL obligation (and a
  fallback where hardware HEVC encode isn't available). The GPL builds' **libx264/libx265** are
  higher quality, so where the GPL is acceptable they remain the better choice; kvazaar is
  dropped there (x265 supersedes it).
- **VP8/VP9 encoding** (libvpx) and **AV1 encoding** (libaom, SVT-AV1) are available in all
  builds — those are BSD-licensed and LGPL-compatible.

**GPL builds** include **libx264** (H.264 software encoder) and **libx265** (H.265 software
encoder), enabling full software encoding. Distributing an application that uses a GPL build
requires that application to comply with the GPL (source disclosure).

**Rule of thumb:** ship LGPL if you link FFmpeg into a closed-source app; use GPL for internal
tooling or GPL-compatible projects that need software H.264/H.265 encoding.

**License version — v3 and v2 both ship.** The matrix carries both a v3 and a v2 line of each
family, four cells in total (GPLv3, GPLv2, LGPLv3, LGPLv2.1). The **v3** cells set
`--enable-version3`, which lets them link Apache-2.0 deps (OpenSSL 3.x for TLS, and Vulkan) —
Apache-2.0 is compatible with version 3 of the (L)GPL but not with 2.1/2. The **v2** cells omit
`--enable-version3` (so GPLv2 / LGPLv2.1) and drop Vulkan; whisper falls back to CPU where v3
used the Vulkan backend. The v2 series is the App-Store-safe one: v3's install-information
(anti-tivoization) terms are incompatible with the Apple App Store, so the iOS App Store build is
`lgplv2`. LGPL (either version) still grants the dynamic-linking permission — ship it inside a
proprietary app as a replaceable shared library. `04_select_license.sh` selects the cell and
`10_write_legal.sh` writes each artifact's `legal/LICENSE-NOTICE.txt` stating the effective
license and why, shipping the matching COPYING text (GPLv2/GPLv3/LGPLv2.1/LGPLv3 as appropriate).
Every bundled dependency's own license also ships under `legal/licenses/<dep>/`.

## Build script

The unified build script (`scripts/build.sh`) accepts environment variables:

| Variable | Required | Default | Values |
|---|---|---|---|
| `BUILD_RID` | Yes | — | `linux-x64`, `linux-arm64`, `linux-armhf`, `linux-musl-x64`, `win-x64`, `osx-x64`, `osx-arm64`, `android-arm64`, `ios-arm64`, `ios-sim-arm64` |
| `BUILD_LICENSE` | No | `lgpl` | `lgpl`, `gpl` — family (`--disable-gpl` vs `--enable-gpl`) |
| `BUILD_LICENSE_VERSION` | No | `3` | `3` (`--enable-version3`) or `2` (GPLv2 / LGPLv2.1, no version3) |
| `ANDROID_NDK_HOME` | for `android-*` | — | path to the Android NDK (r26+) |
| `FFMPEG_VERSION` | No | first line of `versions.txt` | e.g., `8.1.2` |
| `SKIP_DEPS` | No | `false` | `true`, `false` — skip apt/apk/brew dependency installation |

`android-*` builds run on Linux/WSL with the NDK; `ios-*`/`osx-*` builds run on macOS with the
Xcode command-line tools.

### Local build examples

```bash
# Linux x64, GPL, skipping apt install (deps already present)
SKIP_DEPS=true BUILD_RID=linux-x64 BUILD_LICENSE=gpl bash scripts/build.sh
# Output: artifacts/linux-x64/native/

# Windows x64, LGPL, cross-compiled with mingw-w64 (on Linux)
SKIP_DEPS=true BUILD_RID=win-x64 BUILD_LICENSE=lgpl bash scripts/build.sh

# Android arm64, LGPL (needs the NDK; runs on Linux/WSL)
ANDROID_NDK_HOME=/path/to/android-ndk-r26d \
  SKIP_DEPS=true BUILD_RID=android-arm64 BUILD_LICENSE=lgpl bash scripts/build.sh
# Output: artifacts/android-arm64/native/  (include/ + lib/arm64-v8a/*.so)

# iOS device, LGPLv2.1 (the App-Store-safe cell: no version3, no Vulkan, no TLS)
SKIP_DEPS=true BUILD_RID=ios-arm64 BUILD_LICENSE=lgpl BUILD_LICENSE_VERSION=2 bash scripts/build.sh
```

The build ends with an in-process static verification gate (`09_verify_build.sh`, all RIDs)
that fails on regressions: the Whisper filter is enabled, `lgpl` builds contain no GPL
components, the platform hardware decoder is registered, mobile headers are present, and Android
sonames are unversioned.

## Testing

Post-build, `scripts/test.sh <RID> <artifact-native-dir>` dispatches to `test/<platform>.sh`
(shared helpers in `test/lib.sh`). Coverage is layered so *something* runs on every target,
however it's built:

- **Structural (every target, any host).** Reads the artifact without executing it: arch/format,
  SONAMEs, exported `av*_version` symbols, the license boundary and enabled features (harvested
  from FFmpeg's embedded `./configure` string), the TLS backend, and platform specifics
  (Android `libmediandk`/`libc++_shared.so`, unversioned sonames, headers present). `nm`/
  `readelf`/`strings` read foreign-arch binaries fine, so this works from any host.
- **Functional (where the target runs on the runner).** Executes `ffmpeg`: version, filter/
  decoder/protocol enumeration (asserting `https`/`tls` are present on every cell **except**
  `lgplv2`, which drops TLS and is verified to have none), and an encode→decode round-trip — natively
  on matching hosts (Linux on Linux, **Windows on a real Windows runner**, macOS on macOS), or via
  **qemu-user** for cross Linux arches. Execution is the primary signal; a missing binary-
  inspection tool (e.g. `file` on a minimal shell) skips a structural check rather than failing.
- **Mobile (no `ffmpeg` binary).** `test/smoke.c` is a portable libav program (encode→decode +
  whisper filter, plus `https`/`tls` where the cell has a TLS backend — skipped on `lgplv2`)
  compiled against the artifact. Compiling+linking it with no
  undefined symbols is a real **ABI check** that runs in the `test-mobile` workflow (NDK/Xcode
  present on the runner).
  Executing it is the **runtime** layer: `test/ios-run.sh` runs it on the iOS **simulator** via
  `simctl` (native on the Apple-Silicon runner), and `test/android-run.sh` runs it on an
  **arm64-v8a emulator**. The on-device run is what caught the missing `libc++_shared.so`
  bundling — a gap structural checks can't see.

## CI/CD

- **CI** (`ci.yml`) — On pull requests to `main`. A `resolve` job diffs the PR and builds only
  the versions it actually affects: a `scripts/**` change → all tracked versions; a
  `versions.txt`-only change → just the added/changed lines (so an add-9 PR builds only 9);
  docs-only → nothing. It then chains build → desktop test + mobile test against the uploaded
  artifacts. A single `ci-passed` gate job — green when the build/test jobs pass *or are skipped*
  (a docs-only PR builds nothing) — is the one required status check for branch protection. PR
  runs use `fail_fast` (one failed job cancels the rest to save minutes); release builds do not.
- **Release** (`release.yml`) — Runs on pushes to `main` that change `versions.txt` or a build
  recipe (`scripts/**`, excluding tests), and can also be started manually. A `prepare` job
  decides which lines to (re)build: a `versions.txt` edit → only the added/changed lines; a
  build-recipe change → every tracked line (the recipe applies to all — e.g. a bundled-lib
  security fix should reach every version). Tests gate the release (build → test + test-mobile
  must pass before the tag/publish). Each selected version gets its own `{version}.{build}` tag +
  GitHub Release — all variants built and packaged (desktop/Android tarballs; a `publish-ios` job
  assembles the iOS `.xcframework`s on a macOS runner). Only the **highest** tracked line is
  marked GitHub "Latest" (`--latest=true`), so an older-major maintenance release never steals the
  badge. Bumping one line publishes only that line.
- **Check Updates** (`check-updates.yml`) — Runs daily and can also be started manually. For
  each line in `versions.txt` it detects a newer point release in that major.minor series and
  opens a bump PR; if a newer major exists upstream than anything tracked, it opens a PR adding
  that major as a new parallel line. PRs use the `UPDATE_PR_TOKEN` secret so normal PR CI runs;
  merging one triggers the release workflow for the affected line(s).

**Build/test are separate reusable workflows** (`build.yml`, `test.yml`, `test-mobile.yml`), so
tests can grow and re-run without rebuilding. `build.yml` builds each variant and uploads its
artifact; `test.yml` (desktop: linux/win/macOS **execution** — Windows on a real Windows runner)
and `test-mobile.yml` (Android/iOS ABI link-check + emulator/simulator) download those artifacts
and run. Both `ci.yml` (PRs) and `release.yml` chain build → test + test-mobile; in `release.yml`
a failing test blocks the tag/publish. Mobile is split out because its emulator/simulator setup is
slow and fragile and shouldn't gate the fast desktop checks.

For manual releases, run the **Release** workflow from GitHub Actions. Do not create a GitHub
Release by hand, because manual Releases do not build or attach artifacts.

## Hardware acceleration by platform

Which hardware acceleration each platform builds — CUDA/NVENC/NVDEC, VAAPI, QSV, V4L2-M2M,
D3D11VA/DXVA2, AMF, MediaFoundation, MediaCodec, VideoToolbox/AudioToolbox, Vulkan — is enumerated
**per cell** in the auto-generated [build matrix](docs/matrix/README.md) (its Hardware-acceleration
section), which is the single source of truth — this doc doesn't duplicate it (that only drifts
stale). What's worth saying here is *how* those libraries are packaged into the artifact:

The glibc Linux builds (`linux-x64`/`arm64`/`armhf`) are **self-contained**: the VAAPI/QSV/libdrm
dispatch libraries are static-linked and the Vulkan loader is bundled, so `ffmpeg` starts on a
bare system with no package install. (The musl build still links these dynamically — see
[Runtime dependencies](docs/install/linux.md#runtime-dependencies).) NVIDIA (CUDA/NVENC/NVDEC) and
Vulkan are loaded at runtime via `dlopen`, not linked into the binary, so they are silently
unavailable if absent. To actually **use** hardware acceleration you still need the GPU
**driver** (Intel `intel-media-va-driver`, AMD `mesa-va-drivers`, the NVIDIA driver, or
`mesa-vulkan-drivers` for Vulkan).

Vulkan is a **v3-only** feature (the `v2` cells drop it — Vulkan-Headers are Apache-2.0). It's
provided by the system driver on Windows/Android, a bundled libc-only loader on glibc Linux, and
**MoltenVK** (Vulkan-over-Metal) on macOS/iOS. It powers FFmpeg's GPU filters (and, off Apple,
Whisper's GPU backend). The auto-generated [build matrix](docs/matrix/README.md) is the exact
per-cell source of truth.

## Software codec & utility libraries

Every build links a set of LGPL-compatible (BSD/MIT/permissive) codec and utility libraries —
AV1 (dav1d/libaom/SVT-AV1), VP8/VP9, Opus, MP3 (LAME), Vorbis, OpenH264, WebP, zimg, libass,
FreeType, whisper.cpp, a TLS backend, and **kvazaar** (permissive H.265 encode — the LGPL
counterpart to x265, and a software fallback where hardware HEVC encode isn't available). The
**GPL builds** swap in **libx264** and **libx265** (higher-quality H.264/H.265) and drop
kvazaar, which x265 supersedes.

**Which library is built on which platform — and which ones we deliberately don't build — lives
in the auto-generated [docs/matrix/README.md](docs/matrix/README.md)**, an index to one matrix per
maintained FFmpeg major × license cell (`docs/matrix/ffmpeg-<major>-<gplv3|gplv2|lgplv3|lgplv2>.md`). It derives from
the build scripts and each version's own configure, so it never drifts; the per-matrix footnotes
explain the platform gaps (SVT-AV1 needs 64-bit; fontconfig is native on Windows/Apple; etc.),
and the index flags libraries that differ between versions. Don't restate that coverage in prose
here — update the generator, not this file.

Two build-mechanics notes that aren't about coverage:
- **TLS backend (depends on the cell) on Linux/Android:** the **v3** cells build **OpenSSL**
  (Apache-2.0, allowed by `--enable-version3`); the **gpl-2** cell builds **GnuTLS** (which pulls
  in GMP + nettle + libtasn1 — fine under GPLv2); the **lgpl-2** cell has **no TLS at all** (no
  `https`/`tls`), because GnuTLS's GMP + nettle deps are dual LGPLv3+/GPLv2+ (never LGPLv2.1) and
  no other FFmpeg TLS backend is LGPLv2.1-compatible, so a genuine LGPLv2.1 build must drop TLS.
  **Windows/Apple** are unaffected by the v2/v3 split: Windows uses OS-native **SChannel** and
  Apple **SecureTransport** in every cell, with no dependency. (`--disable-autodetect` is set, so
  each backend is requested explicitly.) See [License version](#lgpl-vs-gpl).
- **x265** is pinned to **3.6** (4.0+ has broken ARM NEON intrinsics) and built with
  `-DENABLE_ASSEMBLY=OFF` under the NDK/iOS toolchains, where its aarch64 asm won't assemble.

## Roadmap

- **Other libraries** — the `—` rows in [docs/matrix/README.md](docs/matrix/README.md) list every
  library FFmpeg supports that we don't build (SRT/RIST, VMAF, JXL, …). `check-updates.yml`
  re-surfaces this gap on each version bump.
