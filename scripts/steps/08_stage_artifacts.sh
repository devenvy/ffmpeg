#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 8: Stage Artifacts
#
# Lay out the per-platform deliverable in artifacts/<rid>/native: copy
# binaries, libraries and headers, generate MSVC import libs on Windows,
# normalize Android sonames, and fix rpath/install_name for a relocatable
# flat layout.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── Output artifacts ──────────────────────────────────────────────────────

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

case "${RID}" in
  win-*)
    mkdir -p "${OUT_DIR}/include" "${OUT_DIR}/lib"
    cp -a "${PREFIX_DIR}/bin/"*.dll "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffmpeg.exe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffprobe.exe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    # Generate MSVC-consumable COFF import libraries (.lib) from each DLL so a
    # consumer with no FFmpeg build tooling can link with MSVC. gendef dumps the
    # DLL export table to a .def; llvm-dlltool turns it into a Microsoft short
    # import library (GNU dlltool's .dll.a is not reliably consumable by link.exe).
    # Named by base soname (avcodec.lib, not avcodec-62.lib) so MSVC/CMake find them.
    LLVM_DLLTOOL="$(command -v llvm-dlltool || ls /usr/lib/llvm-*/bin/llvm-dlltool 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "${LLVM_DLLTOOL}" ] || { echo "ERROR: llvm-dlltool not found (install the 'llvm' package)"; exit 1; }
    for dll in "${OUT_DIR}/"*.dll; do
      [ -e "${dll}" ] || continue
      dllbase="$(basename "${dll}")"   # e.g. avcodec-62.dll
      stem="${dllbase%.dll}"           # e.g. avcodec-62
      libbase="${stem%-*}"             # e.g. avcodec
      gendef - "${dll}" > "${WORK_DIR}/${stem}.def"
      "${LLVM_DLLTOOL}" -m i386:x86-64 \
        -d "${WORK_DIR}/${stem}.def" \
        -D "${dllbase}" \
        -l "${OUT_DIR}/lib/${libbase}.lib"
    done
    ;;
  osx-*)
    mkdir -p "${OUT_DIR}/include"
    cp -a "${PREFIX_DIR}/lib/"*.dylib "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffmpeg" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffprobe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    # Bundle the Vulkan-Loader + MoltenVK ICD (v3 only) so --enable-vulkan runs on Metal. The
    # @rpath install-names are set in the fixup pass below. Not fully self-contained at runtime:
    # the consumer points VK_ICD_FILENAMES at the bundled MoltenVK_icd.json (see the macOS
    # install doc). The ICD's library_path is rewritten relative so the folder can be relocated.
    if [[ "${BUILD_VULKAN:-0}" == "1" ]]; then
      cp -a "${DEPS_DIR}/lib/"libvulkan*.dylib  "${OUT_DIR}/" 2>/dev/null || true
      cp -a "${DEPS_DIR}/lib/libMoltenVK.dylib" "${OUT_DIR}/" 2>/dev/null || true
      cp -a "${DEPS_DIR}/lib/MoltenVK_icd.json" "${OUT_DIR}/" 2>/dev/null || true
      if [ -f "${OUT_DIR}/MoltenVK_icd.json" ]; then
        sed -i.bak 's|"library_path"[[:space:]]*:[[:space:]]*"[^"]*"|"library_path": "./libMoltenVK.dylib"|' \
          "${OUT_DIR}/MoltenVK_icd.json"
        rm -f "${OUT_DIR}/MoltenVK_icd.json.bak"
      fi
    fi
    ;;
  android-*)
    mkdir -p "${OUT_DIR}/include" "${OUT_DIR}/lib/${ANDROID_ABI}"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    # Install each shared lib under its UNVERSIONED name (Android requirement).
    for so in "${PREFIX_DIR}/lib/"*.so; do
      [ -e "${so}" ] || continue
      real="$(readlink -f "${so}")"
      base="$(basename "${so}")"   # e.g. libavcodec.so
      cp -a "${real}" "${OUT_DIR}/lib/${ANDROID_ABI}/${base}"
    done
    # Rewrite soname + inter-lib NEEDED to the unversioned names.
    pushd "${OUT_DIR}/lib/${ANDROID_ABI}" >/dev/null || exit 1
    for so in *.so; do
      patchelf --set-soname "${so}" "${so}"
    done
    for so in *.so; do
      for dep in *.so; do
        for n in $(patchelf --print-needed "${so}" | grep -E "^${dep}\.[0-9]+" || true); do
          patchelf --replace-needed "${n}" "${dep}" "${so}"
        done
      done
    done
    popd >/dev/null || exit 1
    # Bundle libc++_shared.so: the C++-based codec libraries (OpenH264, libass,
    # whisper.cpp) make libavcodec/libavfilter depend on it at RUNTIME, and it is
    # not part of Android itself — so the artifact must ship it or a consuming app
    # crashes on load with "library libc++_shared.so not found". (Verified by the
    # on-device smoke test.)
    LIBCXX="${TOOLCHAIN}/sysroot/usr/lib/${ANDROID_TRIPLE}/libc++_shared.so"
    if [ -f "${LIBCXX}" ]; then
      cp -a "${LIBCXX}" "${OUT_DIR}/lib/${ANDROID_ABI}/"
      echo "Bundled libc++_shared.so (runtime dependency of the C++ codec libs)."
    else
      echo "ERROR: libc++_shared.so not found at ${LIBCXX}" >&2
      exit 1
    fi
    ;;
  ios-*)
    # iOS ships one dynamic .framework per libav* library (release.yml assembles the device +
    # simulator frameworks into a per-lib .xcframework). Each framework bundles the dylib (deref'd
    # from its versioned symlink, renamed to the framework's executable name), that lib's public
    # Headers, and an Info.plist. The static dependencies (whisper/ggml, kvazaar, opus, …) are
    # linked INTO the dylibs, so each framework is self-contained. @rpath install-names make them
    # relocatable — Xcode embeds them under the app's Frameworks dir and supplies the runpath.
    # Cross-library header includes ("libavutil/…" from a libavcodec header) resolve at consume
    # time because the sibling frameworks are all on the framework search path.
    mkdir -p "${OUT_DIR}/frameworks"
    case "${RID}" in
      ios-arm64)     IOS_PLATFORM=iPhoneOS ;;
      ios-sim-arm64) IOS_PLATFORM=iPhoneSimulator ;;
    esac
    for base in avcodec avformat avutil avfilter swscale swresample; do
      src="${PREFIX_DIR}/lib/lib${base}.dylib"
      [ -e "${src}" ] || continue
      fw="lib${base}"
      fwdir="${OUT_DIR}/frameworks/${fw}.framework"
      mkdir -p "${fwdir}/Headers"
      cp "${src}" "${fwdir}/${fw}"                                    # deref symlink -> real dylib
      cp -a "${PREFIX_DIR}/include/lib${base}/." "${fwdir}/Headers/"  # this lib's public headers
      cat > "${fwdir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${fw}</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.${fw}</string>
  <key>CFBundleName</key><string>${fw}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION}</string>
  <key>CFBundleVersion</key><string>${FFMPEG_VERSION}</string>
  <key>MinimumOSVersion</key><string>13.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${IOS_PLATFORM}</string></array>
</dict>
</plist>
PLIST
    done
    # Rewrite each framework binary's id and its sibling references to the @rpath framework layout.
    for base in avcodec avformat avutil avfilter swscale swresample; do
      fw="lib${base}"; bin="${OUT_DIR}/frameworks/${fw}.framework/${fw}"
      [ -e "${bin}" ] || continue
      install_name_tool -id "@rpath/${fw}.framework/${fw}" "${bin}"
      otool -L "${bin}" | awk 'NR>1{print $1}' | while read -r ref; do
        b="$(basename "${ref}")"; stem="${b%%.*}"
        case "${stem}" in
          libav*|libsw*) install_name_tool -change "${ref}" "@rpath/${stem}.framework/${stem}" "${bin}" 2>/dev/null || true ;;
        esac
      done
    done
    # Vulkan (v3 only): wrap the Vulkan-Loader + MoltenVK ICD as frameworks so they ride in the
    # xcframework set (release.yml wraps every *.framework here). FFmpeg's --enable-vulkan resolves
    # them at runtime; the consumer points VK_ICD_FILENAMES at the bundled MoltenVK_icd.json (see
    # the iOS install doc). Same loader+ICD mechanism as macOS, for parity.
    if [[ "${BUILD_VULKAN:-0}" == "1" ]]; then
      case "${RID}" in ios-arm64) VKPLAT=iPhoneOS ;; ios-sim-arm64) VKPLAT=iPhoneSimulator ;; esac
      for pair in "vulkan:$(ls "${DEPS_DIR}/lib/"libvulkan*.dylib 2>/dev/null | head -1)" \
                   "MoltenVK:${DEPS_DIR}/lib/libMoltenVK.dylib"; do
        vkfw="${pair%%:*}"; vksrc="${pair#*:}"
        [ -n "${vksrc}" ] && [ -e "${vksrc}" ] || continue
        vkdir="${OUT_DIR}/frameworks/${vkfw}.framework"; mkdir -p "${vkdir}"
        cp "${vksrc}" "${vkdir}/${vkfw}"
        install_name_tool -id "@rpath/${vkfw}.framework/${vkfw}" "${vkdir}/${vkfw}"
        cat > "${vkdir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${vkfw}</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.${vkfw}</string>
  <key>CFBundleName</key><string>${vkfw}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION}</string>
  <key>CFBundleVersion</key><string>${FFMPEG_VERSION}</string>
  <key>MinimumOSVersion</key><string>13.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${VKPLAT}</string></array>
</dict>
</plist>
PLIST
      done
      if [ -f "${DEPS_DIR}/lib/MoltenVK_icd.json" ]; then
        cp "${DEPS_DIR}/lib/MoltenVK_icd.json" "${OUT_DIR}/frameworks/MoltenVK_icd.json"
        sed -i.bak 's|"library_path"[[:space:]]*:[[:space:]]*"[^"]*"|"library_path": "./MoltenVK.framework/MoltenVK"|' \
          "${OUT_DIR}/frameworks/MoltenVK_icd.json"
        rm -f "${OUT_DIR}/frameworks/MoltenVK_icd.json.bak"
      fi
    fi
    ;;
  *)
    mkdir -p "${OUT_DIR}/include"
    cp -a "${PREFIX_DIR}/lib/"*.so* "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffmpeg" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffprobe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    # Bundle the libc-only Vulkan loader (Linux) so the artifact carries no external
    # libvulkan dependency — whisper's ggml links it, and it dlopens the system GPU
    # driver at runtime. The $ORIGIN rpath pass below lets the libs find it.
    [[ "${BUILD_VULKAN_LOADER:-0}" == "1" ]] && cp -a "${DEPS_DIR}/lib/"libvulkan.so* "${OUT_DIR}/" 2>/dev/null || true
    ;;
esac

# ── Fix library paths for flat relocatable layout ─────────────────────────

case "${RID}" in
  win-*)
    # Windows: DLLs in same directory as exe are found automatically
    echo "Windows DLL layout — no rpath fix needed."
    ;;
  osx-*)
    # macOS: use install_name_tool to set @rpath/@loader_path
    echo "Fixing macOS dylib paths for flat layout..."
    # Change each dylib's install name to @rpath/libname.dylib
    for lib in "${OUT_DIR}"/*.dylib; do
      [ -L "${lib}" ] && continue
      libname="$(basename "${lib}")"
      install_name_tool -id "@rpath/${libname}" "${lib}"
    done
    # Update cross-references between dylibs and binaries
    for target in "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe" "${OUT_DIR}"/*.dylib; do
      [ -L "${target}" ] && continue
      [ ! -f "${target}" ] && continue
      # Change references from build-time absolute paths to @rpath
      for lib in "${OUT_DIR}"/*.dylib; do
        [ -L "${lib}" ] && continue
        libname="$(basename "${lib}")"
        old_path="${PREFIX_DIR}/lib/${libname}"
        install_name_tool -change "${old_path}" "@rpath/${libname}" "${target}" 2>/dev/null || true
      done
      install_name_tool -add_rpath "@loader_path" "${target}" 2>/dev/null || true
    done
    ;;
  android-*|ios-*)
    # Android: unversioned sonames, no rpath needed. iOS: the per-framework @rpath install-names
    # are set during framework assembly above, so nothing to do here.
    echo "Mobile build — no additional rpath/install_name fixup needed."
    ;;
  *)
    # Linux (glibc/musl): use patchelf to set $ORIGIN rpath
    echo "Fixing ELF rpath for flat layout..."
    patchelf --set-rpath '$ORIGIN' "${OUT_DIR}/ffmpeg"
    patchelf --set-rpath '$ORIGIN' "${OUT_DIR}/ffprobe"
    for lib in "${OUT_DIR}"/*.so*; do
      [ -L "${lib}" ] && continue
      patchelf --set-rpath '$ORIGIN' "${lib}"
    done
    ;;
esac

############################################
