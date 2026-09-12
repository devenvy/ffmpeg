#!/usr/bin/env bash
set -euo pipefail
# MoltenVK — Vulkan-over-Metal ICD/driver (Apache-2.0). Apple has no native Vulkan, so this is
# what makes FFmpeg's --enable-vulkan GPU filters (scale_vulkan, gblur_vulkan, …) run on Metal —
# there is no Metal equivalent in FFmpeg's filtergraph. Built for BOTH macOS and iOS (v3 only —
# Apache-2.0 is cleared for the v2 App-Store cells by 04_select_license), but consumed
# DIFFERENTLY: macOS ships the dylib and reaches it through the Khronos Vulkan-Loader + ICD
# (vulkan-loader.sh); we do not build that loader for iOS here — vulkan-loader.sh supplies no
# iOS CMake toolchain, so it is macOS-only in this repo (upstream does support iOS) — so
# MoltenVK is linked statically into the libav* frameworks via --enable-vulkan-static instead.
# SOURCED by scripts/build.sh. Not standalone.
#
# NOTE: MoltenVK does not reliably publish prebuilt binaries per release, so we build it from
# source on the macOS runner (Xcode present). fetchDependencies + `make` output paths have
# shifted across versions, so the built dylib/framework is located by name, not a fixed path.

case "${RID}" in osx-*|ios-*|maccatalyst-*) : ;; *) return 0 ;; esac
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
  # MoltenVK spells Catalyst "maccat", not "maccatalyst" -- the name is shared by
  # fetchDependencies' --<target> flag and the Makefile target, both verified against
  # v1.4.2 (fetchDependencies rejected --maccatalyst with "Unsupported option").
  maccatalyst-*) MVK_TARGET=maccat ;;
esac
./fetchDependencies "--${MVK_TARGET}"
make "${MVK_TARGET}"

# Locate the built MoltenVK binary. Packaging differs by platform AND by how we consume it:
#   macOS — the DYNAMIC libMoltenVK.dylib, bundled beside the libav* dylibs and reached
#           through the Khronos loader + MoltenVK_icd.json (see 08_stage_artifacts).
#   iOS   — the STATIC libMoltenVK.a, linked INTO the libav* frameworks. We don't build the
#           Khronos loader for iOS here (vulkan-loader.sh has no iOS toolchain; see below),
#           and FFmpeg's dlopen fallback only tries the leaf names libvulkan.dylib /
#           libvulkan.1.dylib / libMoltenVK.dylib, none of which resolves from inside an app
#           bundle. Static linking removes the lookup.
# Search prefers the platform-matching slice, then falls back to any match.
# macOS wants the DYNAMIC binary (loader + ICD path), so a framework-shaped slice is an
# acceptable match here.
find_mvk_dynamic() { # <path-hint>...
  local p hit
  for p in "$@"; do
    hit="$(find Package -path "*${p}*" \( -name 'libMoltenVK.dylib' -o -path "*MoltenVK.framework/MoltenVK" \) -type f 2>/dev/null | head -1)"
    [ -n "${hit}" ] && { echo "${hit}"; return 0; }
  done
  find Package \( -name 'libMoltenVK.dylib' -o -path "*MoltenVK.framework/MoltenVK" \) -type f 2>/dev/null | head -1
}

# iOS wants the STATIC archive, and must never match a framework binary. MoltenVK's Package
# tree carries both flavours for the same slice —
#   Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/<slice>/MoltenVK.framework/MoltenVK
#   Package/Release/MoltenVK/static/MoltenVK.xcframework/<slice>/libMoltenVK.a
# — and "dynamic" sorts before "static", so a find that accepts either returns the DYLIB.
# That is exactly what happened: the archive assertion below caught a Mach-O shared library.
# Match on the archive name only, preferring the static/ subtree.
find_mvk_static() { # <path-hint>...
  local p hit
  for p in "$@"; do
    hit="$(find Package -path "*static*" -path "*${p}*" -name 'libMoltenVK.a' -type f 2>/dev/null | head -1)"
    [ -n "${hit}" ] && { echo "${hit}"; return 0; }
  done
  find Package -name 'libMoltenVK.a' -type f 2>/dev/null | head -1
}
case "${RID}" in
  osx-*)         MVK_LIB="$(find_mvk_dynamic macos macOS)" ;;
  ios-arm64)     MVK_LIB="$(find_mvk_static ios-arm64 iOS)" ;;
  ios-sim-arm64) MVK_LIB="$(find_mvk_static simulator iossim iOS_Simulator)" ;;
  # Catalyst links MoltenVK STATICALLY like iOS, so each .framework stays self-contained
  # inside the xcframework. Several path spellings are tried because MoltenVK's Package
  # layout for macabi is not stable across releases; a miss hard-errors below with the
  # tree printed, rather than silently disabling Vulkan.
  maccatalyst-*) MVK_LIB="$(find_mvk_static maccat maccatalyst Mac_Catalyst catalyst macabi)" ;;
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
  ios-*|maccatalyst-*)
    # Catalyst takes the iOS path, not the osx-* one: find_mvk_static resolved a static archive
    # for it above, BUILD_VULKAN_LOADER is off, and 08_stage_artifacts ships frameworks rather
    # than a flat dylib layout. Omitting it here left MVK_LIB resolved but never installed, so
    # libvulkan.a never appeared and configure's --enable-vulkan-static check_lib could not
    # succeed on any v3 Catalyst cell.
    cp "${MVK_LIB}" "${DEPS_DIR}/lib/libMoltenVK.a"
    # Guard the whole premise of --enable-vulkan-static: if MoltenVK's packaging shifts
    # and we picked up a dylib, FFmpeg's static link test would fail late and confusingly
    # (or worse, silently disable Vulkan). Fail here, where the cause is obvious.
    if ! file -b "${DEPS_DIR}/lib/libMoltenVK.a" | grep -qiE 'archive|current ar archive'; then
      echo "ERROR: expected a static archive for ${RID}, got: $(file -b "${DEPS_DIR}/lib/libMoltenVK.a")" >&2
      echo "  (MoltenVK static packaging moved; look for libMoltenVK.a under Package/)" >&2
      exit 1
    fi
    # FFmpeg resolves --enable-vulkan-static ONLY via
    #   check_lib vulkan "vulkan/vulkan.h" vkGetInstanceProcAddr -lvulkan
    # so the linker must find a library literally named vulkan. iOS builds no Khronos
    # loader (BUILD_VULKAN_LOADER is macOS-only), so nothing else provides that name —
    # expose the MoltenVK archive under it. Same bytes, second name.
    cp "${DEPS_DIR}/lib/libMoltenVK.a" "${DEPS_DIR}/lib/libvulkan.a"
    ;;
esac

case "${RID}" in
  osx-*)
    # macOS keeps the Khronos-loader + ICD mechanism: the loader dlopens the driver named
    # by MoltenVK_icd.json. 08_stage_artifacts bundles both beside the dylibs.
    MVK_ICD="$(find Package -name 'MoltenVK_icd.json' 2>/dev/null | head -1)"
    [ -n "${MVK_ICD}" ] && cp "${MVK_ICD}" "${DEPS_DIR}/lib/MoltenVK_icd.json"
    # Must stay LAST and unconditional: this file is sourced by 06_build_libraries.sh under
    # `set -euo pipefail`, so ending the arm on the AND-list above would return 1 whenever
    # MVK_ICD is empty and abort the entire build with no message.
    echo "MoltenVK staged for ${RID} — bundled by 08_stage_artifacts."
    ;;
  ios-*|maccatalyst-*)
    # How this actually resolves: configure takes --enable-vulkan-static through
    #   check_lib vulkan "vulkan/vulkan.h" vkGetInstanceProcAddr -lvulkan
    # and NEVER reads vulkan.pc's Libs: line for it (the check_pkg_config branch above that
    # line in FFmpeg's configure passes a "defined VK_VERSION_1_3" cpp condition into the
    # funcs slot, which cannot compile — so that branch always fails). So: the archive is
    # exposed as libvulkan.a above, and the libraries MoltenVK itself calls into go through
    # --extra-libs, which configure appends to the link line of that very check_lib test.
    # Consumers of the resulting libav* frameworks must link the same system frameworks
    # (see the iOS docs). UIKit is required too: MoltenVK's surface code (MVKSurface.mm)
    # imports UIKit/UIView.h, and MoltenVK's project sets CLANG_ENABLE_MODULES=NO, so there
    # is no autolinking to supply it — omitting it fails the check_lib probe below, or at
    # latest the final libavutil link, on unresolved UIKit/UIView symbols.
    EXTRA_LIBS="${EXTRA_LIBS:-} -lc++ -framework Metal -framework IOSurface -framework Foundation -framework QuartzCore -framework CoreGraphics -framework UIKit"
    # shellcheck disable=SC2034  # appended here; consumed by steps/07_build_ffmpeg.sh
    CONFIGURE_FLAGS+=(--enable-vulkan-static)
    echo "MoltenVK linked STATICALLY for ${RID} (--enable-vulkan-static; no loader, no ICD)."
    ;;
esac
