#!/usr/bin/env bash
set -euo pipefail
# libass — SSA/ASS subtitle renderer (ISC). Needs fribidi + harfbuzz + freetype
# + fontconfig (all built earlier). SOURCED by scripts/build.sh (uses
# MESON_CROSS_FILE for cross targets; appends --enable-libass). Not standalone.

[[ "${BUILD_LIBASS}" == "1" ]] || { echo "Skipping libass (not needed for ${RID})."; return 0; }

echo "Building libass (static)..."
cd "${WORK_DIR}" || exit 1
rm -rf libass
clone_dep libass "${WORK_DIR}/libass"
cd libass || exit 1
# fontconfig is only built where the platform uses it (off on Windows/mobile,
# which fall back to DirectWrite/CoreText or an explicit fontfile=).
FC_OPT="-Dfontconfig=disabled"
[[ "${BUILD_FONTCONFIG}" == "1" ]] && FC_OPT="-Dfontconfig=enabled"
ASS_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
          --buildtype=release "${FC_OPT}" -Dtest=disabled)
# Windows/Apple provide DirectWrite/CoreText; Linux uses fontconfig. Android has
# none, so let libass build without a system font provider (fonts are supplied
# explicitly at runtime).
case "${RID}" in
  android-*) ASS_ARGS+=(-Drequire-system-font-provider=false) ;;
esac
# libass enables its x86 SIMD via NASM, but Android links everything
# position-independent and meson's Nasm support cannot emit a PIE — configure aborts with
# "ERROR: Language Nasm does not support position-independent executable". Only android-x64
# is affected: android-arm64 has no nasm path, and the other x86 targets (linux-x64,
# linux-musl-x64, win-x64) are not PIE-forced, so they keep their assembly. The cost here is
# scalar subtitle rasterisation on one RID.
case "${RID}" in
  android-x64) ASS_ARGS+=(-Dasm=disabled) ;;
esac
[[ -n "${MESON_CROSS_FILE:-}" ]] && ASS_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${ASS_ARGS[@]}"
# libass's x86 SIMD is decided by meson (-Dasm defaults to auto), and a missing or too-old NASM
# turns it into a warning and a scalar build -- the library still works, just slower at subtitle
# rasterisation, so nothing downstream notices. We control NASM's presence through the package
# lists, so on the x86-64 RIDs where we expect assembly it should be an error if it vanished.
# android-x64 is the deliberate exception (meson's Nasm cannot emit PIE; disabled above).
case "${RID}" in
  linux-x64|linux-musl-x64|win-x64|osx-x64|maccatalyst-x64)
    if ! grep -qE '^#define[[:space:]]+CONFIG_ASM' build/config.h 2>/dev/null; then
      echo "ERROR: libass config.h has no CONFIG_ASM line at all on ${RID}." >&2
      echo "  The probe cannot answer the question, so it fails rather than passing blind." >&2
      echo "  (libass renamed the macro? update this check -- do not delete it.)" >&2
      exit 1
    fi
    if ! grep -qE '^#define[[:space:]]+CONFIG_ASM[[:space:]]+1' build/config.h; then
      echo "ERROR: libass built WITHOUT x86 assembly on ${RID} (CONFIG_ASM is not 1)." >&2
      echo "  meson downgrades this to a warning when NASM is missing or older than 2.10." >&2
      echo "  nasm: $(command -v nasm || echo 'NOT FOUND') $(nasm -v 2>/dev/null || true)" >&2
      exit 1
    fi
    echo "libass: x86 assembly verified enabled."
    ;;
esac
meson compile -C build -j "$(${NPROC})"
meson install -C build
CONFIGURE_FLAGS+=(--enable-libass)
echo "libass (SSA/ASS subtitle rendering) enabled."
