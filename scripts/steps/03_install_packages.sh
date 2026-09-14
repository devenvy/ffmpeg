#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 3: Install Host Packages
#
# Install the build toolchain and packages this RID needs — apt on
# Debian/Ubuntu, apk in the Alpine/musl container, brew on macOS.
# Skipped entirely when SKIP_DEPS=true.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── Install dependencies ─────────────────────────────────────────────────

if [[ "${SKIP_DEPS:-false}" != "true" ]]; then
# Some RIDs build inside a container (linux-armhf in debian:bookworm, musl in alpine)
# where the user is root and `sudo` is not installed, while the bare runners are non-root
# and need it. Resolve once instead of assuming either.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

case "${RID}" in
  osx-*|ios-*|maccatalyst-*)
    # autoconf/automake/libtool provide `autoreconf`, which several deps' autogen.sh
    # needs (kvazaar, libogg, libvorbis, zimg — cloned from git with no pre-generated
    # configure). GitHub's macOS runners no longer ship them, so install explicitly.
    # shaderc provides glslc, which FFmpeg's configure probes for spirv_compiler -- without it
    # every Vulkan FILTER is silently dropped while --enable-vulkan still appears in the configure
    # string (measured: the published ios-arm64 and maccatalyst slices have zero of them).
    # Homebrew's shaderc is current, so this is the fast path; the capability probe further down
    # still verifies it and falls back to building the pinned shaderc from source, which needs
    # ninja. Both are listed so neither path depends on what the runner image happens to ship.
    for pkg in autoconf automake libtool cmake gperf meson nasm ninja pkg-config shaderc yasm jq; do
      brew list "$pkg" &>/dev/null || brew install "$pkg"
    done
    ;;
  linux-musl-*)
    apk add --no-cache "${PKGS_APK[@]}" jq
    ;;
  linux-x64|linux-arm64)
    if [[ "${BUILD_CONTAINER:-}" == "manylinux" ]]; then
      # Running inside the STOCK upstream manylinux_2_28 image (AlmaLinux 8, glibc
      # 2.28, gcc-toolset-14) for a low runtime glibc floor. It is a bare build image,
      # so provision the toolchain here with dnf (no custom image to maintain — the
      # base is pulled unmodified from quay.io/pypa). Sourced script, so the toolset
      # env below persists into the later build steps.
      source /opt/rh/gcc-toolset-14/enable
      # vim-common supplies xxd. libvmaf's meson treats xxd as `required: false` and generates
      # its built-in model sources only inside `if xxd.found()`, with no failure branch -- so
      # without it VMAF_BUILT_IN_MODELS is never defined, the model table holds only its
      # sentinel, and every lookup returns -EINVAL. The libvmaf FILTER still registers, so
      # nothing looks wrong, but FFmpeg's default version=vmaf_v0.6.1 cannot load and the filter
      # is unusable. libvmaf.sh passes -Dbuilt_in_models=true and its header promises exactly
      # that, so this was a silent broken promise on the manylinux RIDs.
      DNF_PKGS="nasm ninja-build cmake git pkgconfig autoconf automake libtool \
                perl gperf xz curl make diffutils gcc-c++ jq vim-common"
      dnf -y install --setopt=install_weak_deps=False ${DNF_PKGS} >/dev/null 2>&1 \
        || dnf -y install ${DNF_PKGS}
      # meson: the system python is 3.6 (pip caps at meson 0.61) and dnf's meson is
      # 0.58 — both below libdrm's >= 0.59 floor. Install a current meson from one of
      # manylinux's bundled CPythons.
      PYBIN="$(ls -d /opt/python/cp312-cp312/bin 2>/dev/null \
               || ls -d /opt/python/cp311-cp311/bin 2>/dev/null | head -1)"
      "${PYBIN}/pip" install --quiet --upgrade meson ninja
      ln -sf "${PYBIN}/meson" /usr/local/bin/meson
      ln -sf "${PYBIN}/ninja" /usr/local/bin/ninja
      # patchelf 0.18: AlmaLinux 8's dnf and pip ship 0.17.2, which corrupts
      # gcc-toolset PIE executables (CET/GNU_PROPERTY notes) on --set-rpath $ORIGIN
      # -> the staged ffmpeg segfaults in the loader. Install the static 0.18 binary.
      PATCHELF_VER="$(dep_version patchelf)"   # pinned in deps.json so Renovate tracks it
      PE_ARCH="$(uname -m)"   # x86_64 / aarch64 — matches the patchelf asset names
      curl -fsSL -o /tmp/pe.tgz \
        "https://github.com/NixOS/patchelf/releases/download/${PATCHELF_VER}/patchelf-${PATCHELF_VER}-${PE_ARCH}.tar.gz"
      tar xf /tmp/pe.tgz -C /tmp
      install -m755 /tmp/bin/patchelf /usr/local/bin/patchelf
      # glslc (Vulkan shader compiler) from shaderc — AlmaLinux 8 has no package, and
      # FFmpeg's Vulkan filters + whisper's GPU shaders need it at build time.
      # "Is glslc present" is the WRONG question -- it has to be new enough. FFmpeg 8.1+ and 9.x
      # probe the shader compiler with:
      #     glslc --target-env=vulkan1.4 --target-spv=spv1.6 -std=460
      # and Ubuntu noble ships shaderc 2023.8, which predates Vulkan 1.4 and rejects it outright:
      #     glslc: error: invalid value 'vulkan1.4' in '--target-env=vulkan1.4'
      # configure then disables spirv_compiler and silently drops EVERY Vulkan filter --
      # scale_vulkan, gblur_vulkan, xfade_vulkan and the rest. Nothing fails; the filters simply
      # are not in the build. Confirmed in the published 9.0.1.6 and 8.1.2.6 win-x64 artifacts:
      #     strings avfilter-*.dll | grep -c scale_vulkan   ->  0
      # while libavcodec/vulkan_*.o WERE compiled, so it looked like Vulkan was working.
      #
      # The old `command -v glslc` guard was therefore actively harmful: the distro package that
      # satisfied it is precisely the one that cannot do the job, and its presence made us SKIP
      # building the pinned shaderc glslc that can. Probe capability, not presence.
    else
      # Building on a normal glibc host (e.g. local Ubuntu) — use apt like the others.
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y --no-install-recommends "${PKGS[@]}" jq
      # meson >= 1.11 for fontconfig 2.18+ (apt meson is older) — see the note in *) below.
      ${SUDO} python3 -m pip install --break-system-packages --upgrade meson ninja \
        || ${SUDO} python3 -m pip install --upgrade meson ninja
    fi
    ;;
  *)
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y --no-install-recommends "${PKGS[@]}" jq
    # fontconfig 2.18+ (and other newer Meson projects) require meson >= 1.11; the distro's
    # apt meson is older (Ubuntu 24.04 ships 1.3.2). Pull a current meson/ninja from PyPI —
    # same approach the manylinux path uses. PEP-668 marks the system env externally-managed
    # on newer Ubuntu, so allow the override, with a plain-pip fallback for older hosts.
    ${SUDO} python3 -m pip install --break-system-packages --upgrade meson ninja \
      || ${SUDO} python3 -m pip install --upgrade meson ninja
    # Windows-on-ARM needs LLVM-MinGW: Debian/Ubuntu's mingw-w64 packages provide only the
    # x86 targets (i686/x86_64-w64-mingw32) and no aarch64-w64-mingw32 at all, so win-arm64
    # cannot be built from the distro toolchain. llvm-mingw ships prebuilt cross toolchains
    # for every Windows arch. UCRT rather than msvcrt because Windows-on-ARM is Windows 10+,
    # where UCRT is the system C runtime. Pinned like the patchelf download above: a toolchain
    # bump should be a deliberate commit, not whatever is latest on the day CI happens to run.
    if [[ "${RID}" == "win-arm64" ]]; then
      # Pinned in deps.json so Renovate/check-updates track it like every other
      # dependency; a toolchain bump arrives as a reviewable PR, not a silent drift.
      LLVM_MINGW_VER="$(dep_version llvm-mingw)"
      LLVM_MINGW="llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-x86_64"
      echo "Fetching ${LLVM_MINGW} (aarch64-w64-mingw32 cross toolchain)..."
      curl -fsSL -o /tmp/llvm-mingw.tar.xz \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/${LLVM_MINGW}.tar.xz"
      ${SUDO} tar -xf /tmp/llvm-mingw.tar.xz -C /opt
      rm -f /tmp/llvm-mingw.tar.xz
      # 03 is SOURCED by build.sh, so exporting PATH here reaches every later step — which is
      # what makes ${CROSS_PREFIX}-clang resolvable in platform/windows.sh and the dep scripts.
      export PATH="/opt/${LLVM_MINGW}/bin:${PATH}"
      command -v aarch64-w64-mingw32-clang >/dev/null 2>&1 \
        || { echo "ERROR: llvm-mingw unpacked but aarch64-w64-mingw32-clang is not on PATH" >&2; exit 1; }
      echo "llvm-mingw ready: $(aarch64-w64-mingw32-clang --version | head -1)"
    fi
    ;;
esac

  # glslc is needed by EVERY RID that enables Vulkan, not just the manylinux ones. It lived
  # inside the linux-x64/arm64 manylinux branch, so armhf (debian), Windows and Android (both
  # cross-built on the Ubuntu runner) never reached it -- and those hosts DO have a distro
  # glslc, just one too old for FFmpeg's --target-env=vulkan1.4 probe. Result: those four RIDs
  # shipped with every Vulkan filter silently missing, while the manylinux and Alpine RIDs
  # (which build or package a new enough glslc) had them. Measured in the published 9.0.1.6
  # artifacts: linux-x64 9, linux-arm64 11, musl 9/11 -- armhf, win-x64, win-arm64 and
  # android-arm64 all 0. Hoisted here so the check is per-capability, not per-platform.
  if [[ "${BUILD_VULKAN:-0}" == "1" ]]; then
  _glslc_supports_target_env() {
    command -v glslc >/dev/null 2>&1 || return 1
    local d rc=0
    d="$(mktemp -d)"
    printf '#version 460\nlayout (local_size_x = 1) in;\nvoid main() {}\n' > "${d}/probe.comp"
    glslc --target-env=vulkan1.4 --target-spv=spv1.6 -std=460 -fshader-stage=compute \
          "${d}/probe.comp" -o "${d}/probe.spv" >/dev/null 2>&1 || rc=1
    rm -rf "${d}"
    return "${rc}"
  }
  if ! _glslc_supports_target_env; then
    echo "glslc missing or too old for --target-env=vulkan1.4; building the pinned shaderc." >&2
    # Build glslc from the SAME shaderc tag the ledger pins (deps.json .defaults.shaderc,
    # which Renovate tracks) via dep_version — so this build-tool copy can't drift from the
    # shaderc dep and gets version bumps automatically. An unpinned clone tracked shaderc
    # master, and git-sync-deps pulled glslang/SPIRV-Tools HEAD — non-deterministic: a
    # glslang change made spirv-opt emit LocalSizeId execution mode, which whisper's
    # ggml-vulkan shaders (compiled --target-env=vulkan1.2) reject ("LocalSizeId mode is not
    # allowed by the current environment"), breaking the build whenever master moved.
    SHADERC_TAG="$(dep_version shaderc)"
    git clone --depth 1 --branch "${SHADERC_TAG}" https://github.com/google/shaderc /tmp/shaderc
    # git-sync-deps is a PYTHON child process, so the retrying git() wrapper in
    # scripts/lib.sh cannot reach it -- shell functions are not exported to child
    # processes. It clones glslang/SPIRV-Tools/SPIRV-Headers over the network, so it has
    # the same exposure to a DNS or TLS blip as any other clone and had no protection at
    # all. Retry the whole invocation with the same jittered exponential backoff.
    _sync_delay=4
    for _sync_try in 1 2 3 4 5 6; do
      ( cd /tmp/shaderc && ./utils/git-sync-deps ) && break
      if [ "${_sync_try}" -eq 6 ]; then
        echo "ERROR: shaderc git-sync-deps failed after ${_sync_try} attempts" >&2
        exit 1
      fi
      _sync_wait=$(( _sync_delay + (RANDOM % 5) ))
      echo "  git-sync-deps failed (attempt ${_sync_try}/6) - retrying in ${_sync_wait}s..." >&2
      sleep "${_sync_wait}"
      _sync_delay=$(( _sync_delay * 2 ))
    done
    # glslc is a BUILD-HOST tool: FFmpeg's configure executes it ON THE RUNNER to compile
    # shaders. But 02_configure.sh has already exported the TARGET cross toolchain by this point
    # -- CC=x86_64-w64-mingw32-gcc-win32 for win-x64, the NDK clang for Android, an -isysroot
    # CFLAGS for the Apple targets -- and CMake reads all of that from the environment. So this
    # was configuring a WINDOWS build of glslc on a Linux runner, and died at generate time:
    #     Unable to determine default CMAKE_INSTALL_LIBDIR ... no target architecture is known
    #     The install of the spirv-as target requires changing an RPATH from the build tree,
    #     but this is not supported with the Ninja generator unless on an ELF-based ... platform
    # Had it generated, it would have produced a glslc.exe that cannot run on the runner at all,
    # which is a worse failure: the capability probe would reject it and the build would stop
    # with a confusing message. Cross variables are cleared in a subshell so the export list
    # above is untouched for the real (target) build that follows. CC/CXX are unset rather than
    # forced, letting CMake pick the platform's default host compiler -- which is what this
    # block did when it lived inside the manylinux branch and worked.
    (
      unset CC CXX AR RANLIB LD NM STRIP OBJDUMP RC WINDRES \
            CFLAGS CXXFLAGS CPPFLAGS LDFLAGS \
            PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
            CMAKE_TOOLCHAIN_FILE SDKROOT
      cmake -S /tmp/shaderc -B /tmp/shaderc/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local
      # ${NPROC}, not bare `nproc`: this block runs for EVERY Vulkan RID now, Apple included,
      # and macOS has no nproc -- 02_configure.sh sets NPROC=nproc, apple.sh sets
      # NPROC="sysctl -n hw.ncpu".
      cmake --build /tmp/shaderc/build --target glslc_exe -j"$(${NPROC:-nproc})"
    )
    ${SUDO} install -m755 /tmp/shaderc/build/glslc/glslc /usr/local/bin/glslc
    hash -r   # drop the shell's cached path to the old /usr/bin/glslc
    # Building it is not the same as USING it: /usr/local/bin must win over the distro copy.
    # If it does not, configure still probes the old glslc and still silently drops every
    # Vulkan filter -- the exact failure this replaces.
    if ! _glslc_supports_target_env; then
      echo "ERROR: built the pinned glslc but the capability probe still fails." >&2
      echo "  which glslc: $(command -v glslc)" >&2
      echo "  version:     $(glslc --version 2>&1 | head -1)" >&2
      exit 1
    fi
    echo "glslc supports --target-env=vulkan1.4: $(glslc --version 2>&1 | head -1)"
  fi
  fi
else
  echo "Skipping dependency installation (SKIP_DEPS=true)."
fi
