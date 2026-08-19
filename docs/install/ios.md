# iOS

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

The mobile artifacts are libraries to **link into an app**, not CLI tools. For the **Apple App
Store**, use the `lgplv2` cell: v3's anti-tivoization terms are incompatible with the App Store,
so LGPLv2.1 is the App-Store-safe series. The `v2` cells carry **no Vulkan** (Whisper still runs on
Metal on Apple); the `v3` cells add Vulkan via MoltenVK — see [Vulkan GPU filters](#vulkan-gpu-filters-v3-only)
below and the [runtime-dependency overview](./README.md#runtime-dependencies).

## Install

**iOS** (`ffmpeg-{VERSION}-ios-lgplv2.tar.gz` for the App Store) — one `.xcframework` per `libav*`
library, each bundling the device (`ios-arm64`) and simulator (`ios-sim-arm64`) slices. The slices
are **dynamic** dylibs (the old static `.a` is gone) — the App-Store `lgplv2` build must be dynamic
to satisfy LGPLv2.1 §6, which requires the end user be able to relink the app against a modified
library; a dynamic framework satisfies that inherently. Add the frameworks to your Xcode target
(or a CocoaPods `vendored_frameworks`); Xcode selects the right slice and strips the simulator
slice from the shipped app automatically. Hardware decode uses **VideoToolbox**. The simulator
slice is decode-focused (no software encoders) — that path is for development; ship and test
encode/WebRTC-VP8/9 on a device.

## Vulkan GPU filters (v3 only)

The **v3** iOS cells ship **MoltenVK** (Vulkan-over-Metal) as its own `.xcframework` alongside the
Vulkan loader, so FFmpeg's Vulkan GPU filters (`scale_vulkan`, `gblur_vulkan`, …) work on iOS —
there's no Metal equivalent in the filtergraph. (The `v2` / App-Store cells drop it: MoltenVK is
Apache-2.0, incompatible with LGPLv2.1.) Embed the `MoltenVK.xcframework` + `vulkan.xcframework`
like the `libav*` ones, and set `VK_ICD_FILENAMES` to the bundled `MoltenVK_icd.json` before
initializing Vulkan (Whisper's Metal path and VideoToolbox decode are unaffected either way).

---

Back to the [install hub](./README.md) · [Android](./android.md) · [Whisper](./whisper.md) ·
[Development headers](./dev-headers.md)
