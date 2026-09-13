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

## Mac Catalyst

The same `.xcframework`s carry a **Mac Catalyst** slice, so an iOS app brought to the Mac links
the identical artifact with no extra download. It is a single universal slice covering both
Apple Silicon and Intel (the `maccatalyst-arm64` and `maccatalyst-x64` builds are `lipo`-fused
before packaging), and Xcode selects it automatically when the target's *Supports Mac Catalyst*
is on — there is nothing to configure. Hardware decode is **VideoToolbox**, same as iOS.

Catalyst is built against the macOS SDK with an `…-apple-ios14.0-macabi` target triple. **iOS
14.0 is the deployment floor**: an app with a higher minimum still links fine (a library minimum
below the app's is always compatible), but one targeting an earlier iOS will not.

### No TLS in the `lgplv2` Catalyst slice

This is the one place Catalyst differs from iOS in capability, and it is worth checking before
you pick a cell. **SecureTransport is unavailable on Mac Catalyst** — the SDK marks
`SSLRead`/`SSLWrite` "no longer supported" there, and FFmpeg's `tls_securetransport.c` does not
merely warn but fails to *compile*. So Catalyst cannot use the OS-native TLS that every other
Apple target relies on, and instead follows the Linux/Android ladder:

| cell | Catalyst TLS | iOS TLS |
|---|---|---|
| `gplv3` / `lgplv3` | OpenSSL 3.x (Apache-2.0, hence v3-only) | SecureTransport |
| `gplv2` | GnuTLS | SecureTransport |
| `lgplv2` | **none** | SecureTransport |

`https://`, `tls://` and `rtmps://` inputs therefore do not work in the **`lgplv2` Catalyst
slice**. There is no LGPLv2.1-compatible TLS backend to fall back on, which is the same gap the
`lgplv2` Linux and Android builds have. If your Catalyst app needs TLS *and* App-Store-safe
licensing, fetch over TLS with `URLSession` on the app side and hand FFmpeg the data, or use a
`v3` cell where the App Store is not a constraint. The iOS slices in the same
`.xcframework` are unaffected — only the Catalyst slice lacks it.

## Vulkan GPU filters (v3 only)

The **v3** iOS cells enable FFmpeg's Vulkan GPU filters (`scale_vulkan`, `gblur_vulkan`, …) —
there's no Metal equivalent in the filtergraph — by **statically linking MoltenVK**
(Vulkan-over-Metal) into the `libav*` frameworks. There is nothing extra to embed and no
environment variable to set: FFmpeg calls into MoltenVK directly, exactly like the other static
dependencies (whisper/ggml, kvazaar, opus). The artifact is the **same six `.xcframework`s** in
every cell.

MoltenVK links against `Metal`, `IOSurface`, `Foundation`, `QuartzCore`, `CoreGraphics` and
`UIKit` (its surface code imports `UIKit/UIView.h`, and MoltenVK disables Clang module
autolinking, so nothing pulls it in implicitly). Because the `libav*` frameworks are dynamic,
those are recorded as `libavutil`'s own dependencies and the linker resolves them for you. If
your build system links the frameworks in a mode that does not inherit transitive dependencies,
add them explicitly:

```
-framework Metal -framework IOSurface -framework Foundation -framework QuartzCore -framework CoreGraphics -framework UIKit
```

The `v2` / App-Store cells drop Vulkan entirely (MoltenVK is Apache-2.0, incompatible with
LGPLv2.1) and need none of the above. Whisper's Metal path and VideoToolbox decode are
unaffected in either series.

> Earlier documentation described embedding a separate `MoltenVK.xcframework` and
> `vulkan.xcframework` and pointing `VK_ICD_FILENAMES` at a bundled `MoltenVK_icd.json`. That
> path never worked, but not because MoltenVK itself was missing: the old `v3` iOS tarball
> genuinely shipped `MoltenVK.xcframework` (staged from `libMoltenVK.dylib` like any other
> framework, then converted to an xcframework by the release build) — seven `.xcframework`s,
> not six. What was never in the tarball were `vulkan.xcframework` (no Khronos loader was ever
> built for iOS) and `MoltenVK_icd.json` (upstream MoltenVK emits that file only for its macOS
> slice). Without the loader or the ICD JSON, FFmpeg's `dlopen` fallback could not have found
> `MoltenVK.framework/MoltenVK` under any of the leaf names it tries, so the old instructions
> could not have worked regardless of MoltenVK's presence. Static linking replaces all of it —
> if you are upgrading from the old instructions, `MoltenVK.xcframework` disappears from the
> artifact entirely; that is expected.

---

Back to the [install hub](./README.md) · [Android](./android.md) · [Whisper](./whisper.md) ·
[Development headers](./dev-headers.md)
