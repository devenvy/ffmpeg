# Linux

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

> **Important:** The `linux-x64`, `linux-arm64`, and `linux-armhf` builds are **self-contained** —
> the hardware-acceleration libraries (VAAPI/QSV/libdrm) are statically linked and the Vulkan
> loader is bundled in the tarball, so `ffmpeg` starts on a bare system with **no `apt`/`dnf`
> install**. *Using* hardware acceleration or GPU transcription still needs the system GPU
> **driver**, but nothing is required just to run. The `linux-musl-x64` (Alpine) build is the one
> exception — see [Runtime dependencies](#runtime-dependencies).

## Install

```bash
mkdir -p /opt/ffmpeg
tar -xzf ffmpeg-{VERSION}-linux-x64-gplv3.tar.gz -C /opt/ffmpeg/

# Add to PATH
echo 'export PATH="/opt/ffmpeg:$PATH"' >> /etc/profile.d/ffmpeg.sh

# Register libs with the dynamic linker (needed when linking, e.g. from .NET)
echo "/opt/ffmpeg" > /etc/ld.so.conf.d/ffmpeg.conf
ldconfig
```

For Alpine containers, use the `linux-musl-x64` variant instead of `linux-x64`.

## Runtime dependencies

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

TLS and Vulkan availability depend on which license cell you picked — see the cross-platform
[TLS and the license cell](./README.md#runtime-dependencies) overview.

## Dockerfile

```dockerfile
ARG VARIANT=linux-x64-gplv3

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

---

Back to the [install hub](./README.md) · [Windows](./windows.md) · [macOS](./macos.md) ·
[Whisper](./whisper.md) · [Development headers](./dev-headers.md)
