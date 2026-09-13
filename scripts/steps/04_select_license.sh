#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 4: Select License
#
# Apply the GPL or LGPL flag — GPL adds the x264/x265 software encoders —
# and, for the lean iOS-simulator slice, drop the software codec libraries
# it doesn't need.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── License: family (gpl/lgpl) × version series (v3/v2) ────────────────────
# Two axes combine into the license identity:
#   LICENSE                gpl | lgpl   — GPL adds the x264/x265 software encoders
#   BUILD_LICENSE_VERSION  3 (default) | 2
# v3 = (L)GPLv3: may link the Apache-2.0 deps (OpenSSL 3.x TLS, Vulkan), so it uses
# --enable-version3. v2 = GPLv2 / LGPLv2.1 (the App-Store-safe series): NO version3,
# and the Apache-2.0 deps are dropped — GnuTLS replaces OpenSSL wherever TLS came from
# OpenSSL, and Vulkan is turned off (whisper falls back to CPU; Apple is already Metal).
LICENSE_VERSION="${BUILD_LICENSE_VERSION:-3}"

case "${LICENSE}" in
  gpl)
    CONFIGURE_FLAGS+=(--enable-gpl)
    BUILD_LIBX264=1
    BUILD_LIBX265=1
    # GPL builds get the stronger x264/x265. kvazaar is only useful as the permissive
    # HEVC encoder for the LGPL builds (where x265 can't go), so drop the redundant one.
    BUILD_LIBKVAZAAR=0
    ;;
  lgpl)
    CONFIGURE_FLAGS+=(--disable-gpl)
    # kvazaar (BSD) stays on — the LGPL builds' only software HEVC encoder.
    ;;
  *)
    echo "Error: unsupported BUILD_LICENSE '${LICENSE}' (expected gpl or lgpl)" >&2
    exit 1
    ;;
esac

case "${LICENSE_VERSION}" in
  3)
    # OpenSSL 3.x (Apache-2.0) and Vulkan are (L)GPLv3-compatible but NOT v2 — v3 needs this.
    CONFIGURE_FLAGS+=(--enable-version3)
    ;;
  2)
    # (L)GPLv2.1 / GPLv2 — drop the Apache-2.0 deps; no version3.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_VULKAN_LOADER=0
    # AMR (opencore-amr + vo-amrwbenc) is Apache-2.0 → version3-only; drop on the v2 series.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_LIBOPENCORE_AMR=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_LIBVOAMRWBENC=0
    # mbedTLS is Apache-2.0 → version3-only: drop it on v2 and default the SRT/librist transport
    # crypto to nocrypto. The gpl-2 Linux/Android cells override to GnuTLS in the TLS block below;
    # every other v2 cell (lgpl-2 everywhere + gpl-2 Win/Apple) has no v2-compatible crypto lib.
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    BUILD_MBEDTLS=0
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    SRT_ENCLIB=off
    # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
    RIST_CRYPTO=none
    [[ "${WHISPER_BACKEND}" == "vulkan" ]] && WHISPER_BACKEND="cpu"   # Apple is already metal
    # TLS for the v2 cells on Linux/Android, which have no OS-native backend. (Windows keeps
    # SChannel and macOS/iOS keep SecureTransport in every cell, so they are unaffected.)
    #   • gpl-2  → GnuTLS. Its deps GMP + nettle are dual LGPLv3+/GPLv2+; under a GPLv2 work
    #              their GPLv2+ option applies cleanly, so this is fine.
    #   • lgpl-2 → NO TLS. GMP + nettle offer no LGPLv2.1 route (GMP 6 is dual LGPLv3/GPLv2;
    #              nettle is dual GPLv2+/LGPLv3+, and GnuTLS's own README says binaries linking
    #              them must follow LGPLv3+ or GPLv2+), so linking them would force the artifact
    #              up to LGPLv3 or GPLv2 and break the LGPLv2.1 guarantee. The remaining backends
    #              are no better: mbedTLS is version3-gated by FFmpeg, and LibreSSL is not
    #              ISC-only — its COPYING keeps the OpenSSL/SSLeay terms on the inherited code.
    #              This is a conservative PROJECT POLICY on Apache-2.0 TLS combinations pending
    #              legal review, not a claim that no arrangement could ever be lawful.
    #
    # "But FFmpeg's configure ALLOWS OpenSSL here — why not just enable it?"
    # Asked and investigated more than once, so the answer lives here rather than being
    # rediscovered. The premise is CORRECT: configure only rejects OpenSSL >= 3 when --enable-gpl
    # is set without --enable-version3 —
    #     enabled gplv3 || ! enabled gpl || enabled nonfree || die "...requires --enable-version3"
    # — and in an LGPL build `! enabled gpl` is true, so FFmpeg does permit OpenSSL 3.x in this
    # cell. We decline anyway:
    #   1. FFmpeg treats the two Apache-2.0 routes inconsistently. mbedTLS sits in
    #      EXTERNAL_LIBRARY_VERSION3_LIST and FFmpeg's LICENSE.md calls that license incompatible
    #      with LGPLv2.1, while OpenSSL 3 is deliberately permitted in non-GPL builds. (mbedTLS is
    #      additionally dual Apache-2.0 / GPL-2.0-or-later, though for an LGPLv2.1 artifact the
    #      only usable route is still Apache-2.0.) The LGPL allowance was introduced ON PURPOSE by
    #      the 2021 "configure: account for openssl3 license change" commit — it is not a leftover
    #      from the pre-3.0 licence — but that commit gives no legal rationale for the LGPL branch.
    #   2. The FSF routes Apache-2.0 to GNU licences of version 3 or later, citing patent
    #      termination AND indemnification as incompatible with version 2. LGPLv2.1 §6 is the
    #      wrong provision to lean on: it covers an APPLICATION that uses an LGPL library, not a
    #      library containing another library. §7 is the relevant one and does permit combined
    #      libraries, but subject to separate-distribution and notice conditions we do not
    #      currently produce. Neither section settles the compatibility question by itself.
    #   3. openssl.sh builds no-shared, so OpenSSL object code is absorbed into the FFmpeg shared
    #      library that references it — principally libavformat — rather than being a separately
    #      installed library the user could replace.
    #
    # Precedent, among the high-profile projects reviewed: none ships a TLS-enabled LGPLv2.1
    # FFmpeg. They take one of three routes instead — OS-native TLS (libVLC/libvlccore and its
    # modules/misc/securetransport.c are LGPLv2.1+, giving macOS/iOS a native TLS client; VLC the
    # application is GPLv2+); shipping at v3 (FFmpegKit is LGPLv3; BtbN's LGPL variant starts with
    # --enable-version3 and ships COPYING.LGPLv3); or the end-user package being GPL (Debian's
    # package enables --enable-gpl, Fedora's ffmpeg-free declares GPL-3.0-or-later, the VLC-Android
    # application is GPLv2+ — though VideoLAN does publish libVLC metadata as LGPLv2.1).
    # That is not proof none exists: at least one smaller project, serversideup/ffmpeg-lgpl-builds,
    # publishes --disable-version3 builds with OpenSSL 3 statically linked and labels them
    # LGPL-2.1. Noted, not followed — its adoption is small and self-labelling is not clearance.
    #
    # Changing this is a legal decision, not a build fix: it needs counsel, not a patch.
    # Consumers who need both TLS and LGPL should take an lgplv3 cell.
    if [[ "${BUILD_OPENSSL:-0}" == "1" ]]; then
      BUILD_OPENSSL=0
      # gpl-2: GnuTLS provides FFmpeg's HTTPS/TLS. The SRT + librist transports, however, both
      # ship nocrypto on gpl-2 (SRT_ENCLIB/RIST_CRYPTO keep the v2-default off/none set above) —
      # NEITHER can use GnuTLS: SRT's gnutls enclib compiles against nettle's removed legacy AES
      # API (struct aes_ctx / aes_encrypt, gone since nettle 3.4), and librist's gnutls EAP/SRP
      # path won't compile (its verifier types are mbedTLS-only). Both v2-permissible alternatives
      # (openssl, mbedtls) are Apache-2.0/version3. So only the v3 lane gets transport crypto.
      # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
      [[ "${LICENSE}" == "gpl" ]] && BUILD_GNUTLS=1   # lgpl-2: leave TLS off for LGPLv2.1 purity
    fi
    ;;
  *)
    echo "Error: unsupported BUILD_LICENSE_VERSION '${LICENSE_VERSION}' (expected 2 or 3)" >&2
    exit 1
    ;;
esac

# Human/legal label + the artifact license token (lgplv3/gplv3/lgplv2/gplv2).
# shellcheck disable=SC2034  # LICENSE_LABEL is consumed by 10_write_legal.sh + the test scripts
case "${LICENSE}-${LICENSE_VERSION}" in
  gpl-3)  LICENSE_LABEL="GPLv3"    ;;
  gpl-2)  LICENSE_LABEL="GPLv2"    ;;
  lgpl-3) LICENSE_LABEL="LGPLv3"   ;;
  lgpl-2) LICENSE_LABEL="LGPLv2.1" ;;
esac

# ── Lean iOS simulator slice ───────────────────────────────────────────────
# The iOS simulator slice exists only for developer testing in Xcode. The
# software codec libraries have iOS-device-biased configures that don't
# cross-compile for the arm64 simulator (libvpx/x264/x265 inject device-only
# flags), and the simulator doesn't need them: built-in decoders + VideoToolbox
# cover playback there. Drop them so the slice builds and stays lean. The
# device slice keeps full parity (incl. VP8/9 for WebRTC). Runs after the
# license block so it also overrides the GPL x264/x265 enables.
if [[ "${RID}" == "ios-sim-arm64" ]]; then
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBVPX=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBX264=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBX265=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBKVAZAAR=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBOPUS=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBAOM=0
  # Drop the freetype-based text/subtitle stack as a unit: libass (and fontconfig)
  # require freetype, so disabling freetype alone would break their configure. The
  # lean testing slice doesn't need subtitle rendering.
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_FREETYPE=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_FONTCONFIG=0
  # shellcheck disable=SC2034  # set here; consumed by a sourced sibling script
  BUILD_LIBASS=0
  # (fribidi + harfbuzz are gated on BUILD_LIBASS in their dep scripts, so setting
  # BUILD_LIBASS=0 already drops them — no separate BUILD_FRIBIDI/BUILD_HARFBUZZ needed.)
fi

# libplacebo needs Vulkan (+ shaderc), so it builds exactly where Vulkan does: on the
# v3 Vulkan cells, and NOT on the v2 cells just cleared above — track BUILD_VULKAN's
# final value so the build and the coverage matrix gate it consistently. EXCEPT the
# deliberately lean iOS-simulator slice (Xcode testing; already drops x264/x265/aom/
# opus/libass), which shouldn't pull in the heavy shaderc+libplacebo chain.
# (An `if` — not `[ ] && …` — because a false test would abort the script under `set -e`.)
# shellcheck disable=SC2034  # consumed by scripts/deps/{shaderc,libplacebo}.sh
if [ "${RID}" = "ios-sim-arm64" ]; then BUILD_LIBPLACEBO=0; else BUILD_LIBPLACEBO="${BUILD_VULKAN}"; fi
