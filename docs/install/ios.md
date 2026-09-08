# iOS

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

The mobile artifacts are libraries to **link into an app**, not CLI tools. For the **Apple App
Store**, use the `lgplv2` cell: v3's anti-tivoization terms are incompatible with the App Store,
so LGPLv2.1 is the App-Store-safe series. The `v2` cells carry **no Vulkan** (Whisper still runs on
Metal on Apple); the `v3` cells add Vulkan via statically-linked MoltenVK — see [Vulkan GPU filters](#vulkan-gpu-filters-v3-only)
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

The **v3** iOS cells enable FFmpeg's Vulkan GPU filters (`scale_vulkan`, `gblur_vulkan`, …) —
there's no Metal equivalent in the filtergraph — by **statically linking MoltenVK**
(Vulkan-over-Metal) into the `libav*` frameworks. There is nothing extra to embed and no
environment variable to set: FFmpeg calls into MoltenVK directly, exactly like the other static
dependencies (whisper/ggml, kvazaar, opus). The artifact is the **same six `.xcframework`s** in
every cell.

MoltenVK links against `Metal`, `IOSurface`, `Foundation`, `QuartzCore` and `CoreGraphics`.
Because the `libav*` frameworks are dynamic, those are recorded as `libavutil`'s own
dependencies and the linker resolves them for you. If your build system links the frameworks
in a mode that does not inherit transitive dependencies, add them explicitly:

```
-framework Metal -framework IOSurface -framework Foundation -framework QuartzCore -framework CoreGraphics
```

The `v2` / App-Store cells drop Vulkan entirely (MoltenVK is Apache-2.0, incompatible with
LGPLv2.1) and need none of the above. Whisper's Metal path and VideoToolbox decode are
unaffected in either series.

> Earlier documentation described embedding a separate `MoltenVK.xcframework` and
> `vulkan.xcframework` and pointing `VK_ICD_FILENAMES` at a bundled `MoltenVK_icd.json`. That
> path never worked and those files were never shipped: the Khronos Vulkan loader does not build
> against the iOS SDK, so there was no loader to read the ICD file. Static linking replaces it.

---

Back to the [install hub](./README.md) · [Android](./android.md) · [Whisper](./whisper.md) ·
[Development headers](./dev-headers.md)
