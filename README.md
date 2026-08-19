# FFmpeg Builds

Prebuilt, self-contained **FFmpeg 8** libraries and binaries for every major platform, in four
license variants — with the [whisper.cpp](https://github.com/ggml-org/whisper.cpp) speech-to-text
filter (`af_whisper`) built in. No network, no external services; every artifact ships the
governing license text and each bundled dependency's license under `legal/`.

## Platforms

| OS | RIDs |
|----|------|
| Windows | `win-x64` |
| Linux (glibc) | `linux-x64`, `linux-arm64`, `linux-armhf` |
| Linux (musl / Alpine) | `linux-musl-x64` |
| macOS | `osx-x64`, `osx-arm64` |
| Android | `android-arm64` |
| iOS | `ios-arm64` (device) + `ios-sim-arm64` (simulator), shipped as one `.xcframework` |

Every platform ships **dynamic** libraries (`.dll` / `.so` / `.dylib`; iOS as a dynamic-framework
`.xcframework`). The glibc Linux builds are self-contained (old-glibc floor, hwaccel libs
static-linked, Vulkan loader bundled) so they run on a bare system with no package install.

## License variants

Each platform is built in **four cells** — pick by family and version:

- **Family** — `gpl` adds the x264 + x265 encoders; `lgpl` uses kvazaar for HEVC and omits
  x264/x265, so linking it doesn't force your app to the GPL.
- **Version** — `v3` is `(L)GPLv3` and may link the Apache-2.0 dependencies (OpenSSL TLS +
  Vulkan); `v2` is `GPLv2` / `LGPLv2.1` with no Vulkan. **`lgplv2` is the App-Store-safe cell**
  — v3's anti-tivoization terms are incompatible with the Apple App Store, so LGPLv2.1 is the
  variant you ship to iOS.

Artifact naming: `ffmpeg-{version}-{rid}-{gplv3|gplv2|lgplv3|lgplv2}`.

The **TLS backend depends on the cell**: OpenSSL on `v3` (Linux/Android), GnuTLS on `gplv2`, and
**no TLS at all** on `lgplv2` (Linux/Android — no LGPLv2.1-compatible backend exists); Windows uses
SChannel and Apple uses SecureTransport in every cell. See the docs for the full breakdown.

## Documentation

- **[Install & usage](docs/install/README.md)** — download, link, and consume per platform, plus
  the Whisper filter and the development (headers / import-lib) packages.
- **[Build coverage matrix](docs/matrix/README.md)** — every library FFmpeg supports × every
  platform × license, ✓ where this repo builds it.
- **[Development](DEVELOPMENT.md)** — how the builds are produced: the build scripts, CI, and how
  to add a platform or dependency.
- **[Security](SECURITY.md)** — the security model and how to report an issue.

## License

FFmpeg and its dependencies are licensed under the GNU (L)GPL and various permissive licenses.
Each release artifact carries its effective-license notice and the full text of every bundled
component under `legal/` — see the [install docs](docs/install/README.md) for what to ship.
