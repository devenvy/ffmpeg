# Security

This repository holds a build definition only: [`ffmpeg-build.yml`](ffmpeg-build.yml), its lock and the workflows
that build and publish the releases. The builds themselves are made by
[ffmpeg-build](https://github.com/devenvy/ffmpeg-build), from each library's upstream source, pinned by commit or
checksum in [`ffmpeg.lock`](ffmpeg.lock).

## Reporting a vulnerability

Please report privately, through **Security → Report a vulnerability** on this repository; don't open a public issue.

- **The builds or how they are made** (what is downloaded and how it's checked, the toolchains, the workflows): report
  it to [ffmpeg-build](https://github.com/devenvy/ffmpeg-build/security).
- **FFmpeg or a bundled library's own code:** report it upstream. Fixed upstream releases reach these builds through
  the daily lock update.
- **Anything about this repository's configuration or releases:** here.
