#!/usr/bin/env bash
set -euo pipefail
# kissfft — small mixed-radix FFT (BSD-3). Not an FFmpeg dependency itself: it's the
# FFT backend for chromaprint (built next). We build the static lib + its CMake
# find-package config so chromaprint's find_package(KissFFT) locates it. No FFmpeg flag.
# SOURCED by scripts/build.sh (shares env). Not a standalone script.

[[ "${BUILD_KISSFFT}" == "1" ]] || { echo "Skipping kissfft (not needed for ${RID})."; return 0; }

# KISSFFT_STATIC=ON + KISSFFT_PKGCONFIG=ON: static lib + a find-package config for
# chromaprint. KISSFFT_USE_ALLOCA=OFF: use malloc (alloca is non-portable across the
# cross toolchains). TEST/TOOLS off: just the library.
build_cmake_dep kissfft \
  -DKISSFFT_TEST=OFF -DKISSFFT_TOOLS=OFF -DKISSFFT_STATIC=ON \
  -DKISSFFT_PKGCONFIG=ON -DKISSFFT_USE_ALLOCA=OFF

echo "kissfft (chromaprint dependency) built."
