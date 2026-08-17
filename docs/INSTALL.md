# Installation & usage

How to download, install, and link the [FFmpeg builds](../README.md) — per platform — plus the
bundled Whisper speech-to-text filter and the development (headers/import-lib) packages.

## Install

Download a tarball from the [latest release](../../releases/latest) and extract.

> **Important:** The `linux-x64`, `linux-arm64`, and `linux-armhf` builds are **self-contained** —
> the hardware-acceleration libraries (VAAPI/QSV/libdrm) are statically linked and the Vulkan
> loader is bundled in the tarball, so `ffmpeg` starts on a bare system with **no `apt`/`dnf`
> install**. *Using* hardware acceleration or GPU transcription still needs the system GPU
> **driver**, but nothing is required just to run. The `linux-musl-x64` (Alpine) build is the one
> exception — see [Runtime dependencies](#runtime-dependencies).

### Runtime dependencies

The **`linux-x64`, `linux-arm64`, and `linux-armhf`** builds have **no runtime package
requirements** — every codec and hardware-dispatch library is static-linked or bundled, and the
binaries are built against an old glibc (2.28), so they launch on any current distro (RHEL/Alma
8+, Debian 10+, Ubuntu 18.10+) without installing anything.

To actually **use** hardware acceleration or GPU Whisper you additionally need the system GPU
**driver** — e.g. `intel-media-va-driver`/`mesa-va-drivers` for VAAPI, `mesa-vulkan-drivers`
for Vulkan/GPU transcription. Without one, hardware paths are simply unavailable and Whisper
falls back to CPU, so treat drivers as optional `Recommends`, never a hard dependency.

**`linux-musl-x64` (Alpine)** still links its hwaccel libraries dynamically, so it needs:

```bash
apk add libva libdrm libvpl vulkan-loader
```

**Windows and macOS** need no extra install: on Windows the Vulkan loader (`vulkan-1.dll`)
ships with the GPU driver, and macOS uses Metal. Where no Vulkan GPU is present, Whisper
transcribes on the CPU automatically.

### Linux

```bash
mkdir -p /opt/ffmpeg
tar -xzf ffmpeg-{VERSION}-linux-x64-gpl.tar.gz -C /opt/ffmpeg/

# Add to PATH
echo 'export PATH="/opt/ffmpeg:$PATH"' >> /etc/profile.d/ffmpeg.sh

# Register libs with the dynamic linker (needed when linking, e.g. from .NET)
echo "/opt/ffmpeg" > /etc/ld.so.conf.d/ffmpeg.conf
ldconfig
```

For Alpine containers, use the `linux-musl-x64` variant instead of `linux-x64`.

### Windows

```powershell
mkdir C:\opt\ffmpeg
tar -xzf ffmpeg-{VERSION}-win-x64-gpl.tar.gz -C C:\opt\ffmpeg\

# Add to PATH (current session)
$env:PATH = "C:\opt\ffmpeg;$env:PATH"
```

DLLs and executables are in the same directory — Windows finds DLLs automatically. To *link*
the DLLs from an MSVC/CMake project, download the separate `…-win-x64-{lgpl,gpl}-dev.tar.gz`,
which holds the `include/` headers and the `lib/*.lib` MSVC import libraries (see
[Development headers](#development-headers)).

### macOS

```bash
mkdir -p /opt/ffmpeg
tar -xzf ffmpeg-{VERSION}-osx-arm64-gpl.tar.gz -C /opt/ffmpeg/
export PATH="/opt/ffmpeg:$PATH"
```

### Mobile (Android / iOS)

The mobile artifacts are libraries to **link into an app**, not CLI tools. Use the `lgpl`
variant for anything shipped (a GPL build obligates your whole app to the GPL).

**Android** (`ffmpeg-{VERSION}-android-arm64-lgpl.tar.gz`) — a tarball with:
- `include/` — the `libav*` headers to compile against.
- `lib/arm64-v8a/*.so` — shared libraries with unversioned sonames; drop them into your
  module's `src/main/jniLibs/arm64-v8a/` (or point `jniLibs.srcDirs` at `lib/`).
- `legal/` — LGPL text (ship it).

The `lib/arm64-v8a/` folder includes **`libc++_shared.so`**. `libavcodec`/`libavfilter`
depend on it at runtime — the codec libraries built from C++ (OpenH264, libass, whisper.cpp)
are linked with `c++_shared`, so the shared NDK C++ runtime must ship alongside them or the app
crashes on load. Keep it in `jniLibs`. If your app (or another native dependency) already
bundles its own `libc++_shared.so`, they are interchangeable — Android loads one by soname, so
drop whichever is newer and remove the duplicate.

Hardware decode uses Android **MediaCodec** (`--enable-mediacodec --enable-jni`); link the
system framework at app build time.

> **Minimum SDK: Android 9 (API 28).** The libraries link Vulkan 1.1 symbols (the Whisper
> filter's GPU backend and FFmpeg's own Vulkan), so your app's `minSdkVersion` must be **28+**.
> On a device with no Vulkan GPU, Whisper falls back to CPU automatically.

**iOS** (`ffmpeg-{VERSION}-ios-lgpl.tar.gz`) — one `.xcframework` per `libav*` library, each
bundling the device (`arm64`) and simulator (`arm64`) slices. Add them to your Xcode target
(or a CocoaPods `vendored_frameworks`); Xcode selects the right slice and strips the simulator
slice from the shipped app automatically. Hardware decode uses **VideoToolbox**. The simulator
slice is decode-focused (no software encoders) — that path is for development; ship and test
encode/WebRTC-VP8/9 on a device.

### Dockerfile

```dockerfile
ARG VARIANT=linux-x64-gpl

RUN VERSION=$(curl -fsSL "https://api.github.com/repos/OWNER/REPO/releases/latest" \
        | jq -r '.tag_name') \
    && curl -fsSL \
        "https://github.com/OWNER/REPO/releases/download/${VERSION}/ffmpeg-${VERSION%.*}-${VARIANT}.tar.gz" \
        -o /tmp/ffmpeg.tar.gz \
    && mkdir -p /opt/ffmpeg \
    && tar -xzf /tmp/ffmpeg.tar.gz -C /opt/ffmpeg/ \
    && rm /tmp/ffmpeg.tar.gz \
    && echo "/opt/ffmpeg" > /etc/ld.so.conf.d/ffmpeg.conf \
    && ldconfig

ENV PATH="/opt/ffmpeg:$PATH"
```

Replace `OWNER/REPO` with the actual repository path. Assets on a public repo are downloadable
with plain `curl` — no authentication.

## Speech-to-text (Whisper ASR)

Every build enables FFmpeg's `whisper` audio filter (`af_whisper`), which runs
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) speech recognition inside the
filtergraph — no network, no external service. It is MIT/LGPL-clean and present in **all**
variants, including the shippable plain-LGPL builds.

**Model file (required, not bundled).** Download a GGML Whisper model and pass its path to the
filter. `base.en` (~142 MB) is a good default for English audio; `tiny.en` (~75 MB) is
smaller/faster for on-device use.

```bash
curl -fsSL -o ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

**Examples:**

```bash
# Transcribe a file's audio to an SRT subtitle sidecar
ffmpeg -i input.mp4 -vn \
    -af "whisper=model=ggml-base.en.bin:language=en:format=srt:destination=subs.srt" \
    -f null -

# Transcribe to a plain-text transcript
ffmpeg -i input.mp4 -vn \
    -af "whisper=model=ggml-base.en.bin:language=en:destination=transcript.txt" \
    -f null -
```

**Common options** (`ffmpeg -h filter=whisper` on the binary is authoritative):

| Option | Default | Description |
|--------|---------|-------------|
| `model` | (required) | Path to the GGML model file |
| `language` | `auto` | Language code (e.g. `en`), or `auto` to detect |
| `format` | `text` | Output format: `text`, `srt`, or `json` |
| `destination` | (stdout) | Output file path for the transcript |
| `queue` | `3s` | Audio buffered before each transcription pass |
| `use_gpu` | `1` | Use the GPU backend when available (else CPU) |
| `vad_model` | (none) | Optional VAD model path for speech segmentation |

**Hardware acceleration & fallback.** The GPU backend is **Vulkan** on Linux / Windows /
Android and **Metal** on macOS / iOS. When no compatible GPU is present, transcription runs on
the CPU automatically (`tiny`/`base` models are roughly real-time on CPU). On the glibc Linux
builds the Vulkan loader is **bundled** in the tarball; only the Alpine (`linux-musl-x64`) build
needs it from the system — see [Runtime dependencies](#runtime-dependencies).

## Development headers

Desktop runtime tarballs (`linux-*`, `win-x64`, `osx-*`) contain **only** the binaries, shared
libraries, and `legal/` — not the `libav*` headers. If you're *linking* against the libraries
(rather than running `ffmpeg`/`ffprobe`), grab the matching **`…-{variant}-dev.tar.gz`** from
the same release: it holds the `include/` headers, and for Windows the `lib/*.lib` MSVC import
libraries. Keeping dev files out of the runtime download keeps it lean and avoids consumers
accidentally picking up headers/import libs at runtime.

Mobile artifacts are the exception — Android (`lib/<abi>/*.so` + `include/`) and iOS
(`.xcframework`, headers bundled) ship headers in the main tarball, since those builds exist
only to be linked.
