#!/usr/bin/env bash
set -euo pipefail
# MoltenVK — Vulkan-over-Metal ICD/driver (Apache-2.0). Apple has no native Vulkan, so this is
# what makes FFmpeg's --enable-vulkan GPU filters (scale_vulkan, gblur_vulkan, …) run on Metal —
# there is no Metal equivalent in FFmpeg's filtergraph. Built for BOTH macOS and iOS (v3 only —
# Apache-2.0 is cleared for the v2 App-Store cells by 04_select_license). Pairs with the
# Vulkan-Loader from vulkan.sh. SOURCED by scripts/build.sh. Not standalone.
#
# NOTE: MoltenVK does not reliably publish prebuilt binaries per release, so we build it from
# source on the macOS runner (Xcode present). fetchDependencies + `make` output paths have
# shifted across versions, so the built dylib/framework is located by name, not a fixed path.

case "${RID}" in osx-*|ios-*) : ;; *) return 0 ;; esac
[[ "${BUILD_VULKAN}" == "1" ]] || return 0

MOLTENVK_VER=v1.2.11
echo "Building MoltenVK ${MOLTENVK_VER} (Vulkan-over-Metal) for ${RID}..."
cd "${WORK_DIR}" || exit 1
rm -rf MoltenVK
git clone --depth 1 --branch "${MOLTENVK_VER}" https://github.com/KhronosGroup/MoltenVK.git
cd MoltenVK || exit 1

# Which platform slice to build + which MoltenVK make target / SDK subdir it lands in.
case "${RID}" in
  osx-*)         MVK_TARGET=macos;  MVK_PLAT=macOS ;;
  ios-arm64)     MVK_TARGET=ios;    MVK_PLAT=iOS ;;
  ios-sim-arm64) MVK_TARGET=iossim; MVK_PLAT=iOS_Simulator ;;
esac
./fetchDependencies "--${MVK_TARGET}"
make "${MVK_TARGET}"

# libMoltenVK.dylib for the target platform + the ICD json (macOS uses the loader+ICD; the
# iOS slices are bundled as a framework by 08 and loaded directly).
MVK_LIB="$(find Package -path "*${MVK_PLAT}*" -name 'libMoltenVK.dylib' 2>/dev/null | head -1)"
[ -n "${MVK_LIB}" ] || MVK_LIB="$(find Package -name 'libMoltenVK.dylib' 2>/dev/null | head -1)"
[ -n "${MVK_LIB}" ] || { echo "ERROR: libMoltenVK.dylib not found after build (${RID})" >&2; exit 1; }
cp "${MVK_LIB}" "${DEPS_DIR}/lib/libMoltenVK.dylib"

MVK_ICD="$(find Package -name 'MoltenVK_icd.json' 2>/dev/null | head -1)"
[ -n "${MVK_ICD}" ] && cp "${MVK_ICD}" "${DEPS_DIR}/lib/MoltenVK_icd.json"
echo "MoltenVK staged for ${RID} — bundled by 08_stage_artifacts."
