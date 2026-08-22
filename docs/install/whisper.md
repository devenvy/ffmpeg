# Speech-to-text (Whisper ASR)

Part of the [install docs](./README.md).

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

**Hardware acceleration & fallback.** On the **`v3`** cells the GPU backend is **Vulkan** on
Linux / Windows / Android and **Metal** on macOS / iOS. The **`v2`** cells carry no Vulkan, so on
Linux / Windows / Android they transcribe on the **CPU** (macOS / iOS still use Metal). When no
compatible GPU is present, transcription also runs on the CPU automatically (`tiny`/`base` models
are roughly real-time on CPU). On the glibc Linux `v3` builds the Vulkan loader is **bundled** in
the tarball; only the Alpine (`linux-musl-x64`) build needs it from the system — see
[Linux runtime dependencies](./linux.md#runtime-dependencies).

---

Back to the [install hub](./README.md) · [Linux](./linux.md) · [Windows](./windows.md) ·
[macOS](./macos.md)
