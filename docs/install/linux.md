# Linux

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

> **Important:** Every Linux build — `linux-x64`, `linux-arm64`, `linux-armhf`, `linux-musl-x64`,
> and `linux-musl-arm64` — is **self-contained** for hardware acceleration: the
> hardware-acceleration libraries (VAAPI/QSV/libdrm) are statically linked, and the Vulkan loader
> is bundled on every Linux build **except `linux-armhf`** (see below), so `ffmpeg` starts with
> **no `apt`/`dnf`/`apk` install** needed for those. *Using* hardware acceleration or GPU transcription still needs the system GPU **driver**,
> but nothing is required just to run. That now includes the `linux-musl-*` (Alpine) builds: the
> C++ runtime Alpine's minimal base image lacks is linked statically into the libraries, so they run on a bare
> `alpine` container with no `apk add` — see [Runtime dependencies](#runtime-dependencies).

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

The **`linux-x64`** and **`linux-arm64`** builds have **no runtime package requirements on a
normal distribution** — every codec and hardware-dispatch library is static-linked or bundled,
and they are built in a manylinux_2_28 container (**glibc 2.28**), so they launch on any current
distro (RHEL/Alma 8+, Debian 10+, Ubuntu 18.10+) without installing anything.

> The C++ codec libraries mean `libavcodec`/`libavfilter` still link `libstdc++.so.6` and
> `libgcc_s.so.1` dynamically. Every ordinary glibc distribution ships those, which is why there
> is nothing to install — but a **minimal or distroless** glibc image may not, and there they
> must be present. (The musl builds link them statically instead; see below.)

**`linux-armhf`** is built in a Debian Bookworm container, so its floor is **glibc 2.36** —
Raspberry Pi OS Bookworm, Debian 12 and Ubuntu 22.10+. It is cross-compiled rather than built
on an armv7 host (no hosted runner executes 32-bit ARM), and Bookworm is the oldest base whose
glibc still satisfies the Node runtime the CI actions require.

**`linux-armhf` and Vulkan.** Unlike the other Linux `v3` cells, the armhf build ships no bundled
Vulkan loader. This is not a startup dependency — its `libavfilter` has no `DT_NEEDED` on
`libvulkan.so.1` and reaches Vulkan through FFmpeg's `dlopen` path — so the artifact runs fine
without one. The practical difference is that on armhf, FFmpeg's **Vulkan filters** need the
**system** loader (`apt install libvulkan1`) plus a driver, where the other Linux cells carry
their own loader. This does not affect Whisper: armhf builds Whisper with the **CPU** backend,
so there is no GPU transcription there to enable in the first place.

To actually **use** hardware acceleration or GPU Whisper you additionally need the system GPU
**driver** — e.g. `intel-media-va-driver`/`mesa-va-drivers` for VAAPI, `mesa-vulkan-drivers`
for Vulkan/GPU transcription. Without one, hardware paths are simply unavailable and Whisper
falls back to CPU, so treat drivers as optional `Recommends`, never a hard dependency.

**`linux-musl-x64`/`linux-musl-arm64` (Alpine)** — the latter is the Alpine-on-ARM build (AWS
Graviton, Ampere, and Docker Desktop on Apple Silicon, which defaults to arm64 containers) — are
self-contained in the same way as the glibc builds above: the hwaccel dispatch libraries
(libdrm/libva/libvpl/Vulkan-Loader) are built from source and statically linked or bundled
directly in the tarball, not taken from Alpine's `-dev` packages, so they carry no
`libva.so`/`libvpl.so`/`libvulkan.so` runtime dependency either.

The C++ runtime whisper needs (`libstdc++`, `libgcc`) is **linked statically into the FFmpeg
libraries**, so these run on a bare `alpine` image with nothing installed — no `apk add` step, and
no `libstdc++.so.6`/`libgcc_s.so.1` in the tarball to find at all.

> Previously this required `apk add libstdc++ libgcc`. That was documented rather than fixed, and
> documentation doesn't make an artifact runnable — a stock Alpine container failed at startup
> with `Error loading shared library libstdc++.so.6`. The runtime is now part of the libraries.

**How that works.** The C++ runtime is linked **statically** into the FFmpeg libraries rather than shipped alongside them, so there is no `libstdc++.so.6`/`libgcc_s.so.1` to find. That also keeps the licence position clean: the GCC Runtime Library Exception covers statically linked runtime as part of the compiled output, so no GPLv3 library is redistributed — which matters most for the `lgplv2` cell. No platform bundles a GPL runtime.

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
