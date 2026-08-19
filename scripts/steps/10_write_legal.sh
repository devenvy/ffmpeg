#!/usr/bin/env bash
set -euo pipefail
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

# Ship the license text(s) that ACTUALLY govern this build — family (gpl/lgpl) × version
# (3/2). v3 builds use --enable-version3 (they link Apache-2.0 deps: OpenSSL 3.x / Vulkan,
# compatible with v3 but NOT v2.1/2); v2 builds (GPLv2 / LGPLv2.1, App-Store-safe) do not.
# LGPL incorporates the matching GPL text by reference, so an LGPL build ships both. FFmpeg's
# source tree carries all four COPYING files.
LICENSE_VER="${LICENSE_VERSION:-3}"
case "${LICENSE}-${LICENSE_VER}" in
  gpl-3)  cp "${SRC_DIR}/COPYING.GPLv3"   "${LEGAL_DIR}/" ;;
  gpl-2)  cp "${SRC_DIR}/COPYING.GPLv2"   "${LEGAL_DIR}/" ;;
  lgpl-3) cp "${SRC_DIR}/COPYING.LGPLv3"  "${LEGAL_DIR}/"; cp "${SRC_DIR}/COPYING.GPLv3" "${LEGAL_DIR}/" ;;
  lgpl-2) cp "${SRC_DIR}/COPYING.LGPLv2.1" "${LEGAL_DIR}/"; cp "${SRC_DIR}/COPYING.GPLv2" "${LEGAL_DIR}/" ;;
esac

# GnuTLS TLS chain (gpl-2 only — lgpl-2 drops TLS): ship each bundled dependency's license
# text so the LGPL/GPL attribution requirement is met. GMP + nettle are dual LGPLv3+/GPLv2+,
# libtasn1 is LGPLv2.1+, GnuTLS is LGPLv2.1+. Their sources are still in WORK_DIR here.
if [[ "${BUILD_GNUTLS:-0}" == "1" ]]; then
  for dep in gmp nettle libtasn1 gnutls; do
    for d in "${WORK_DIR}/${dep}"-*/; do
      [ -d "${d}" ] || continue
      mkdir -p "${LEGAL_DIR}/licenses/${dep}"
      find "${d}" -maxdepth 2 \( -iname 'COPYING*' -o -iname 'LICENSE*' \) \
        -exec cp {} "${LEGAL_DIR}/licenses/${dep}/" \; 2>/dev/null || true
    done
  done
fi

# Prominent, plain-language statement of the EFFECTIVE license — the first thing a
# consumer/auditor should read, so there's no "is this v2 or v3?" guesswork.
case "${LICENSE}-${LICENSE_VER}" in
  gpl-3)  LICENSE_FULLNAME="GNU General Public License, version 3";          GOVERNING_TEXTS="COPYING.GPLv3" ;;
  gpl-2)  LICENSE_FULLNAME="GNU General Public License, version 2";          GOVERNING_TEXTS="COPYING.GPLv2" ;;
  lgpl-3) LICENSE_FULLNAME="GNU Lesser General Public License, version 3";   GOVERNING_TEXTS="COPYING.LGPLv3 (plus COPYING.GPLv3, which it extends)" ;;
  lgpl-2) LICENSE_FULLNAME="GNU Lesser General Public License, version 2.1"; GOVERNING_TEXTS="COPYING.LGPLv2.1 (plus COPYING.GPLv2, which it extends)" ;;
esac
if [[ "${LICENSE_VER}" == "3" ]]; then
  WHY_VERSION="This build uses --enable-version3 because it links Apache-2.0 dependencies
  (OpenSSL 3.x TLS and/or Vulkan headers), whose license is compatible with version 3 of the
  (L)GPL but NOT with version 2.1/2. Its effective license is therefore VERSION 3."
else
  WHY_VERSION="This is a VERSION 2 build (App-Store-safe): it does NOT use --enable-version3
  and links no Apache-2.0 dependency. TLS is GnuTLS (gpl-2) or omitted entirely (lgpl-2, for
  which no LGPLv2.1-compatible TLS backend exists), and Vulkan is disabled."
fi
GNUTLS_NOTE=""
[[ "${BUILD_GNUTLS:-0}" == "1" ]] && GNUTLS_NOTE="
Bundled TLS stack: GnuTLS + GMP + nettle + libtasn1 — their license texts are in the
licenses/ subdirectory of this directory."
cat > "${LEGAL_DIR}/LICENSE-NOTICE.txt" <<EOF
FFmpeg ${FFMPEG_VERSION} — ${RID}

EFFECTIVE LICENSE:  ${LICENSE_LABEL} (${LICENSE_FULLNAME})

Governing license text: ${GOVERNING_TEXTS}

${WHY_VERSION}
${GNUTLS_NOTE}
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
  if   [[ "${BUILD_OPENSSL}" == "1" ]]; then echo "OpenSSL"
  elif [[ "${BUILD_GNUTLS:-0}" == "1" ]]; then echo "GnuTLS (with GMP, nettle, libtasn1)"
  elif [[ "${RID}" == win-* ]]; then echo "SChannel"
  elif [[ "${RID}" == osx-* || "${RID}" == ios-* ]]; then echo "SecureTransport"
  else echo "none (LGPLv2.1 has no license-compatible TLS backend on this platform)"; fi
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
