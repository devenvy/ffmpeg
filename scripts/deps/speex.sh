#!/usr/bin/env bash
set -euo pipefail
# speex — Speex speech codec (BSD/Xiph). Enables FFmpeg's libspeex de/encoder. SOURCED by
# scripts/build.sh (shares env; appends --enable-* to CONFIGURE_FLAGS). Not a standalone script.

[[ "${BUILD_LIBSPEEX}" == "1" ]] || { echo "Skipping speex (not needed for ${RID})."; return 0; }

echo "Building speex (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf speex
clone_dep speex "${WORK_DIR}/speex"
cd speex || exit 1
# The git tree ships no generated configure — regenerate it (autoconf/automake/libtool are in
# the build env). Xiph's autogen.sh runs autoreconf; run it non-interactively.
./autogen.sh >/dev/null 2>&1 || autoreconf -fi
SPX_ARGS=(--prefix="${DEPS_DIR}" --disable-shared --enable-static --with-pic
          --disable-binaries)   # libspeex only; skip speexenc/speexdec CLIs
[ -n "${CROSS_HOST:-}" ] && SPX_ARGS+=(--host="${CROSS_HOST}")
./configure "${SPX_ARGS[@]}"
make -j"$(${NPROC})"
make install
CONFIGURE_FLAGS+=(--enable-libspeex)
echo "libspeex (Speex de/encode) enabled."
