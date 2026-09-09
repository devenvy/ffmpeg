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

> `android-x64` and `linux-musl-arm64` were added in this branch (implemented 2026-09-08). Note for future estimates: the
> "resolve line + one platform block" pricing above was optimistic — a RID is currently
> hardcoded in ~15 files (CI matrices, the ledger validator, the coverage-matrix generator, and
> the per-dep host triples). Still mechanical, but budget accordingly.

## Bigger — new toolchain, new `platform/<family>.sh`
| OS/runtime | RID | Lift |
|---|---|---|
| **Web / WASM** | `browser-wasm` | Emscripten (`emcc`) toolchain; thread/syscall/HW-accel constraints. **Highest-value** for a media/DVR product — in-browser playback, no install (cf. `ffmpeg.wasm`). Own spike. |

## On-demand niche
`linux-riscv64`, `linux-ppc64le`, `linux-loongarch64`, `android-arm` (32-bit), Mac
Catalyst, FreeBSD (`freebsd-x64`).

## Known asymmetries (not platform gaps, but worth fixing)
- **iOS device vs. simulator filter set.** `04_select_license.sh` disables libplacebo
  on `ios-sim-arm64` only (the deliberately lean simulator slice), so the two slices
  inside one `.xcframework` expose different filters — a `libplacebo` filtergraph that
  works on device silently isn't available in the simulator. Consumers building a
  capability table need to know. Fixing it means paying the shaderc+libplacebo build
  cost on the simulator slice.

## Vocabulary (keep consistent)
- **RID** = atomic build target `{os}-{arch}[-variant]` — one RID → one build → one
  artifact; it's `${RID}`, the matrix axis, and the artifact-name middle. Use it for
  anything specific.
- **platform (family)** = toolchain bucket (`apple`/`linux`/`windows`/`android`/`wasm`)
  — what `platform/<family>.sh` keys on (`PLATFORM`). Many RIDs per platform.
- The OS name (tvOS, Web) is prose only — "add tvOS" = "add its RIDs". Avoid "target"
  (ambiguous).
