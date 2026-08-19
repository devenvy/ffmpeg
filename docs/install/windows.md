# Windows

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

## Install

```powershell
mkdir C:\opt\ffmpeg
tar -xzf ffmpeg-{VERSION}-win-x64-gplv3.tar.gz -C C:\opt\ffmpeg\

# Add to PATH (current session)
$env:PATH = "C:\opt\ffmpeg;$env:PATH"
```

DLLs and executables are in the same directory — Windows finds DLLs automatically. To *link*
the DLLs from an MSVC/CMake project, download the separate `…-win-x64-{gplv3,gplv2,lgplv3,lgplv2}-dev.tar.gz`,
which holds the `include/` headers and the `lib/*.lib` MSVC import libraries (see
[Development headers](./dev-headers.md)).

Windows needs no extra runtime install: the Vulkan loader (`vulkan-1.dll`) ships with the GPU
driver, and TLS uses the OS-native **SChannel** backend in every cell (unaffected by the v2/v3
split — see the [runtime-dependency overview](./README.md#runtime-dependencies)).

---

Back to the [install hub](./README.md) · [Linux](./linux.md) · [macOS](./macos.md) ·
[Whisper](./whisper.md) · [Development headers](./dev-headers.md)
