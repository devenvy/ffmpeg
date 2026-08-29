#!/usr/bin/env bash
set -euo pipefail
# kissfft — small FFT library (BSD-3). chromaprint's build compiles kissfft's kiss_fft.c +
# kiss_fftr.c DIRECTLY from source (its FindKissFFT.cmake wants KISSFFT_SOURCE_DIR with
# kiss_fftr.h/.c — it does NOT link a prebuilt libkissfft), so we only fetch the source tree
# here; chromaprint.sh points -DKISSFFT_SOURCE_DIR at ${WORK_DIR}/kissfft. No build, no install,
# no FFmpeg flag. SOURCED by scripts/build.sh. Not a standalone script.

[[ "${BUILD_KISSFFT}" == "1" ]] || { echo "Skipping kissfft (not needed for ${RID})."; return 0; }

echo "Fetching kissfft source (chromaprint dependency)..."
cd "${WORK_DIR}" || exit 1
rm -rf kissfft
clone_dep kissfft "${WORK_DIR}/kissfft"
echo "kissfft source ready at ${WORK_DIR}/kissfft."
