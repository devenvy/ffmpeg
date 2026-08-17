#!/usr/bin/env bash
# Shared build helpers: the cmake policy wrapper and build_cmake_dep, used by
# the dependency scripts. Sourced by build.sh before the build steps run.

# ── CMake wrapper: inject policy minimum for older third-party projects ────
# Newer CMake (4.x on macOS) rejects old cmake_minimum_required() calls.
# This wrapper adds -DCMAKE_POLICY_VERSION_MINIMUM=3.5 to all configure
# invocations so we don't need to repeat it per dependency.
cmake() {
  if [[ "$1" == "--build" || "$1" == "--install" ]]; then
    command cmake "$@"
  else
    command cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  fi
}

# ── Helper: build a CMake-based static dependency ─────────────────────────

build_cmake_dep() {
  local name="$1" url="$2" branch="$3"; shift 3
  echo "Building ${name} (static)..."
  cd "${WORK_DIR}" || return 1
  rm -rf "${name}"
  git clone --depth 1 ${branch:+--branch "$branch"} "$url" "$name"
  cd "$name" || return 1
  cmake -B build \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${DEPS_DIR}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
    "$@"
  cmake --build build -j"$(${NPROC})"
  cmake --install build
}
