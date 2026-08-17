#!/usr/bin/env bash
# fontconfig — system font discovery (MIT) so drawtext can pick fonts by name.
# Builds expat first as a dependency.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_FONTCONFIG}" == "1" ]]; then
  # expat has a non-standard repo layout (CMakeLists.txt is in expat/ subdir)
  echo "Building libexpat (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf libexpat
  git clone --depth 1 --branch R_2_6_2 https://github.com/libexpat/libexpat.git
  cd libexpat/expat || exit 1
  cmake -B build \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${DEPS_DIR}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
    -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_DOCS=OFF
  cmake --build build -j"$(${NPROC})"
  cmake --install build
  echo "expat built (fontconfig dependency)."

  echo "Building fontconfig (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf fontconfig
  git clone --depth 1 --branch 2.15.0 https://gitlab.freedesktop.org/fontconfig/fontconfig.git
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
