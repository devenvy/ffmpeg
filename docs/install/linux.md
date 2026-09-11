# Linux

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

> **Important:** Every Linux build — `linux-x64`, `linux-arm64`, `linux-armhf`, `linux-musl-x64`,
> and `linux-musl-arm64` — is **self-contained** for hardware acceleration: the
> hardware-acceleration libraries (VAAPI/QSV/libdrm) are statically linked and the Vulkan loader
> is bundled in the tarball, so `ffmpeg` starts with **no `apt`/`dnf`/`apk` install** needed for
> those. *Using* hardware acceleration or GPU transcription still needs the system GPU **driver**,
> but nothing is required just to run. The `linux-musl-*` (Alpine) builds have one *unrelated*
> runtime requirement — Alpine's minimal base image ships no C++ runtime — see
> [Runtime dependencies](#runtime-dependencies).

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

For Alpine containers, use a `linux-musl-*` variant (`-x64` or `-arm64`) instead of
`linux-x64`/`linux-arm64`.

## Runtime dependencies

The **`linux-x64`** and **`linux-arm64`** builds have **no runtime package requirements** —
every codec and hardware-dispatch library is static-linked or bundled, and they are built in a
manylinux_2_28 container (**glibc 2.28**), so they launch on any current distro (RHEL/Alma 8+,
Debian 10+, Ubuntu 18.10+) without installing anything.

**`linux-armhf`** is built in a Debian Bookworm container, so its floor is **glibc 2.36** —
Raspberry Pi OS Bookworm, Debian 12 and Ubuntu 22.10+. It is cross-compiled rather than built
on an armv7 host (no hosted runner executes 32-bit ARM), and Bookworm is the oldest base whose
glibc still satisfies the Node runtime the CI actions require.

To actually **use** hardware acceleration or GPU Whisper you additionally need the system GPU
**driver** — e.g. `intel-media-va-driver`/`mesa-va-drivers` for VAAPI, `mesa-vulkan-drivers`
for Vulkan/GPU transcription. Without one, hardware paths are simply unavailable and Whisper
falls back to CPU, so treat drivers as optional `Recommends`, never a hard dependency.

**`linux-musl-x64`/`linux-musl-arm64` (Alpine)** — the latter is the Alpine-on-ARM build (AWS
Graviton, Ampere, and Docker Desktop on Apple Silicon, which defaults to arm64 containers) — are
self-contained in the same way as the glibc builds above: the hwaccel dispatch libraries
(libdrm/libva/libvpl/Vulkan-Loader) are built from source and statically linked or bundled
directly in the tarball, not taken from Alpine's `-dev` packages, so they carry no
`libva.so`/`libvpl.so`/`libvulkan.so` runtime dependency either. The only thing Alpine's minimal
base image doesn't ship is a C++ runtime, which whisper needs:

```bash
apk add libstdc++ libgcc
```

on either musl host.

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
