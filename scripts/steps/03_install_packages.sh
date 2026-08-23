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
case "${RID}" in
  osx-*|ios-*)
    # autoconf/automake/libtool provide `autoreconf`, which several deps' autogen.sh
    # needs (kvazaar, libogg, libvorbis, zimg — cloned from git with no pre-generated
    # configure). GitHub's macOS runners no longer ship them, so install explicitly.
    for pkg in autoconf automake libtool cmake gperf meson nasm pkg-config yasm jq; do
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
      DNF_PKGS="nasm ninja-build cmake git pkgconfig autoconf automake libtool \
                perl gperf xz curl make diffutils gcc-c++ jq"
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
      PE_ARCH="$(uname -m)"   # x86_64 / aarch64 — matches the patchelf asset names
      curl -fsSL -o /tmp/pe.tgz \
        "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-${PE_ARCH}.tar.gz"
      tar xf /tmp/pe.tgz -C /tmp
      install -m755 /tmp/bin/patchelf /usr/local/bin/patchelf
      # glslc (Vulkan shader compiler) from shaderc — AlmaLinux 8 has no package, and
      # FFmpeg's Vulkan filters + whisper's GPU shaders need it at build time.
      if ! command -v glslc >/dev/null 2>&1; then
        git clone --depth 1 https://github.com/google/shaderc /tmp/shaderc
        ( cd /tmp/shaderc && ./utils/git-sync-deps )
        cmake -S /tmp/shaderc -B /tmp/shaderc/build -G Ninja \
          -DCMAKE_BUILD_TYPE=Release -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
          -DCMAKE_INSTALL_PREFIX=/usr/local
        cmake --build /tmp/shaderc/build --target glslc_exe -j"$(nproc)"
        install -m755 /tmp/shaderc/build/glslc/glslc /usr/local/bin/glslc
      fi
    else
      # Building on a normal glibc host (e.g. local Ubuntu) — use apt like the others.
      sudo apt-get update
      sudo apt-get install -y --no-install-recommends "${PKGS[@]}" jq
    fi
    ;;
  *)
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${PKGS[@]}" jq
    ;;
esac
else
  echo "Skipping dependency installation (SKIP_DEPS=true)."
fi
