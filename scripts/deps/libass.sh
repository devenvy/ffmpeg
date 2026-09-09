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
meson compile -C build -j "$(${NPROC})"
meson install -C build
CONFIGURE_FLAGS+=(--enable-libass)
echo "libass (SSA/ASS subtitle rendering) enabled."
