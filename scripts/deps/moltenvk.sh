#!/usr/bin/env bash
set -euo pipefail
# MoltenVK — Vulkan-over-Metal ICD/driver (Apache-2.0). Apple has no native Vulkan, so this is
# what makes FFmpeg's --enable-vulkan GPU filters (scale_vulkan, gblur_vulkan, …) run on Metal —
# there is no Metal equivalent in FFmpeg's filtergraph. Built for BOTH macOS and iOS (v3 only —
# Apache-2.0 is cleared for the v2 App-Store cells by 04_select_license), but consumed
# DIFFERENTLY: macOS ships the dylib and reaches it through the Khronos Vulkan-Loader + ICD
# (vulkan-loader.sh); iOS has no loader for its SDK, so MoltenVK is linked statically into the
# libav* frameworks via --enable-vulkan-static. SOURCED by scripts/build.sh. Not standalone.
#
# NOTE: MoltenVK does not reliably publish prebuilt binaries per release, so we build it from
# source on the macOS runner (Xcode present). fetchDependencies + `make` output paths have
# shifted across versions, so the built dylib/framework is located by name, not a fixed path.

case "${RID}" in osx-*|ios-*) : ;; *) return 0 ;; esac
[[ "${BUILD_VULKAN}" == "1" ]] || return 0

echo "Building MoltenVK (Vulkan-over-Metal) for ${RID}..."
cd "${WORK_DIR}" || exit 1
rm -rf MoltenVK
clone_dep moltenvk "${WORK_DIR}/MoltenVK"
cd MoltenVK || exit 1

# Which MoltenVK make target to build for this RID.
case "${RID}" in
  osx-*)         MVK_TARGET=macos  ;;
  ios-arm64)     MVK_TARGET=ios    ;;
  ios-sim-arm64) MVK_TARGET=iossim ;;
esac
./fetchDependencies "--${MVK_TARGET}"
make "${MVK_TARGET}"

# Locate the built MoltenVK binary. Packaging differs by platform AND by how we consume it:
#   macOS — the DYNAMIC libMoltenVK.dylib, bundled beside the libav* dylibs and reached
#           through the Khronos loader + MoltenVK_icd.json (see 08_stage_artifacts).
#   iOS   — the STATIC libMoltenVK.a, linked INTO the libav* frameworks. There is no
#           Khronos loader for the iOS SDK, and FFmpeg's dlopen fallback only tries the
#           leaf names libvulkan.dylib / libvulkan.1.dylib / libMoltenVK.dylib, none of
#           which resolves from inside an app bundle. Static linking removes the lookup.
# Search prefers the platform-matching slice, then falls back to any match.
find_mvk() { # <name-pattern> <path-hint>...
  local pat="$1"; shift
  local p hit
  for p in "$@"; do
    hit="$(find Package -path "*${p}*" \( -name "${pat}" -o -path "*MoltenVK.framework/MoltenVK" \) -type f 2>/dev/null | head -1)"
    [ -n "${hit}" ] && { echo "${hit}"; return 0; }
  done
  find Package \( -name "${pat}" -o -path "*MoltenVK.framework/MoltenVK" \) -type f 2>/dev/null | head -1
}
case "${RID}" in
  osx-*)         MVK_LIB="$(find_mvk 'libMoltenVK.dylib' macos macOS)" ;;
  ios-arm64)     MVK_LIB="$(find_mvk 'libMoltenVK.a' ios-arm64 iOS)" ;;
  ios-sim-arm64) MVK_LIB="$(find_mvk 'libMoltenVK.a' simulator iossim iOS_Simulator)" ;;
esac
[ -n "${MVK_LIB}" ] && [ -e "${MVK_LIB}" ] \
  || { echo "ERROR: MoltenVK binary (libMoltenVK.dylib or MoltenVK.framework/MoltenVK) not found after build (${RID})" >&2
       echo "  Package tree:" >&2; find Package -name 'libMoltenVK*' -o -name 'MoltenVK' 2>/dev/null | head -20 >&2
       exit 1; }
case "${RID}" in
  osx-*)
    cp "${MVK_LIB}" "${DEPS_DIR}/lib/libMoltenVK.dylib"
    # The copied Mach-O keeps its original install-name; 08 resets it when it bundles.
    ;;
  ios-*)
    cp "${MVK_LIB}" "${DEPS_DIR}/lib/libMoltenVK.a"
    # Guard the whole premise of --enable-vulkan-static: if MoltenVK's packaging shifts
    # and we picked up a dylib, FFmpeg's static link test would fail late and confusingly
    # (or worse, silently disable Vulkan). Fail here, where the cause is obvious.
    if ! file -b "${DEPS_DIR}/lib/libMoltenVK.a" | grep -qiE 'archive|current ar archive'; then
      echo "ERROR: expected a static archive for ${RID}, got: $(file -b "${DEPS_DIR}/lib/libMoltenVK.a")" >&2
      echo "  (MoltenVK static packaging moved; look for libMoltenVK.a under Package/)" >&2
      exit 1
    fi
    ;;
esac

case "${RID}" in
  osx-*)
    # macOS keeps the Khronos-loader + ICD mechanism: the loader dlopens the driver named
    # by MoltenVK_icd.json. 08_stage_artifacts bundles both beside the dylibs.
    MVK_ICD="$(find Package -name 'MoltenVK_icd.json' 2>/dev/null | head -1)"
    [ -n "${MVK_ICD}" ] && cp "${MVK_ICD}" "${DEPS_DIR}/lib/MoltenVK_icd.json"
    ;;
  ios-*)
    # vulkan-headers.sh (sourced BEFORE this script by 06_build_libraries.sh) writes a
    # header-only vulkan.pc. --enable-vulkan-static needs it to actually link, so append
    # the archive plus the Apple frameworks MoltenVK itself calls into. Consumers of the
    # resulting libav* frameworks must link the same system frameworks (see the iOS docs).
    cat >> "${DEPS_DIR}/lib/pkgconfig/vulkan.pc" <<PKGCONFIG
Libs: -L\${prefix}/lib -lMoltenVK -lc++ -framework Metal -framework IOSurface -framework Foundation -framework QuartzCore -framework CoreGraphics
PKGCONFIG
    # shellcheck disable=SC2034  # appended here; consumed by steps/07_build_ffmpeg.sh
    CONFIGURE_FLAGS+=(--enable-vulkan-static)
    echo "MoltenVK linked STATICALLY for ${RID} (--enable-vulkan-static; no loader, no ICD)."
    ;;
esac
