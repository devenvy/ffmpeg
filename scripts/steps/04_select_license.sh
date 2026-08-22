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
    [[ "${WHISPER_BACKEND}" == "vulkan" ]] && WHISPER_BACKEND="cpu"   # Apple is already metal
    # TLS for v2 on Linux/Android, where OpenSSL (Apache-2.0) can't be used without version3.
    # (Windows/Apple never had OpenSSL — they keep OS-native SChannel/SecureTransport.)
    #   • gpl-2  → GnuTLS. Its deps GMP + nettle are dual LGPLv3+/GPLv2+; under a GPLv2 work
    #              their GPLv2+ option applies cleanly, so this is fine.
    #   • lgpl-2 → NO TLS. GMP + nettle are NEVER LGPLv2.1, so linking them would force the
    #              artifact up to LGPLv3 (or GPLv2), breaking the LGPLv2.1 guarantee — and no
    #              other FFmpeg TLS backend is LGPLv2.1-compatible (mbedTLS = Apache-2.0/version3,
    #              LibreSSL carries the OpenSSL advertising clause). A genuine LGPLv2.1 build on
    #              Linux/Android therefore ships without https/tls.
    if [[ "${BUILD_OPENSSL:-0}" == "1" ]]; then
      BUILD_OPENSSL=0
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
