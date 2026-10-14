# Using the builds

Download an archive from the [releases](../../../releases) and check it against the release's `SHA256SUMS`:

```bash
gh release download 9.0.2.4 --repo devenvy/ffmpeg --pattern 'ffmpeg-9.0.2-linux-x64-lgplv3.tar.gz' --pattern SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS       # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
```

A product can pin a release instead, and let ffmpeg-build download, check and unpack it (and move the pin within the
same FFmpeg major): `devenvy/ffmpeg@9.0.2.4` in a file such as `ffmpeg.version`, then
`ffmpeg-build fetch ffmpeg.version --target linux-x64-lgplv3 --dev --out vendor/ffmpeg`.

Ship `THIRD-PARTY-NOTICES.txt` with anything you distribute: it is the variant's license notice and every bundled
library's license text.

## Which variant

- **A closed-source app:** an `lgpl` variant (a `gpl` one puts the whole app under the GPL).
- **The Apple App Store:** `lgplv2`.
- **x264/x265 encoding,** where the GPL is fine: a `gpl` variant.
- **Otherwise:** `lgplv3` (TLS everywhere, Vulkan, no GPL obligations).

The [README](../README.md#license-variants) lists what each variant has: TLS, SRT/RIST encryption, Vulkan, GPU
Whisper.

## Linux

```bash
mkdir -p /opt/ffmpeg && tar -xzf ffmpeg-9.0.2-linux-x64-lgplv3.tar.gz -C /opt/ffmpeg
export PATH="/opt/ffmpeg:$PATH"
echo /opt/ffmpeg > /etc/ld.so.conf.d/ffmpeg.conf && ldconfig     # to link against the libraries
```

Nothing needs installing. `linux-x64` and `linux-arm64` run on glibc 2.28 and later (RHEL/Alma 8+, Debian 10+, Ubuntu
18.10+), `linux-armhf` on glibc 2.36 and later (Debian 12, Raspberry Pi OS Bookworm); a distroless image also needs
`libstdc++.so.6` and `libgcc_s.so.1`. The `linux-musl-*` builds run on a bare `alpine` image: the C++ runtime is linked
in. NVIDIA encoding (NVENC) needs driver 570 or later, on Linux and Windows. Hardware acceleration (VAAPI, QSV, Vulkan)
and GPU Whisper only need the GPU driver (e.g. `mesa-va-drivers`,
`mesa-vulkan-drivers`); without one, FFmpeg runs on the CPU. `linux-armhf` ships no Vulkan loader: its Vulkan filters
use the system's (`libvulkan1`).

## Windows

```powershell
tar -xzf ffmpeg-9.0.2-win-x64-lgplv3.tar.gz -C C:\ffmpeg
$env:PATH = "C:\ffmpeg;$env:PATH"
```

The DLLs sit beside `ffmpeg.exe`. To link from MSVC or CMake, take the `-dev` archive: `include/` and the `lib/*.lib`
import libraries. Vulkan comes with the GPU driver. `win-arm64` has no NVENC/NVDEC, AMF, QSV or SVT-AV1 (none exist for
Windows on ARM); it decodes in hardware through D3D11VA, DXVA2 and Media Foundation.

## macOS

```bash
mkdir -p /opt/ffmpeg && tar -xzf ffmpeg-9.0.2-osx-arm64-lgplv3.tar.gz -C /opt/ffmpeg
export PATH="/opt/ffmpeg:$PATH"
```

The `v3` builds run FFmpeg's Vulkan filters (`scale_vulkan`, ...) through MoltenVK, shipped in the archive; point the
Vulkan loader at it:

```bash
export VK_ICD_FILENAMES=/opt/ffmpeg/MoltenVK_icd.json
ffmpeg -init_hw_device vulkan -i in.mp4 -vf scale_vulkan=1280:720 out.mp4
```

Without it, everything else (VideoToolbox, Metal Whisper) works as usual.

## Android

The archive has `include/` and `lib/<abi>/*.so` (`arm64-v8a` or `x86_64`); put the libraries in your module's
`src/main/jniLibs/<abi>/`, including the `libc++_shared.so` they need. Ship both ABIs (`android-x64` is for emulators
and x86_64 devices). Hardware decode uses MediaCodec. The minimum is Android 9 (API 28), in every variant.

## iOS and Mac Catalyst

`ffmpeg-<version>-ios-<variant>.tar.gz` holds one dynamic `.xcframework` per `libav*` library, each with the device
(`ios-arm64`), simulator (`ios-sim-arm64`) and Mac Catalyst (arm64 + x64 in one slice) builds. Add them to your Xcode
target; Xcode picks the slice. Hardware decode uses VideoToolbox. The iOS 14.0 minimum applies to Catalyst.

- The simulator slice leaves out x264, x265, kvazaar, libvpx, libaom, Opus and libass (they don't build for the arm64
  simulator); test that work on a device.
- Mac Catalyst has no SecureTransport, so it takes TLS like Linux: none in `lgplv2`.
- The `v3` frameworks link MoltenVK in for FFmpeg's Vulkan filters; nothing to embed or configure. On Mac Catalyst,
  also link `-framework IOKit`.

## Whisper (speech to text)

Every build has FFmpeg's `whisper` filter. Download a [GGML model](https://huggingface.co/ggerganov/whisper.cpp) and
point the filter at it:

```bash
curl -fsSLo ggml-base.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
ffmpeg -i input.mp4 -vn -af "whisper=model=ggml-base.en.bin:language=en:format=srt:destination=subs.srt" -f null -
```

It uses the GPU where the build has a backend for it (see the README) and falls back to the CPU; `use_gpu=0` forces
the CPU. `ffmpeg -h filter=whisper` lists its options.
