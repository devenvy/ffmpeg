# Installation & usage

How to download, install, and link the [FFmpeg builds](../../README.md) — per platform — plus the
bundled Whisper speech-to-text filter and the development (headers/import-lib) packages.

## Install

Download a tarball from the [latest release](../../../releases/latest) and extract. Each platform
ships **four license cells** — the variant name is `{rid}-{gplv3,gplv2,lgplv3,lgplv2}` (e.g.
`linux-x64-lgplv3`). Family: `gpl` bundles x264/x265; `lgpl` doesn't. Version: `v3` links
Apache-2.0 deps (OpenSSL TLS + Vulkan); `v2` (GPLv2 / LGPLv2.1) is the App-Store-safe series with
no Vulkan, and its `lgplv2` cell has no TLS at all (see [Runtime dependencies](#runtime-dependencies)).
The per-platform pages below each use one cell in their examples; substitute the one you need.

### Which cell do I pick?

- **Shipping into a closed-source app** → an **`lgpl`** cell (a GPL build obligates your whole app
  to the GPL).
- **Apple App Store** → **`lgplv2`**: v3's anti-tivoization terms are incompatible with the App
  Store, so LGPLv2.1 is the App-Store-safe series. (No Vulkan; on Android, no TLS — see below.)
- **Need software H.264/H.265 (x264/x265) encoding**, and the GPL is acceptable (internal tooling,
  GPL-compatible project) → a **`gpl`** cell.
- **Want TLS (`https`/`tls`) or GPU Whisper on Linux/Android/Windows** → a **`v3`** cell (`v2`
  drops Vulkan, and `lgplv2` drops TLS entirely).
- **No preference otherwise** → **`lgplv3`** is the general-purpose default (dynamic-linking
  permission, TLS, GPU Whisper, no GPL obligation).

### Runtime dependencies

Two things travel with the cell you pick — TLS and Vulkan — and one platform (Alpine/musl) needs
system packages. The cross-platform rules are here; the platform pages carry the OS-specific steps.

**TLS and the license cell.** Which cell you pick changes what's inside the binary. On
Linux/Android, `v3` cells carry **OpenSSL**, the `gplv2` cell carries **GnuTLS**, and the
**`lgplv2` cell ships no TLS backend at all** — `https`/`tls` are unavailable, because GnuTLS's
GMP + nettle dependencies are never LGPLv2.1-licensed and no other FFmpeg TLS backend is
LGPLv2.1-compatible. Windows (**SChannel**) and macOS (**SecureTransport**) use the OS-native
backend in every cell, so their TLS is unaffected by the split. The `v2` cells also omit
**Vulkan**, so GPU Whisper on Linux/Android/Windows requires a `v3` cell (macOS/iOS use Metal
either way).

**System packages.** The glibc Linux builds are self-contained (nothing to install); the Alpine
(`linux-musl-x64`) build needs a few `apk` packages. Both live on the [Linux page](./linux.md#runtime-dependencies).
Windows and macOS need no extra install.

## Pages

- **[Linux](./linux.md)** — glibc + Alpine/musl, self-contained note, and the Dockerfile recipe.
- **[Windows](./windows.md)** — DLLs on `PATH`, and the `-dev` tarball for MSVC `.lib` linking.
- **[macOS](./macos.md)** — dylibs + `PATH`.
- **[Android](./android.md)** — jniLibs `.so`, `libc++_shared.so`, MediaCodec, the API-28/`v3` floor.
- **[iOS](./ios.md)** — the `.xcframework`, dynamic dylibs (LGPLv2.1 §6), VideoToolbox.
- **[Speech-to-text (Whisper ASR)](./whisper.md)** — the bundled `whisper` filter, models, GPU/CPU.
- **[Development headers](./dev-headers.md)** — the `-dev` tarballs (headers + Windows import libs).

See also the auto-generated **[build coverage matrix](../matrix/README.md)** for which library is
built on which platform × license.
