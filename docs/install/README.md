# Installation & usage

How to download, install, and link the [FFmpeg builds](../../README.md) — per platform — plus the
bundled Whisper speech-to-text filter and the development (headers/import-lib) packages.

## Install

Download a tarball from the [latest release](../../../../releases/latest) and extract. Each platform
ships **four license cells** — the variant name is `{rid}-{gplv3,gplv2,lgplv3,lgplv2}` (e.g.
`linux-x64-lgplv3`). The four Apple mobile RIDs are the exception: `ios-arm64`, `ios-sim-arm64`,
`maccatalyst-arm64` and `maccatalyst-x64` ship as a single `ffmpeg-{VERSION}-ios-{cell}.tar.gz`
asset rather than one tarball per RID. The two Catalyst RIDs are `lipo`-fused into one universal
slice, so each xcframework in it holds three slices: device, simulator, and Catalyst.

Family: `gpl` bundles x264/x265; `lgpl` doesn't. Version: `v3` links the Apache-2.0 dependencies
— that means Vulkan everywhere it applies, and OpenSSL TLS on the platforms that need a bundled
backend (Linux, Android, Mac Catalyst); Windows and macOS/iOS use the OS-native backend in every
cell. `v2` (GPLv2 / LGPLv2.1) is the App-Store-safe series with no Vulkan, and its `lgplv2` cell
has no TLS on those same three platforms (see [Runtime dependencies](#runtime-dependencies)).
The per-platform pages below each use one cell in their examples; substitute the one you need.

## Verifying a download

Releases carry a `SHA256SUMS` asset covering every other artifact on that release, in standard
`sha256sum` format. **Releases published before this was added do not have one** — check the
release's asset list; for those, the per-asset digests are still available from the GitHub
releases API.

Fetch it alongside whatever you downloaded, and check from the directory containing the
downloads:

```bash
gh release download <tag> --repo <owner>/<repo> --pattern 'SHA256SUMS'
sha256sum -c --ignore-missing SHA256SUMS          # Linux (GNU coreutils >= 8.25)
shasum -a 256 -c --ignore-missing SHA256SUMS      # macOS (no sha256sum; shasum ships with it)
```

On Windows, `Get-FileHash <file> -Algorithm SHA256` prints the hash to compare against the
matching line, or use `sha256sum` from Git Bash / WSL.

`--ignore-missing` checks only the files you actually downloaded. Drop it to require the full
set — useful when mirroring a release or staging it for an air-gapped install.

The manifest does not list itself. Its trust root is the GitHub release it is attached to; the
same per-asset digests are also available from the releases API if you prefer to check one file
without fetching the manifest.

### Which cell do I pick?

- **Shipping into a closed-source app** → an **`lgpl`** cell (a GPL build obligates your whole app
  to the GPL).
- **Apple App Store** → **`lgplv2`**: v3's anti-tivoization terms are incompatible with the App
  Store, so LGPLv2.1 is the App-Store-safe series. (No Vulkan; on Android, no TLS — see below.)
- **Need software H.264/H.265 (x264/x265) encoding**, and the GPL is acceptable (internal tooling,
  GPL-compatible project) → a **`gpl`** cell.
- **Want GPU (Vulkan) Whisper** → a **`v3`** cell, and one of `linux-x64`, `linux-arm64`,
  `linux-musl-x64`, `linux-musl-arm64`, `win-x64`, `android-arm64` or `android-x64`. `v2` drops
  Vulkan on every RID, and `linux-armhf` / `win-arm64` are CPU-only Whisper in every cell.
  macOS/iOS/Catalyst use Metal regardless of cell.
- **Want TLS (`https`/`tls`)** → note that only the `lgplv2` cell lacks it, and only on Linux,
  Android and Mac Catalyst. `gplv2` has GnuTLS, and Windows/macOS/iOS have their native backend
  in all four cells — so `v3` is not required for TLS.
- **No preference otherwise** → **`lgplv3`** is the general-purpose default (dynamic-linking
  permission, TLS, no GPL obligation, and GPU Whisper on the RIDs listed above).

### Runtime dependencies

Two things travel with the cell you pick — TLS and Vulkan. No platform needs a package install
to make the artifacts run, including Alpine/musl. The cross-platform rules are here; the platform
pages carry the OS-specific steps.

**TLS and the license cell.** Which cell you pick changes what's inside the binary. On
Linux/Android, `v3` cells carry **OpenSSL**, the `gplv2` cell carries **GnuTLS**, and the
**`lgplv2` cell ships no TLS backend at all** — `https`/`tls` are unavailable, because GnuTLS's
GMP + nettle dependencies are never LGPLv2.1-licensed and no other FFmpeg TLS backend is
LGPLv2.1-compatible. Windows (**SChannel**) and macOS/iOS (**SecureTransport**) use the OS-native
backend in every cell, so their TLS is unaffected by the split. **Mac Catalyst is the exception
among Apple targets**: SecureTransport is unavailable there (the SDK marks it no longer supported
and FFmpeg's backend fails to compile), so Catalyst follows the Linux/Android ladder above and its
`lgplv2` slice has no TLS either — see [iOS / Mac Catalyst](./ios.md#no-tls-in-the-lgplv2-catalyst-slice).

**Vulkan and the license cell.** The `v2` cells omit **Vulkan** everywhere, so Vulkan Whisper
needs a `v3` cell — but a `v3` cell is not sufficient on its own. The Vulkan Whisper backend is
built only for `linux-x64`, `linux-arm64`, `linux-musl-x64`, `linux-musl-arm64`, `win-x64`,
`android-arm64` and `android-x64`; `linux-armhf` and `win-arm64` run Whisper on the CPU in every
cell, and macOS/iOS/Catalyst use Metal either way.

**System packages.** None are required. The glibc Linux builds are self-contained, and the
Alpine (`linux-musl-x64`, `linux-musl-arm64`) builds link the C++ runtime statically, so they run
on a stock `alpine` image with no `apk add`. The only external pieces anywhere are optional GPU
drivers for hardware acceleration. Details on the
[Linux page](./linux.md#runtime-dependencies). Windows and macOS need no extra install.

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
