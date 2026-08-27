#!/usr/bin/env bash
set -euo pipefail
# libgsm — GSM 06.10 full-rate speech codec (permissive, TU-Berlin). Enables FFmpeg's
# libgsm de/encoder. FFmpeg finds it via `check_lib libgsm gsm.h gsm_create -lgsm` (no
# pkg-config). SOURCED by scripts/build.sh (shares env; appends --enable-* to
# CONFIGURE_FLAGS). Not a standalone script.
#
# NON-STANDARD PACKAGING (the tricky one): libgsm ships a hand-written top-level
# Makefile with NO ./configure and NO `make install` target. Its Makefile hardcodes the
# host toolchain (CC = gcc, AR = ar, RANLIB = ranlib) and does not honour a --host cross
# triple, so we override those make variables on the command line to inject the cross
# toolchain + -fPIC, build ONLY the static lib target (lib/libgsm.a — skipping the toast
# CLI tools, which need extra headers), then MANUALLY copy the lib + header into DEPS_DIR.
#
# LIKELY TWEAK POINT: the make-variable names below (CC/AR/RANLIB and the lib/libgsm.a
# target) follow libgsm-1.0.22's Makefile. If a version bump renames them, this is the
# line to adjust. We deliberately do NOT pass GSM_INSTALL_ROOT to `make install` (the
# Makefile's install target is unreliable / assumes system paths) — we install by hand.

[[ "${BUILD_LIBGSM}" == "1" ]] || { echo "Skipping libgsm (not needed for ${RID})."; return 0; }

gsm_ver="$(dep_version libgsm)"
echo "Building libgsm ${gsm_ver} (static)..."
cd "${WORK_DIR}" || exit 1
curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 30 \
  "https://www.quut.com/gsm/gsm-${gsm_ver}.tar.gz" -o gsm.tar.gz
# The tarball's top dir is NOT gsm-${ver} — libgsm names it by version+patchlevel
# (gsm-1.0.22.tar.gz extracts to gsm-1.0-pl22/). Extract, then glob the one gsm-*/ dir.
# (Avoid `tar -tzf | head` to find it: head closes the pipe early → tar gets SIGPIPE →
# trips `set -o pipefail` and aborts the sourced script with exit 141.)
rm -rf gsm-*/
tar -xf gsm.tar.gz
cd gsm-*/ || exit 1

# Build just the static archive. Override the hardcoded toolchain (the Makefile's own
# CC/AR/RANLIB assume a native gcc) with our cross toolchain + PIC/EXTRA_CFLAGS. libgsm's
# Makefile uses `AR ... $(ARFLAGS)` with ARFLAGS defaulting to `cr`, so we keep AR as the
# archiver alone and pass the flags via ARFLAGS to stay compatible.
make -j"$(${NPROC})" lib/libgsm.a \
  CC="${CC:-cc} -fPIC ${EXTRA_CFLAGS:-}" \
  AR="${AR:-ar}" ARFLAGS="cr" \
  RANLIB="${RANLIB:-ranlib}"

# Manual install — the Makefile has no `install` target we can rely on.
mkdir -p "${DEPS_DIR}/lib" "${DEPS_DIR}/include"
cp -a lib/libgsm.a "${DEPS_DIR}/lib/"
cp -a inc/gsm.h "${DEPS_DIR}/include/"

# FFmpeg's `check_lib libgsm gsm.h gsm_create -lgsm` must find gsm.h. -I${DEPS_DIR}/include
# is added globally in 06_build_libraries.sh, but ensure it's present here too (idempotent).
case " ${EXTRA_CFLAGS:-} " in
  *" -I${DEPS_DIR}/include "*) : ;;
  *) EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }-I${DEPS_DIR}/include" ;;
esac

CONFIGURE_FLAGS+=(--enable-libgsm)
echo "libgsm (GSM 06.10 de/encode) enabled."
