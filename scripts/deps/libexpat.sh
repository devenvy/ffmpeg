#!/usr/bin/env bash
set -euo pipefail
# libexpat — XML parser (MIT) for fontconfig.
# SOURCED by scripts/build.sh (shares its environment; appends its --enable-*
# to CONFIGURE_FLAGS where applicable). Not a standalone script.

if [[ "${BUILD_FONTCONFIG}" == "1" ]]; then
  # expat has a non-standard repo layout (CMakeLists.txt is in expat/ subdir)
  echo "Building libexpat (static)..."
  cd "${WORK_DIR}" || exit 1
  rm -rf libexpat
  clone_dep libexpat "${WORK_DIR}/libexpat"
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
else
  echo "Skipping libexpat."
fi
