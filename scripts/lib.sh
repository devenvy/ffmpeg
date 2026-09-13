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
# Dependency downloads hit resolution failures, timeouts, refused connections and retryable
# HTTP/FTP responses. Those retry flags are injected centrally here. Note the limits: this does
# NOT validate archive contents, and it does not make every transfer error retryable. A CDN that
# returns a garbage 200 body is a SUCCESSFUL transfer as far as curl is concerned — it is only
# caught later, by tar — so the wrapper cannot retry that case.
# For the scalar retry options (--retry, --retry-delay, --retry-max-time) curl uses the LAST
# value given, so an explicit override by a caller still wins. --retry-connrefused needs
# curl >= 7.52; the oldest image we build on (manylinux_2_28 = AlmaLinux 8) ships 7.61.1, so all
# three flags below are safe there. We do NOT add --retry-all-errors: it needs curl >= 7.71,
# which that image predates (the FFmpeg download step probes for it separately).
#
# Deliberately NO --retry-delay: a nonzero value replaces curl's exponential backoff with a
# fixed wait. The old wrapper used --retry 5 with five fixed 3s sleeps, and the nine dependency
# scripts overrode it with --retry 3 and three fixed 5s sleeps — roughly a 15s window either
# way, which cannot outlast even a brief DNS or CDN outage. Omitting it restores curl's own
# 1s, 2s, 4s, … doubling backoff (capped at 600s per wait).
#
# --retry-max-time 300 is NOT a hard wall-clock limit and does NOT abort an in-progress
# transfer: it only stops curl selecting a FURTHER retry once its retry timer passes 300s. A
# large tarball that legitimately takes longer than that still completes. Use --max-time if a
# per-transfer ceiling is ever wanted.
#
# --retry 8 means eight retries AFTER the initial attempt, i.e. nine attempts total.
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
# all four inside 15 seconds. Six attempts now add 124-144s of jittered retry SLEEP, plus
# however long the six git invocations themselves take — so this is a widened window, not a
# hard ceiling (no per-attempt git timeout is imposed). Jitter keeps a 52-cell-per-version
# matrix from retrying in lockstep and hammering the remote at the same instants; the
# thundering herd is itself a failure cause.
# GIT_CLONE_ATTEMPTS overrides the count. It must be a positive integer — it is used directly
# in an arithmetic test, so a non-numeric value is a caller error, not a supported input.
GIT_CLONE_ATTEMPTS="${GIT_CLONE_ATTEMPTS:-6}"
# Which subcommands get the retry: every one of ours that touches the network. `clone` was the
# only one covered before, which left scripts/deps/libplacebo.sh's `git submodule update` (it
# fetches the glad/jinja submodules) completely unprotected against the very outage this exists
# to survive. All four are safe to repeat: clone removes its target dir on failure, and fetch /
# submodule update / ls-remote are idempotent.
git() {
  case "${1:-}" in
    clone|fetch|submodule|ls-remote)
      local n=1 delay=4
      while :; do
        command git "$@" && return 0
        if [[ "${n}" -ge "${GIT_CLONE_ATTEMPTS}" ]]; then
          echo "ERROR: git $1 failed after ${n} attempts: $*" >&2; return 1
        fi
        local wait=$(( delay + (RANDOM % 5) ))
        echo "  git $1 failed (attempt ${n}/${GIT_CLONE_ATTEMPTS}) — retrying in ${wait}s..." >&2
        sleep "${wait}"
        delay=$(( delay * 2 )); n=$(( n + 1 ))
      done
      ;;
  esac
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
