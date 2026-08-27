#!/usr/bin/env bash
set -euo pipefail
# mbedtls — compact TLS/crypto library (Apache-2.0 → version3-only). This is NOT FFmpeg's
# own TLS backend: OpenSSL (v3) / GnuTLS (gpl-2) keep that, because they auto-load the system
# CA store and tls_mbedtls.c does not. mbedTLS here is the shared *transport* crypto that both
# SRT (USE_ENCLIB=mbedtls) and librist (use_mbedtls) consume on the v3 cells — librist can't
# use OpenSSL at all, so the transports need their own crypto lib regardless of FFmpeg's TLS.
#
# deps.json pins the git tag (v<ver>) with a datasource so Renovate tracks it, but we DOWNLOAD
# the matching release tarball (mbedtls-<ver>.tar.bz2) rather than cloning: the git tag carries a
# 'framework' submodule (a bare pointer — needs a submodule init), whereas the release tarball
# bundles the framework in-tree. Both ship the auto-generated PSA-crypto files pre-generated, so
# either way there's no Python (jinja2/jsonschema) needed — the tarball just avoids the submodule
# dance. dep_version yields the tag "v<ver>"; strip the leading v for the tarball's bare version.
#
# SOURCED by scripts/build.sh (shares env). Not a standalone script. No FFmpeg --enable-* flag.

[[ "${BUILD_MBEDTLS}" == "1" ]] || { echo "Skipping mbedtls (not needed for ${RID})."; return 0; }

mbed_ver="$(dep_version mbedtls)"; mbed_ver="${mbed_ver#v}"   # v3.6.7 -> 3.6.7 (tarball bare version)
echo "Building mbedtls ${mbed_ver} (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf "mbedtls-${mbed_ver}"
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${mbed_ver}/mbedtls-${mbed_ver}.tar.bz2" \
  -o mbedtls.tar.bz2
tar -xf mbedtls.tar.bz2
cd "mbedtls-${mbed_ver}" || exit 1

# Static libs only; no tests/programs/fuzzers. Installs libmbed{tls,x509,crypto}.a + headers +
# pkg-config (.pc) + cmake package config into DEPS_DIR, so SRT finds it via find_package(MbedTLS)
# and librist via pkg-config. The cmake wrapper (scripts/lib.sh) injects the policy minimum;
# CMAKE_CROSS_ARGS carries the per-RID toolchain file for cross targets.
cmake -B _build \
  -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="${DEPS_DIR}" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
  -DENABLE_TESTING=OFF \
  -DENABLE_PROGRAMS=OFF \
  ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"}
cmake --build _build -j"$(${NPROC})"
cmake --install _build

# Re-add mbedTLS as -l libs at the END of FFmpeg's link (EXTRA_LIBS). Both transports leave their
# mbedTLS symbols unresolved otherwise: srt.pc lists mbedTLS as ABSOLUTE .a paths, which FFmpeg
# classifies as input objects and places BEFORE -lsrt (so libsrt's cryspr-mbedtls.o refs are
# already discarded → undefined), and librist.pc omits mbedTLS entirely. Appending them here (after
# -lsrt/-lrist, which appear earlier) lets the linker resolve both. -L is on EXTRA_LDFLAGS (06).
# Order high-level → low so the inter-mbedTLS deps resolve left-to-right (tls → x509 → crypto).
EXTRA_LIBS="${EXTRA_LIBS:-} -lmbedtls -lmbedx509 -lmbedcrypto"
echo "mbedtls (SRT + librist transport crypto) built."
