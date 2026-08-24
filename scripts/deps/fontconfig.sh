#!/usr/bin/env bash
set -euo pipefail
# fontconfig — system font discovery (MIT) so drawtext can pick fonts by name.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_FONTCONFIG}" == "1" ]]; then
  echo "Building fontconfig (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf fontconfig
  clone_dep fontconfig "${WORK_DIR}/fontconfig"
  cd fontconfig || exit 1

  FC_ARGS=(
    --prefix="${DEPS_DIR}"
    --libdir="${DEPS_DIR}/lib"
    --default-library=static
    --buildtype=release
    -Ddoc=disabled
    -Dtests=disabled
    -Dtools=disabled
    -Dcache-build=disabled
  )

  # Cross targets use the shared Meson cross file written in step 05.
  [[ -n "${MESON_CROSS_FILE:-}" ]] && FC_ARGS+=(--cross-file "${MESON_CROSS_FILE}")

  meson setup build "${FC_ARGS[@]}"
  meson compile -C build
  meson install -C build

  CONFIGURE_FLAGS+=(--enable-libfontconfig)
  echo "fontconfig (system font access) enabled."
else
  echo "Skipping fontconfig (not needed for ${RID})."
fi
