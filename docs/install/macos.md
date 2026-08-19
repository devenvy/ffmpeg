# macOS

Part of the [install docs](./README.md). See there for the four-cell variant naming and the
cross-platform [runtime-dependency overview](./README.md#runtime-dependencies).

## Install

```bash
mkdir -p /opt/ffmpeg
tar -xzf ffmpeg-{VERSION}-osx-arm64-gplv3.tar.gz -C /opt/ffmpeg/
export PATH="/opt/ffmpeg:$PATH"
```

macOS needs no extra runtime install: Whisper's GPU path uses **Metal** (available regardless of
the v2/v3 split), and TLS uses the OS-native **SecureTransport** backend in every cell — see the
[runtime-dependency overview](./README.md#runtime-dependencies).

## Vulkan GPU filters (v3 only)

FFmpeg's Vulkan filters (`scale_vulkan`, `gblur_vulkan`, `chromaber_vulkan`, …) have no Metal
equivalent in the filtergraph, so the **v3** macOS builds ship **MoltenVK** (Vulkan-over-Metal)
alongside the Vulkan loader to make them work. (The `v2` cells drop Vulkan — MoltenVK is
Apache-2.0, incompatible with GPLv2/LGPLv2.1.)

MoltenVK is an ICD, so the Vulkan loader must be told where to find it. Point `VK_ICD_FILENAMES`
at the bundled `MoltenVK_icd.json` before running:

```bash
export VK_ICD_FILENAMES="/opt/ffmpeg/MoltenVK_icd.json"
export DYLD_LIBRARY_PATH="/opt/ffmpeg:${DYLD_LIBRARY_PATH:-}"   # so ffmpeg finds the bundled loader
ffmpeg -init_hw_device vulkan -i in.mp4 -vf scale_vulkan=1280:720 out.mp4
```

Without those, `ffmpeg` still runs normally — the Vulkan filters just report no device (Metal
Whisper and VideoToolbox decode/encode are unaffected).

---

Back to the [install hub](./README.md) · [Linux](./linux.md) · [Windows](./windows.md) ·
[Whisper](./whisper.md) · [Development headers](./dev-headers.md)
