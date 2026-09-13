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
#
# Deliberately NO --retry-delay. Per curl(1) it "changes the default backoff time algorithm",
# i.e. passing it REPLACES curl's built-in exponential backoff with a fixed wait. The old
# --retry-delay 3 therefore capped five attempts at ~15s total, which cannot outlast even a
# brief DNS or CDN outage. Omitting it restores curl's doubling backoff (1s, 2s, 4s, …), and
# --retry-max-time bounds the whole thing so a genuinely dead host still fails in reasonable
# time instead of retrying for as long as curl's cap allows.
curl() {
  command curl --retry 8 --retry-connrefused --retry-max-time 300 "$@"
}

# ── git wrapper: retry clones on transient network failures ───────────────
# Dependency source clones intermittently fail when the remote returns an HTML error
# page instead of the git protocol ("could not determine hash algorithm", "bad line
# length character: <!do…") — a transient blip, not a real error. Retry a few times so
# one hiccup doesn't fail the whole build/CI run. git clone removes its target directory
# on failure, so a plain re-clone is safe. Falls through to real git for everything else.
# Backoff is EXPONENTIAL with jitter, not a fixed delay. The previous 4 attempts x 5s covered a
# ~15s window, so a runner DNS outage took the whole job down despite "retrying":
#   fatal: unable to access 'https://github.com/libass/libass.git/': Could not resolve host
#   ERROR: git clone failed after 4 attempts
# all four inside 15 seconds. 6 attempts doubling from 4s span ~2 minutes, which covers the
# blips actually seen in CI. Jitter keeps a 60-cell matrix from retrying in lockstep and
# hammering the remote at the same instants — the thundering herd is itself a failure cause.
GIT_CLONE_ATTEMPTS="${GIT_CLONE_ATTEMPTS:-6}"
git() {
  if [[ "${1:-}" == clone ]]; then
    local n=1 delay=4
    while :; do
      command git "$@" && return 0
      if [[ "${n}" -ge "${GIT_CLONE_ATTEMPTS}" ]]; then
        echo "ERROR: git clone failed after ${n} attempts: $*" >&2; return 1
      fi
      local wait=$(( delay + (RANDOM % 5) ))
      echo "  git clone failed (attempt ${n}/${GIT_CLONE_ATTEMPTS}) — retrying in ${wait}s..." >&2
      sleep "${wait}"
      delay=$(( delay * 2 )); n=$(( n + 1 ))
    done
  fi
  command git "$@"
}

# ── Helper: build a CMake-based static dependency ─────────────────────────

build_cmake_dep() {
  local name="$1"; shift
  echo "Building ${name} (static)..."
  cd "${WORK_DIR}" || return 1
  rm -rf "${name}"
  clone_dep "${name}" "${WORK_DIR}/${name}"
  cd "${name}" || return 1
  # Build in "_build", not "build": some sources ship a case-insensitively-colliding entry
  # (google/highway has a Bazel `BUILD` file) that clashes with a `build` dir on macOS/iOS's
  # case-insensitive filesystem — cmake then fails ("Unable to (re)create ... pkgRedirects").
  # "_build" avoids that, and also never reuses a `build/` dir a project might vendor.
  cmake -B _build \
    -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${DEPS_DIR}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
    "$@"
  cmake --build _build -j"$(${NPROC})"
  cmake --install _build
}
