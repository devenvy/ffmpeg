# Windows

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

Two RIDs: **`win-x64`** for Intel/AMD, and **`win-arm64`** for Windows on ARM (Snapdragon X and
similar). Substitute the RID you need in the filenames below — the layout is identical.

`win-arm64` builds the same software codecs, but its **hardware** acceleration set is smaller,
and necessarily so: NVIDIA's nvcodec (CUDA/NVENC/NVDEC), AMD's AMF and Intel's QSV have no
Windows-on-ARM implementation at all. What remains is D3D11VA, DXVA2 and MediaFoundation, which
cover the platform's own decode paths. SVT-AV1 is also absent (its assembly is x86-only) — AV1
encode comes from libaom and decode from dav1d instead. The Whisper filter runs on CPU there
rather than the Vulkan GPU backend used on `win-x64`.

## Install

```powershell
mkdir C:\opt\ffmpeg
tar -xzf ffmpeg-{VERSION}-win-x64-gplv3.tar.gz -C C:\opt\ffmpeg\

# Add to PATH (current session)
$env:PATH = "C:\opt\ffmpeg;$env:PATH"
```

DLLs and executables are in the same directory — Windows finds DLLs automatically. To *link*
the DLLs from an MSVC/CMake project, download the separate `…-win-{x64,arm64}-{gplv3,gplv2,lgplv3,lgplv2}-dev.tar.gz`,
which holds the `include/` headers and the `lib/*.lib` MSVC import libraries (see
[Development headers](./dev-headers.md)).

Windows needs no extra runtime install: the Vulkan loader (`vulkan-1.dll`) ships with the GPU
driver, and TLS uses the OS-native **SChannel** backend in every cell (unaffected by the v2/v3
split — see the [runtime-dependency overview](./README.md#runtime-dependencies)).

---

Back to the [install hub](./README.md) · [Linux](./linux.md) · [macOS](./macos.md) ·
[Whisper](./whisper.md) · [Development headers](./dev-headers.md)
