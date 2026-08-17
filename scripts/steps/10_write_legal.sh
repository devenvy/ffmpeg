#!/usr/bin/env bash
############################################
# Step 10: Write Legal & Build Info
#
# Copy the applicable license texts and render the corresponding-source
# notice (SOURCE_OFFER.txt) into legal/, then write build-info.txt
# describing this exact build (version, RID, license, hwaccel, codecs).
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── License & compliance files ────────────────────────────────────────────

LEGAL_DIR="${OUT_DIR}/legal"
mkdir -p "${LEGAL_DIR}"

cp "${SRC_DIR}/LICENSE.md" "${LEGAL_DIR}/"
cp "${SRC_DIR}/CREDITS" "${LEGAL_DIR}/" 2>/dev/null || true

# Every build is (L)GPL *version 3* (see 04_select_license.sh: --enable-version3 is
# unconditional because we link OpenSSL 3.x / Apache-2.0). Ship ONLY the governing
# v3 text — not the v2.1/v2 text — so there is no ambiguity about which version
# applies. LGPLv3 is defined as a set of additional permissions on top of GPLv3, so
# an LGPLv3 build must ALSO include the GPLv3 text.
case "${LICENSE}" in
  gpl)
    cp "${SRC_DIR}/COPYING.GPLv3" "${LEGAL_DIR}/"
    ;;
  lgpl)
    cp "${SRC_DIR}/COPYING.LGPLv3" "${LEGAL_DIR}/"
    cp "${SRC_DIR}/COPYING.GPLv3" "${LEGAL_DIR}/"   # LGPLv3 incorporates GPLv3 by reference
    ;;
esac

# Prominent, plain-language statement of the EFFECTIVE license version. This is the
# first thing a consumer/auditor should read — it removes any "is this v2 or v3?"
# guesswork that copying multiple COPYING files would otherwise create.
if [[ "${LICENSE}" == "lgpl" ]]; then
  LICENSE_FULLNAME="GNU Lesser General Public License, version 3"
  GOVERNING_TEXTS="COPYING.LGPLv3 (plus COPYING.GPLv3, which it extends)"
else
  LICENSE_FULLNAME="GNU General Public License, version 3"
  GOVERNING_TEXTS="COPYING.GPLv3"
fi
cat > "${LEGAL_DIR}/LICENSE-NOTICE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION} — ${RID}

EFFECTIVE LICENSE:  ${LICENSE_LABEL} (${LICENSE_FULLNAME})

Governing license text: ${GOVERNING_TEXTS}

Why version 3 (not 2.1/2):
  FFmpeg's own code is "(L)GPL v2.1 or later", so it could in principle be used
  under version 2.1. THIS build, however, is compiled with --enable-version3
  because it links OpenSSL 3.x, whose Apache-2.0 license is compatible with
  version 3 of the (L)GPL but NOT with version 2.1/2. The effective license of
  this combined work is therefore VERSION 3, uniformly on every platform
  (Windows/macOS/Linux/Android/iOS) — there is no v2 variant of these builds.

Corresponding source: see SOURCE_OFFER.txt in this directory.
EOF

# Corresponding-source notice: a static template checked into the repo
# (SOURCE_OFFER.txt), copied in with a few fields filled — we do NOT regenerate a
# per-component source list here. The build script itself is the authoritative,
# pinned list of every component and its version; the notice just points at it.
REPO_LINE="${SOURCE_REPO_URL:-the public build repository this artifact was produced from}"
[[ -n "${SOURCE_REPO_URL:-}" && -n "${SOURCE_REPO_REF:-}" ]] && \
  REPO_LINE="${SOURCE_REPO_URL} (ref ${SOURCE_REPO_REF})"
sed -e "s|@FFMPEG_VERSION@|${FFMPEG_VERSION}|g" \
    -e "s|@LICENSE@|${LICENSE_LABEL}|g" \
    -e "s|@RID@|${RID}|g" \
    -e "s|@REPO@|${REPO_LINE}|g" \
    "${ROOT_DIR}/SOURCE_OFFER.txt" > "${LEGAL_DIR}/SOURCE_OFFER.txt"

cat > "${ROOT_DIR}/artifacts/${RID}/build-info.txt" <<EOF
FFmpeg version: ${FFMPEG_VERSION}
RID: ${RID}
License: ${LICENSE_LABEL}
Build type: ${BUILD_TYPE_LABEL} (${LICENSE_LABEL} shared)
Hardware acceleration: ${HWACCEL_FEATURES}
Vulkan: ${VULKAN_STATUS}
Software codecs: libvpx (VP8/VP9)$(
  [[ "${BUILD_LIBX264}" == "1" ]] && echo ", libx264 (H.264)"
)$(
  [[ "${BUILD_LIBX265}" == "1" ]] && echo ", libx265 (H.265)"
)$(
  [[ "${BUILD_LIBOPENH264}" == "1" ]] && echo ", OpenH264 (H.264)"
)$(
  [[ "${BUILD_LIBKVAZAAR}" == "1" ]] && echo ", kvazaar (H.265)"
)$(
  [[ "${BUILD_LIBOPUS}" == "1" ]] && echo ", libopus (Opus)"
)$(
  [[ "${BUILD_LIBMP3LAME}" == "1" ]] && echo ", libmp3lame (MP3)"
)$(
  [[ "${BUILD_LIBVORBIS}" == "1" ]] && echo ", libvorbis (Vorbis)"
)$(
  [[ "${BUILD_LIBAOM}" == "1" ]] && echo ", libaom (AV1)"
)$(
  [[ "${BUILD_LIBSVTAV1}" == "1" ]] && echo ", SVT-AV1"
)$(
  [[ "${BUILD_LIBDAV1D}" == "1" ]] && echo ", dav1d (AV1 decode)"
)$(
  [[ "${BUILD_LIBWEBP}" == "1" ]] && echo ", libwebp (WebP)"
)
TLS/https: $(
  if [[ "${BUILD_OPENSSL}" == "1" ]]; then echo "OpenSSL"
  elif [[ "${RID}" == win-* ]]; then echo "SChannel"
  else echo "SecureTransport"; fi
)
Libraries: $(
  [[ "${BUILD_ZLIB}" == "1" ]] && echo -n "zlib, "
)$(
  [[ "${BUILD_FREETYPE}" == "1" ]] && echo -n "freetype, "
)$(
  [[ "${BUILD_FONTCONFIG}" == "1" ]] && echo -n "fontconfig, "
)$(
  [[ "${BUILD_LIBASS}" == "1" ]] && echo -n "libass, "
)$(
  [[ "${BUILD_LIBZIMG}" == "1" ]] && echo -n "zimg, "
)built-in decoders
EOF

echo ""
echo "Done! FFmpeg binaries in ${OUT_DIR}"
