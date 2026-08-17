# Security Policy

## What this repository is

This repository is a **build system** for stock upstream FFmpeg and its supporting
libraries (x264, x265, kvazaar, dav1d, SVT-AV1, OpenSSL, and others). It does **not**
vendor, fork, patch, or ship modified copies of that upstream source — each library is
fetched from its official upstream at a pinned release tag and built **unmodified** at
CI time, into a git-ignored, ephemeral `.build/` tree. The only source original to this
repository is the build tooling (shell scripts and GitHub Actions workflows) plus a
small compile/runtime smoke test (`scripts/test/smoke.c`).

## Scope

**In scope** — report here:

- Vulnerabilities in our build tooling (shell scripts, workflows) — e.g. command
  injection, unsafe download/verification, secret handling.
- Supply-chain concerns in how we fetch or pin upstream sources.

**Out of scope** — please report upstream instead:

- Vulnerabilities in FFmpeg or any bundled library's own source code. Those belong to
  the respective upstream projects; we track and adopt fixed upstream releases through
  our version-update process. They are not defects in this repository.

## How we scan

- **CodeQL** — the C we own (`scripts/test/`) and our GitHub Actions workflows.
- **ShellCheck** — our shell scripts.

Both run on pull requests and pushes to `main`, with results in the Security tab.
Upstream library source is never checked out into an analyzed path, so upstream CVEs
are not attributed to this repository.

## Reporting a vulnerability

Please open a private report via the repository's **Security → Report a vulnerability**
page (GitHub private vulnerability reporting), or contact the maintainers directly. We
aim to acknowledge within a few business days.
