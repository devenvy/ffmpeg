# Android

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

The mobile artifacts are libraries to **link into an app**, not CLI tools. Use an `lgpl`
variant for anything shipped (a GPL build obligates your whole app to the GPL). For the **Apple
App Store**, use the `lgplv2` cell — see [iOS](./ios.md); on Android note that `lgplv2` carries no
Vulkan and no TLS backend (see the [runtime-dependency overview](./README.md#runtime-dependencies)).

## Install

**Android** (`ffmpeg-{VERSION}-android-arm64-lgplv3.tar.gz`) — a tarball with:
- `include/` — the `libav*` headers to compile against.
- `lib/arm64-v8a/*.so` — shared libraries with unversioned sonames; drop them into your
  module's `src/main/jniLibs/arm64-v8a/` (or point `jniLibs.srcDirs` at `lib/`).
- `legal/` — the LGPL text plus each bundled dependency's license under `legal/licenses/<dep>/`
  (ship it).

The `lib/arm64-v8a/` folder includes **`libc++_shared.so`**. `libavcodec`/`libavfilter`
depend on it at runtime — the codec libraries built from C++ (OpenH264, libass, whisper.cpp)
are linked with `c++_shared`, so the shared NDK C++ runtime must ship alongside them or the app
crashes on load. Keep it in `jniLibs`. If your app (or another native dependency) already
bundles its own `libc++_shared.so`, they are interchangeable — Android loads one by soname, so
drop whichever is newer and remove the duplicate.

Hardware decode uses Android **MediaCodec** (`--enable-mediacodec --enable-jni`); link the
system framework at app build time.

> **Minimum SDK: Android 9 (API 28) for the `v3` cells.** Those link Vulkan 1.1 symbols (the
> Whisper filter's GPU backend and FFmpeg's own Vulkan), so an app using a `v3` build needs
> `minSdkVersion` **28+**; on a device with no Vulkan GPU, Whisper falls back to CPU
> automatically. The `v2` cells carry no Vulkan, so they don't impose the API-28 floor (and run
> Whisper on CPU).

---

Back to the [install hub](./README.md) · [iOS](./ios.md) · [Whisper](./whisper.md) ·
[Development headers](./dev-headers.md)
