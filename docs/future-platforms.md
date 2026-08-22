# Future platforms (backlog)

Candidate RIDs to add **after** the current work lands (v2 license series, Apple
dynamic frameworks, MoltenVK-macOS). The platform-hoist refactor makes each of these a
localized change — a `resolve` line + a `platform/<family>.sh` block — not a per-dep
edit. See the vocabulary note at the bottom.

## Trivial — existing platform + existing toolchain (resolve line + one block)
| OS/runtime | RID(s) | Platform | Notes |
|---|---|---|---|
| tvOS | `tvos-arm64`, `tvos-sim-arm64` | apple | appletvos SDK; VideoToolbox/Metal; same LGPLv2.1 App-Store story as iOS. Cheapest, plausibly real (big-screen viewing). |
| visionOS | `visionos-arm64`, `visionos-sim-arm64` | apple | xros SDK. Emerging, small market. |
| Linux musl arm64 | `linux-musl-arm64` | linux | Alpine containers on ARM. |
| Android x64 | `android-x64` | android | emulator / x86 devices. |

## Bigger — new toolchain, new `platform/<family>.sh`
| OS/runtime | RID | Lift |
|---|---|---|
| **Web / WASM** | `browser-wasm` | Emscripten (`emcc`) toolchain; thread/syscall/HW-accel constraints. **Highest-value** for a media/DVR product — in-browser playback, no install (cf. `ffmpeg.wasm`). Own spike. |
| Windows ARM64 | `win-arm64` | Needs `llvm-mingw` (mingw-w64 arm64 is weak). Windows-on-ARM is growing. |

## On-demand niche
`linux-riscv64`, `linux-ppc64le`, `linux-loongarch64`, `android-arm` (32-bit), Mac
Catalyst, FreeBSD (`freebsd-x64`).

## Vocabulary (keep consistent)
- **RID** = atomic build target `{os}-{arch}[-variant]` — one RID → one build → one
  artifact; it's `${RID}`, the matrix axis, and the artifact-name middle. Use it for
  anything specific.
- **platform (family)** = toolchain bucket (`apple`/`linux`/`windows`/`android`/`wasm`)
  — what `platform/<family>.sh` keys on (`PLATFORM`). Many RIDs per platform.
- The OS name (tvOS, Web) is prose only — "add tvOS" = "add its RIDs". Avoid "target"
  (ambiguous).
