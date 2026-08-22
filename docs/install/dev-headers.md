# Development headers

Part of the [install docs](./README.md).

Desktop runtime tarballs (`linux-*`, `win-x64`, `osx-*`) contain **only** the binaries, shared
libraries, and `legal/` (the per-cell license notice plus each bundled dependency's license under
`legal/licenses/<dep>/`) — not the `libav*` headers. If you're *linking* against the libraries
(rather than running `ffmpeg`/`ffprobe`), grab the matching **`…-{variant}-dev.tar.gz`** from
the same release: it holds the `include/` headers, and for Windows the `lib/*.lib` MSVC import
libraries. Keeping dev files out of the runtime download keeps it lean and avoids consumers
accidentally picking up headers/import libs at runtime.

Mobile artifacts are the exception — [Android](./android.md) (`lib/<abi>/*.so` + `include/`) and
[iOS](./ios.md) (`.xcframework`, headers bundled) ship headers in the main tarball, since those
builds exist only to be linked.

---

Back to the [install hub](./README.md) · [Linux](./linux.md) · [Windows](./windows.md) ·
[macOS](./macos.md)
