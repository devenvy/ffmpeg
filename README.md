# FFmpeg builds

Prebuilt, self-contained FFmpeg libraries and programs for every major platform: FFmpeg 8.x and 9.x, each in four
license variants, with the [whisper.cpp](https://github.com/ggml-org/whisper.cpp) speech-to-text filter (`whisper`)
built in. Download them from the [releases](../../releases).

They are built from [`ffmpeg-build.yml`](ffmpeg-build.yml) by [ffmpeg-build](https://github.com/devenvy/ffmpeg-build):
every library version is locked in [`ffmpeg.lock`](ffmpeg.lock), every license is checked before anything builds, and
each archive carries its license notices. [Using the builds](docs/install.md) covers each platform.

## Platforms

| OS                    | RIDs                                                                          |
| --------------------- | ----------------------------------------------------------------------------- |
| Windows               | `win-x64`, `win-arm64`                                                        |
| Linux (glibc)         | `linux-x64`, `linux-arm64`, `linux-armhf`                                     |
| Linux (musl / Alpine) | `linux-musl-x64`, `linux-musl-arm64`                                          |
| macOS                 | `osx-x64`, `osx-arm64`                                                        |
| Android               | `android-arm64`, `android-x64`                                                |
| iOS and Mac Catalyst  | `ios-arm64`, `ios-sim-arm64`, `maccatalyst-arm64` + `maccatalyst-x64`, in one `.xcframework` bundle |

Every platform ships shared libraries (`.dll`, `.so`, `.dylib`; iOS as dynamic frameworks). The Linux builds are
self-contained: nothing to install to run them.

## License variants

Each platform is built four times. Pick by family and version:

- **Family:** `gpl` adds the x264 and x265 encoders; `lgpl` uses kvazaar for HEVC and leaves x264/x265 out, so
  linking it doesn't put your app under the GPL.
- **Version:** `v3` (GPLv3 / LGPLv3) may use the Apache-2.0 libraries: OpenSSL, the Vulkan loader, and MoltenVK on
  Apple. `v2` (GPLv2 / LGPLv2.1) can't. **`lgplv2` is the App Store variant**: v3's anti-tivoization terms don't fit
  the App Store.

| Variant  | TLS (Linux, Android, Mac Catalyst) | SRT/RIST encryption | Vulkan filters | Whisper on the GPU (Vulkan)      |
| -------- | ---------------------------------- | ------------------- | -------------- | -------------------------------- |
| `gplv3`  | OpenSSL                            | yes                 | yes            | Linux, Windows, Android          |
| `lgplv3` | OpenSSL                            | yes                 | yes            | Linux, Windows, Android          |
| `gplv2`  | GnuTLS                             | yes                 | no             | Windows, Android                 |
| `lgplv2` | none                               | no                  | no             | Windows, Android                 |

Windows always uses SChannel and macOS/iOS SecureTransport for TLS. Whisper uses Metal on every Apple build, and the
CPU on `linux-armhf` (and wherever no GPU is found). On `v2` Windows and Android builds, Whisper's GPU path uses the
system's own Vulkan library, so nothing Apache-2.0 is shipped.

## Releases

Releases are tagged `<FFmpeg version>.<build>`, e.g. `9.0.2.4`; the build number goes up whenever anything a release
is made of changes (a library version, the build definition, the engine). Each release has, per platform and
variant:

- `ffmpeg-<version>-<rid>-<variant>.tar.gz`: the programs and shared libraries, with `THIRD-PARTY-NOTICES.txt` (the
  variant's license, how FFmpeg was built, and every bundled library's license texts).
- `ffmpeg-<version>-<rid>-<variant>-dev.tar.gz` (desktop platforms): headers, pkg-config files and, on Windows, MSVC
  import libraries.
- `ffmpeg-<version>-ios-<variant>.tar.gz`: the iOS and Mac Catalyst `.xcframework` bundle.

plus `SHA256SUMS`, `manifest.yml` (what each build contains) and `ffmpeg-<version>-sources.tar.gz` (the source of
every library in the release).

## License

The build definition in this repository is MIT ([LICENSE](LICENSE)). FFmpeg and the libraries are under the GNU (L)GPL
and various permissive licenses; each archive's `THIRD-PARTY-NOTICES.txt` says which, in full.
