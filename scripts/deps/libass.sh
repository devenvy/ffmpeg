#!/usr/bin/env bash
# libass — SSA/ASS subtitle renderer (ISC). Needs fribidi + harfbuzz + freetype
# + fontconfig (all built earlier). SOURCED by scripts/build.sh (uses
# MESON_CROSS_FILE for cross targets; appends --enable-libass). Not standalone.

[[ "${BUILD_LIBASS}" == "1" ]] || { echo "Skipping libass (not needed for ${RID})."; return 0; }

echo "Building libass (static)..."
cd "${WORK_DIR}"
rm -rf libass
git clone --depth 1 --branch 0.17.3 https://github.com/libass/libass.git
cd libass
# fontconfig is only built where the platform uses it (off on Windows/mobile,
# which fall back to DirectWrite/CoreText or an explicit fontfile=).
FC_OPT="-Dfontconfig=disabled"
[[ "${BUILD_FONTCONFIG}" == "1" ]] && FC_OPT="-Dfontconfig=enabled"
ASS_ARGS=(--prefix="${DEPS_DIR}" --libdir=lib --default-library=static
          --buildtype=release "${FC_OPT}" -Dtest=false)
# Windows/Apple provide DirectWrite/CoreText; Linux uses fontconfig. Android has
# none, so let libass build without a system font provider (fonts are supplied
# explicitly at runtime).
case "${RID}" in
  android-*) ASS_ARGS+=(-Drequire-system-font-provider=false) ;;
esac
[[ -n "${MESON_CROSS_FILE:-}" ]] && ASS_ARGS+=(--cross-file "${MESON_CROSS_FILE}")
meson setup build "${ASS_ARGS[@]}"
meson compile -C build -j "$(${NPROC})"
meson install -C build
CONFIGURE_FLAGS+=(--enable-libass)
echo "libass (SSA/ASS subtitle rendering) enabled."
