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
. "${D}/lcms2.sh"        # ICC color management (FFmpeg iccdetect/iccgen; libjxl + libplacebo dep)
. "${D}/libxml2.sh"      # XML parser — FFmpeg DASH demuxer + IMF
. "${D}/libpng.sh"       # PNG image support (freetype dependency)
. "${D}/freetype.sh"     # text rendering (drawtext)
. "${D}/fribidi.sh"      # bidirectional text (libass dependency)
. "${D}/harfbuzz.sh"     # text shaping (libass dependency)
. "${D}/libexpat.sh"     # XML parser (fontconfig dependency)
. "${D}/fontconfig.sh"   # system font discovery
. "${D}/libass.sh"       # SSA/ASS subtitle rendering
. "${D}/libogg.sh"       # Ogg container (libvorbis dependency)
. "${D}/libvorbis.sh"    # Vorbis audio
. "${D}/opus.sh"         # Opus audio
. "${D}/libmp3lame.sh"   # MP3 audio encoder
. "${D}/soxr.sh"         # high-quality audio resampling (soxr backend for aresample)
. "${D}/aom.sh"          # AV1 reference encoder/decoder (libaom)
. "${D}/svtav1.sh"       # fast AV1 encoder (SVT-AV1)
. "${D}/libwebp.sh"      # WebP image
. "${D}/openjpeg.sh"     # JPEG 2000 (--enable-libopenjpeg)
. "${D}/zimg.sh"         # high-quality scaling/colorspace conversion
. "${D}/libvmaf.sh"      # VMAF perceptual quality metric (--enable-libvmaf)
. "${D}/openssl.sh"      # TLS/https, v3 series (Linux + Android; native backends elsewhere)
# GnuTLS chain — TLS/https for the v2 series (LGPLv2.1+/GPLv2), replacing OpenSSL where
# it can't ship. All four self-skip unless BUILD_GNUTLS=1. Dependency order matters.
. "${D}/gmp.sh"          #   bignum (GMP)
. "${D}/nettle.sh"       #   crypto (nettle/hogweed; needs GMP)
. "${D}/libtasn1.sh"     #   ASN.1
. "${D}/gnutls.sh"       #   GnuTLS (needs the three above; appends --enable-gnutls)
. "${D}/brotli.sh"       # compression — libjxl dependency (no FFmpeg flag)
. "${D}/vulkan-headers.sh"  # Vulkan headers (FFmpeg hwaccel/filters + whisper's ggml backend)
. "${D}/vulkan-loader.sh"   # (glibc Linux / macOS) libc-only loader to bundle — needs headers above
. "${D}/moltenvk.sh"        # MoltenVK Vulkan-over-Metal ICD (v3 macOS only; pairs with the loader)
. "${D}/spirv-headers.sh"   # SPIRV-Headers for whisper's ggml-vulkan backend (mingw/NDK/musl/linux)
. "${D}/whisper.sh"         # whisper.cpp — af_whisper ASR (links the Vulkan loader above)
. "${D}/shaderc.sh"         # SPIR-V compiler (static lib) — libplacebo build dependency (v3 Vulkan cells)
. "${D}/libplacebo.sh"      # GPU HDR tone-map/scaling via Vulkan — FFmpeg libplacebo filter

# Ensure deps dirs are in compiler/linker search paths
EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }-I${DEPS_DIR}/include"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:+${EXTRA_LDFLAGS} }-L${DEPS_DIR}/lib"
