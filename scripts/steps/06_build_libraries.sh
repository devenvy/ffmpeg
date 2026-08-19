#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 6: Build Third-Party Libraries
#
# Build every bundled library as a static dependency — one script per
# library in scripts/deps/, each sourced so it shares this environment and
# appends its --enable-* to CONFIGURE_FLAGS. Comment out a line below to skip
# that library when debugging.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

D="${ROOT_DIR}/scripts/deps"
. "${D}/nv-codec.sh"     # NVIDIA codec headers (NVENC/NVDEC/CUVID)
. "${D}/amf.sh"          # AMD AMF headers (Windows)
. "${D}/libdrm.sh"       # DRM userspace (static on Linux; VAAPI + --enable-libdrm)
. "${D}/libva.sh"        # VA-API dispatcher (static on Linux; needs libdrm)
. "${D}/libvpl.sh"       # Intel QSV dispatcher (oneVPL)
. "${D}/libvpx.sh"       # VP8/VP9
. "${D}/libx264.sh"      # H.264 software encoder (GPL builds)
. "${D}/libx265.sh"      # H.265 software encoder (GPL builds)
. "${D}/openh264.sh"     # H.264 software encoder (BSD — LGPL builds too)
. "${D}/kvazaar.sh"      # H.265 software encoder (BSD — LGPL builds too)
. "${D}/dav1d.sh"        # fast AV1 decoder
. "${D}/zlib.sh"         # zlib compression
. "${D}/freetype.sh"     # text rendering (drawtext)
. "${D}/fribidi.sh"      # bidirectional text (libass dependency)
. "${D}/harfbuzz.sh"     # text shaping (libass dependency)
. "${D}/fontconfig.sh"   # system font discovery
. "${D}/libass.sh"       # SSA/ASS subtitle rendering
. "${D}/libogg.sh"       # Ogg container (libvorbis dependency)
. "${D}/libvorbis.sh"    # Vorbis audio
. "${D}/opus.sh"         # Opus audio
. "${D}/libmp3lame.sh"   # MP3 audio encoder
# . "${D}/soxr.sh"       # high-quality resampling — deferred: FFmpeg's direct
#                        # -lsoxr check needs -lm link-ordering; swresample covers it
. "${D}/aom.sh"          # AV1 reference encoder/decoder (libaom)
. "${D}/svtav1.sh"       # fast AV1 encoder (SVT-AV1)
. "${D}/libwebp.sh"      # WebP image
. "${D}/zimg.sh"         # high-quality scaling/colorspace conversion
. "${D}/openssl.sh"      # TLS/https (Linux + Android; native backends elsewhere)
. "${D}/vulkan.sh"       # Vulkan headers + (glibc Linux) a libc-only loader to bundle
. "${D}/whisper.sh"      # whisper.cpp — af_whisper ASR (links the Vulkan loader above)

# Ensure deps dirs are in compiler/linker search paths
EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }-I${DEPS_DIR}/include"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:+${EXTRA_LDFLAGS} }-L${DEPS_DIR}/lib"
