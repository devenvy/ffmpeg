# Capability Libraries (Tier-3 additions) — Design

**Status:** approved design, pre-plan
**Branch:** `feat/capability-libs-tier3` → one PR to `main`
**Predecessors:** [Tier-1](2026-08-24-capability-libraries-design.md) (PR #9), [Tier-2](2026-08-25-capability-libraries-tier2-design.md) (PR #10, merged)
**Goal:** Add audio codecs (Speex, GSM, AMR-NB/WB), audio fingerprinting (chromaprint), and
the SRT + RIST network transports (with per-license encryption). Closes the remaining
high-value `—` rows. **ONNX/DNN is deliberately excluded** — no mainstream build ships it, and
its filters are inert without external models (revisit only on a concrete use case).

## Scope — two groups, one branch/PR

### Group 1 — codecs + fingerprinting
| Lib | FFmpeg flag | Gating | Build | Source |
|---|---|---|---|---|
| **speex** | `--enable-libspeex` | all cells | autotools | xiph git |
| **libgsm** | `--enable-libgsm` | all cells | custom Makefile | tarball (quut.com) |
| **kissfft** | *(chromaprint dep)* | all cells | cmake | mborgerding git |
| **chromaprint** | `--enable-chromaprint` | all cells | cmake (C++) | acoustid git |
| **opencore-amr** | `--enable-libopencore-amrnb` + `--enable-libopencore-amrwb` | **v3 only** | autotools | SF tarball |
| **vo-amrwbenc** | `--enable-libvo-amrwbenc` | **v3 only** | autotools | SF tarball |

### Group 2 — network transports + crypto
| Lib | FFmpeg flag | Gating | Build | Source |
|---|---|---|---|---|
| **mbedtls** | *(transport crypto dep)* | **v3 only** | cmake | Mbed-TLS git (3.6 LTS) |
| **libsrt** | `--enable-libsrt` | all cells | cmake | Haivision git |
| **librist** | `--enable-librist` | all cells | meson | videolan git |

## Crypto architecture (locked — see below for why)
FFmpeg's own HTTPS/TLS is **unchanged** (keeps OpenSSL's auto-CA behaviour — no regression).
Only the **transport encryption** for SRT + librist is new:

| Cell | FFmpeg TLS | SRT + librist encryption | new crypto dep |
|---|---|---|---|
| Linux/Android **v3** | OpenSSL (unchanged) | **mbedTLS** | mbedTLS |
| Win/Apple **v3** | SChannel/SecureTransport (unchanged) | **mbedTLS** | mbedTLS |
| Linux/Android **gpl-2** | GnuTLS (unchanged) | **GnuTLS** (reuse) | — |
| **lgpl-2** (all), **gpl-2** Win/Apple | unchanged | **nocrypto** | — |

**Rationale (verified):**
- **librist cannot use OpenSSL** — only mbedTLS or GnuTLS/nettle. So the transports need their
  own crypto lib regardless of FFmpeg's TLS backend.
- **mbedTLS is the one lib both SRT and librist support** (SRT `USE_ENCLIB=mbedtls`, librist
  `use_mbedtls`), it's Apache-2.0 (fine on `--enable-version3`), small, and cross-compiles
  cleanly (it's the embedded-first TLS lib). So it's the shared transport crypto on the v3 lane.
- **We do NOT swap FFmpeg's TLS onto mbedTLS.** FFmpeg's mbedTLS backend (`tls_mbedtls.c`) only
  loads CAs from an explicit `ca_file` — no system-store fallback — so verified HTTPS would
  regress. OpenSSL/GnuTLS auto-load the system trust store; they stay as FFmpeg's TLS backends.
- **This mirrors BtbN exactly** — it bundles OpenSSL (TLS + SRT) *and* a dedicated mbedTLS (for
  librist). Two crypto libs on the v3 cells is the normal, correct setup.
- **lgpl-2** already ships no TLS (GMP/nettle can't be LGPLv2.1); transports match → nocrypto.
  **gpl-2 on Win/Apple** has no crypto lib there (OpenSSL is version3-only, GnuTLS not built) → nocrypto.
- SRT uses **mbedTLS on v3** (uniform with librist; avoids needing OpenSSL on Win/Apple) and
  **GnuTLS on gpl-2 Linux/Android**.

## Global Constraints
- **Local-first (hard rule):** vet **win / linux-x64 / linux-musl-x64 / android-arm64** locally
  before the PR (osx/ios via CI). "Done" = lib compiles AND `config.h` shows its `CONFIG_*=1`.
- **No lint suppression across the board** — fix, or inline per-line `# shellcheck disable=…`.
- **License gating:** opencore-amr + vo-amrwbenc are **version3** (Apache-2.0); mbedTLS is
  version3. speex/libgsm/chromaprint/kissfft/srt/librist are permissive → all cells. No new dep
  narrows a cell's license token.
- **Static, PIC, no shared.** C++ deps (chromaprint) self-supply their runtime to `EXTRA_LIBS`.
- **Ledger-tracked:** every dep pinned in `deps.json` with a `datasource` (Renovate). Tarball
  deps (libgsm, opencore-amr, vo-amrwbenc) use the existing tarball pattern (`dep_version` +
  download, like gmp/lame/nettle) with a `reason` noting the tarball source.
- **Coverage matrix regenerates** — `gen-matrix.sh` zero-drift.

## Per-library notes
- **speex** (`speex.pc`, all cells): autotools, `--disable-shared --enable-static`. Just the
  codec (libspeex); FFmpeg's libspeex uses it for de/encode.
- **libgsm** (`-lgsm`, no pkg-config, all cells): the trickiest — libgsm ships a **non-standard
  Makefile** (no `./configure`, no `make install`). Build `libgsm.a` with `CC`/`AR`/cross flags,
  then **manually install** `lib/libgsm.a` + `inc/gsm.h` into `${DEPS_DIR}`. FFmpeg finds it via
  `check_lib libgsm gsm.h gsm_create -lgsm`. Needs `EXTRA_CFLAGS` include path.
- **kissfft** (chromaprint dep, all cells): cmake, install `libkissfft` + its find-package
  config; chromaprint locates it via `find_package(KissFFT)`.
- **chromaprint** (`-lchromaprint`, all cells): cmake, `-DFFT_LIB=kissfft` (kissfft built first —
  the `avfft`/`avtx` options would need FFmpeg's own libs, circular). C++ → append `-lstdc++`/
  `-lc++` to `EXTRA_LIBS`. FFmpeg uses it for the `chromaprint` muxer (audio fingerprinting).
- **opencore-amr** (`opencore-amrnb`/`opencore-amrwb` pkg-config, **v3**): autotools tarball,
  `--disable-shared`. Enables AMR-NB en/decode + AMR-WB decode.
- **vo-amrwbenc** (`vo-amrwbenc` pkg-config, **v3**): autotools tarball. Enables AMR-WB encode.
- **mbedtls** (transport dep, **v3**): cmake, `-DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF`,
  static. Pin the **3.6 LTS** line (4.x is the TF-PSA-Crypto split, not yet consumed by
  FFmpeg/SRT/librist). Built on all v3 cells (incl. Win/Apple, for the transports).
- **libsrt** (`srt >= 1.3` pkg-config, all cells): cmake. `-DENABLE_APPS=OFF -DENABLE_SHARED=OFF
  -DENABLE_STATIC=ON`. Encryption per the crypto map: `-DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=mbedtls`
  (v3) / `=gnutls` (gpl-2 Linux/Android) / `-DENABLE_ENCRYPTION=OFF` (nocrypto cells). C++ → runtime.
- **librist** (`librist >= 0.2` pkg-config, all cells): meson. `use_mbedtls=true` (v3, external
  mbedTLS) / `use_gnutls=true` (gpl-2 Linux/Android) / both false (nocrypto cells). Uses the
  MESON_CROSS_FILE for cross targets.

## Testing
- Per-cell local gate on linux-x64/musl/win/android: lib compiles, `config.h CONFIG_*=1`.
  Probes: `ffmpeg -codecs | grep -iE 'speex|gsm|amr'`, `-muxers | grep chromaprint`,
  `-protocols | grep -E 'srt|rist'`, and (where crypto expected) SRT passphrase accepted.
- gen-matrix zero-drift; ledger validator + select-versions-test + shellcheck green.
- CI matrix (40 cells × 2 versions) = final osx/ios sign-off.

## Risks
1. **libgsm's non-standard Makefile** — the main packaging risk; manual install + cross `CC`.
2. **chromaprint→kissfft** find_package wiring on cross toolchains (FFT_LIB=kissfft).
3. **SRT/librist crypto gating** — per-cell enclib selection must match the crypto map; nocrypto
   cells must configure cleanly with encryption off.
4. **mbedTLS 3.6-vs-4.x** — pin 3.6 LTS to stay compatible with FFmpeg/SRT/librist.
