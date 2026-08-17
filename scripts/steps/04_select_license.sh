#!/usr/bin/env bash
############################################
# Step 4: Select License
#
# Apply the GPL or LGPL flag — GPL adds the x264/x265 software encoders —
# and, for the lean iOS-simulator slice, drop the software codec libraries
# it doesn't need.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── License flag ──────────────────────────────────────────────────────────

case "${LICENSE}" in
  gpl)
    CONFIGURE_FLAGS+=(--enable-gpl)
    LICENSE_LABEL="GPLv3"
    BUILD_LIBX264=1
    BUILD_LIBX265=1
    # GPL builds get the stronger x264/x265. kvazaar is only useful as the
    # permissive HEVC encoder for the LGPL builds (where x265 can't go), so drop
    # it here rather than ship a weaker redundant encoder.
    BUILD_LIBKVAZAAR=0
    ;;
  lgpl)
    CONFIGURE_FLAGS+=(--disable-gpl)
    LICENSE_LABEL="LGPLv3"
    # kvazaar (BSD) stays on — it is the LGPL builds' only software HEVC encoder,
    # the H.265 counterpart to OpenH264 for H.264.
    ;;
  *)
    echo "Error: unsupported BUILD_LICENSE '${LICENSE}' (expected gpl or lgpl)" >&2
    exit 1
    ;;
esac

# Every build is (L)GPL *version 3*, uniformly across all platforms. We build with
# OpenSSL 3.x (Apache-2.0) for TLS, which is compatible with (L)GPLv3 but NOT with
# v2.1/v2, so FFmpeg requires --enable-version3. We apply it unconditionally (not
# just where OpenSSL is linked) so there is a single, unambiguous license version
# for the whole matrix — no per-platform juggling of v2-vs-v3. This mirrors the
# reference BtbN builds, which also ship (L)GPLv3.
CONFIGURE_FLAGS+=(--enable-version3)

# ── Lean iOS simulator slice ───────────────────────────────────────────────
# The iOS simulator slice exists only for developer testing in Xcode. The
# software codec libraries have iOS-device-biased configures that don't
# cross-compile for the arm64 simulator (libvpx/x264/x265 inject device-only
# flags), and the simulator doesn't need them: built-in decoders + VideoToolbox
# cover playback there. Drop them so the slice builds and stays lean. The
# device slice keeps full parity (incl. VP8/9 for WebRTC). Runs after the
# license block so it also overrides the GPL x264/x265 enables.
if [[ "${RID}" == "ios-sim-arm64" ]]; then
  BUILD_LIBVPX=0
  BUILD_LIBX264=0
  BUILD_LIBX265=0
  BUILD_LIBKVAZAAR=0
  BUILD_LIBOPUS=0
  BUILD_LIBAOM=0
  BUILD_FREETYPE=0
fi
