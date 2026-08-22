#!/usr/bin/env bash
set -euo pipefail
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

# ── curl wrapper: retry downloads on transient network failures ───────────
# The dependency tarball downloads hit the same transient blips as the git clones (a CDN
# returns a short/garbage response). Inject retry flags so a hiccup doesn't fail the build.
# curl takes the LAST of a repeated option, so a dep that passes its own --retry still wins;
# --retry-connrefused is in curl >= 7.52 (present on the old manylinux image). We do NOT add
# --retry-all-errors here — it needs curl >= 7.71, which the manylinux image predates (the
# FFmpeg download step probes for it separately).
curl() {
  command curl --retry 5 --retry-delay 3 --retry-connrefused "$@"
}

# ── git wrapper: retry clones on transient network failures ───────────────
# Dependency source clones intermittently fail when the remote returns an HTML error
# page instead of the git protocol ("could not determine hash algorithm", "bad line
# length character: <!do…") — a transient blip, not a real error. Retry a few times so
# one hiccup doesn't fail the whole build/CI run. git clone removes its target directory
# on failure, so a plain re-clone is safe. Falls through to real git for everything else.
git() {
  if [[ "${1:-}" == clone ]]; then
    local n=1
    while :; do
      command git "$@" && return 0
      if [[ "${n}" -ge 4 ]]; then echo "ERROR: git clone failed after ${n} attempts: $*" >&2; return 1; fi
      echo "  git clone failed (attempt ${n}/4) — retrying in 5s..." >&2
      sleep 5; n=$((n+1))
    done
  fi
  command git "$@"
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
