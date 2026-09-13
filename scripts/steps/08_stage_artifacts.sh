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

# Ship pkg-config files. `pkg-config --cflags --libs libavcodec` is the standard way a
# Linux/macOS consumer integrates, and the -dev archives carried none at all: FFmpeg installs
# them under lib/pkgconfig, which nothing staged.
#
# They cannot be copied verbatim. FFmpeg bakes the BUILD prefix in (prefix=/home/runner/...),
# which does not exist on the consumer's machine, so a verbatim .pc is worse than none -- it
# resolves to paths that silently are not there. Rewrite the prefix to ${pcfiledir}, which
# pkg-config expands to the directory holding the .pc, making the archive relocatable.
#
# libdir is set to ${prefix} rather than ${prefix}/lib because the desktop layout is flat:
# the shared libraries sit at the archive root next to the binaries, not in lib/.
stage_pkgconfig() {   # $1 = libdir for the .pc, SINGLE-QUOTED by callers
  # NOTE: callers pass '${prefix}' single-quoted on purpose. That is a pkg-config
  # variable that must reach the .pc file LITERALLY -- double quotes make the shell
  # expand it, which under `set -u` aborts staging with "prefix: unbound variable".
  local libdir_expr="$1" src="${PREFIX_DIR}/lib/pkgconfig" dst="${OUT_DIR}/lib/pkgconfig" pc
  [ -d "${src}" ] || { echo "WARNING: no pkgconfig dir at ${src} — dev archive will ship none" >&2; return 0; }
  mkdir -p "${dst}"
  for pc in "${src}"/*.pc; do
    [ -e "${pc}" ] || continue
    sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|'         -e 's|^exec_prefix=.*|exec_prefix=${prefix}|'         -e "s|^libdir=.*|libdir=${libdir_expr}|"         -e 's|^includedir=.*|includedir=${prefix}/include|'         "${pc}" > "${dst}/$(basename "${pc}")"
  done
  echo "Staged $(ls -1 "${dst}" 2>/dev/null | wc -l) pkg-config files."
}


case "${RID}" in
  win-*)
    mkdir -p "${OUT_DIR}/include" "${OUT_DIR}/lib"
    cp -a "${PREFIX_DIR}/bin/"*.dll "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffmpeg.exe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffprobe.exe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    stage_pkgconfig '${prefix}/lib'
    # Generate MSVC-consumable COFF import libraries (.lib) from each DLL so a
    # consumer with no FFmpeg build tooling can link with MSVC. gendef dumps the
    # DLL export table to a .def; llvm-dlltool turns it into a Microsoft short
    # import library (GNU dlltool's .dll.a is not reliably consumable by link.exe).
    # Named by base soname (avcodec.lib, not avcodec-62.lib) so MSVC/CMake find them.
    LLVM_DLLTOOL="$(command -v llvm-dlltool || ls /usr/lib/llvm-*/bin/llvm-dlltool 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "${LLVM_DLLTOOL}" ] || { echo "ERROR: llvm-dlltool not found (install the 'llvm' package)"; exit 1; }
    # The import library's machine type must match the RID, not the build host.
    # -m i386:x86-64 maps to IMAGE_FILE_MACHINE_AMD64, so using it for win-arm64 put
    # x64 .lib files inside the ARM64 dev archive, which link.exe rejects for an ARM64
    # target. Nothing caught it: the files exist and are well-formed COFF, they are
    # simply the wrong architecture, and the test only counted them.
    case "${RID}" in
      win-x64)   DLLTOOL_MACHINE="i386:x86-64" ;;
      win-arm64) DLLTOOL_MACHINE="arm64" ;;
      *) echo "ERROR: no llvm-dlltool machine mapping for RID ${RID}" >&2; exit 1 ;;
    esac
    for dll in "${OUT_DIR}/"*.dll; do
      [ -e "${dll}" ] || continue
      dllbase="$(basename "${dll}")"   # e.g. avcodec-62.dll
      stem="${dllbase%.dll}"           # e.g. avcodec-62
      libbase="${stem%-*}"             # e.g. avcodec
      gendef - "${dll}" > "${WORK_DIR}/${stem}.def"
      "${LLVM_DLLTOOL}" -m "${DLLTOOL_MACHINE}" \
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
    stage_pkgconfig '${prefix}'
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
  ios-*|maccatalyst-*)
    # iOS ships one dynamic .framework per libav* library (release.yml assembles the device +
    # simulator frameworks into a per-lib .xcframework). Each framework bundles the dylib (deref'd
    # from its versioned symlink, renamed to the framework's executable name), that lib's public
    # Headers, and an Info.plist. The static dependencies (whisper/ggml, kvazaar, opus, …) are
    # linked INTO the dylibs, so each framework is self-contained. @rpath install-names make them
    # relocatable — Xcode embeds them under the app's Frameworks dir and supplies the runpath.
    # Cross-library header includes ("libavutil/…" from a libavcodec header) resolve at consume
    # time because the sibling frameworks are all on the framework search path.
    mkdir -p "${OUT_DIR}/frameworks"
    # CFBundleSupportedPlatforms / MinimumOSVersion per platform. A Catalyst framework is a
    # MacOSX-platform bundle, but its MinimumOSVersion is still expressed on the iOS scale
    # (macabi targets ios14.0), which is what MCAT_TARGET encodes.
    case "${RID}" in
      ios-arm64)      IOS_PLATFORM=iPhoneOS        ; FW_MIN_OS=13.0 ;;
      ios-sim-arm64)  IOS_PLATFORM=iPhoneSimulator ; FW_MIN_OS=13.0 ;;
      maccatalyst-*)  IOS_PLATFORM=MacOSX          ; FW_MIN_OS=14.0 ;;
      *)              echo "ERROR: no framework platform mapping for ${RID}" >&2; exit 1 ;;
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
  <key>MinimumOSVersion</key><string>${FW_MIN_OS}</string>
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
    # No Vulkan artifacts are staged for iOS. MoltenVK is linked INTO the libav* framework
    # binaries (--enable-vulkan-static; see scripts/deps/moltenvk.sh), because we don't build
    # the Khronos loader for iOS here (vulkan-loader.sh supplies no iOS CMake toolchain; that's
    # our configuration, not an upstream limitation) and FFmpeg's dlopen fallback cannot
    # resolve a framework from inside an app bundle. MoltenVK's Apache-2.0 text still ships
    # via 10_write_legal.sh's WORK_DIR walk.
    ;;
  *)
    mkdir -p "${OUT_DIR}/include"
    cp -a "${PREFIX_DIR}/lib/"*.so* "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffmpeg" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/bin/ffprobe" "${OUT_DIR}/"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    stage_pkgconfig '${prefix}'
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
    # Rewrite install names + cross-references for the flat, relocatable layout.
    #
    # The previous pass GUESSED the old path as "${PREFIX_DIR}/lib/<file name>", i.e. the
    # full-version name (libavcodec.63.1.101.dylib). But upstream FFmpeg links against the
    # MAJOR-only name, so the actual LC_LOAD_DYLIB entries said libavcodec.63.dylib and the
    # -change never matched anything. The -id and -add_rpath passes succeeded, which made it
    # look like relinking worked, while every published macOS binary still loaded its
    # siblings by absolute build path and could not start on any other machine.
    #
    # Fix: do not guess. Read the load commands off each binary and rewrite whatever points
    # into the build tree, whatever it happens to be called.
    echo "Fixing macOS install names for the flat layout..."
  
    # Install name = @rpath + MAJOR-only, matching upstream's
    #   -install_name $(INSTALL_NAME_DIR)/$(SLIBNAME_WITH_MAJOR) -compatibility_version $(LIBMAJOR)
    # so a consumer records libavcodec.63.dylib and keeps working across patch bumps. The real
    # file stays fully versioned with symlinks beside it, exactly like the Linux layout.
    for lib in "${OUT_DIR}"/*.dylib; do
      [ -L "${lib}" ] && continue
      [ -f "${lib}" ] || continue
      libname="$(basename "${lib}")"
      major="$(printf '%s' "${libname}" | sed -E 's/^(lib[a-z0-9]+)\.([0-9]+)(\..*)?\.dylib$/\1.\2.dylib/')"
      install_name_tool -id "@rpath/${major}" "${lib}"
    done
  
    for target in "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe" "${OUT_DIR}"/*.dylib; do
      [ -L "${target}" ] && continue
      [ -f "${target}" ] || continue
      # Every dependency the binary actually records; rewrite the ones inside the build tree.
      while read -r dep; do
        case "${dep}" in
          "${PREFIX_DIR}"/*|"${DEPS_DIR}"/*|"${WORK_DIR}"/*)
            install_name_tool -change "${dep}" "@rpath/$(basename "${dep}")" "${target}" || true ;;
        esac
      done < <(otool -L "${target}" 2>/dev/null | awk 'NR>1 {print $1}')
      install_name_tool -add_rpath "@loader_path" "${target}" 2>/dev/null || true
      # Editing a Mach-O invalidates its signature, and arm64 refuses to load an
      # incorrectly-signed image. Re-sign ad-hoc after the last edit.
      codesign --force --sign - "${target}" 2>/dev/null || true
    done
  
    # Assert the result rather than trusting it: nothing may still point into the build tree.
    _leaked=""
    for target in "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe" "${OUT_DIR}"/*.dylib; do
      [ -L "${target}" ] && continue
      [ -f "${target}" ] || continue
      if otool -L "${target}" 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${WORK_DIR}"; then
        _leaked="${_leaked} $(basename "${target}")"
      fi
    done
    if [ -n "${_leaked}" ]; then
      echo "ERROR: build-tree paths survive in:${_leaked}" >&2
      otool -L "${OUT_DIR}/ffmpeg" 2>/dev/null | head -12 >&2
      exit 1
    fi
    # No shipped binary may depend on a package-manager prefix. The published osx-x64
    # artifacts carry an LC_LOAD_DYLIB on /usr/local/opt/gettext/lib/libintl.8.dylib -- a
    # Homebrew library present on the Intel runner and on no consumer machine, absent from
    # osx-arm64 because that runner has a different prefix. We do not bundle it, so this is a
    # hard failure, and naming the file identifies which dependency dragged it in.
    _brew=""
    for target in "${OUT_DIR}/ffmpeg" "${OUT_DIR}/ffprobe" "${OUT_DIR}"/*.dylib; do
      [ -L "${target}" ] && continue
      [ -f "${target}" ] || continue
      while read -r dep; do
        case "${dep}" in
          /usr/local/*|/opt/homebrew/*|/opt/local/*)
            _brew="${_brew} $(basename "${target}")->${dep}" ;;
        esac
      done < <(otool -L "${target}" 2>/dev/null | awk 'NR>1 {print $1}')
    done
    if [ -n "${_brew}" ]; then
      echo "ERROR: shipped binaries link package-manager libraries we do not bundle:" >&2
      printf '  %s
' ${_brew} >&2
      echo "  (build the offending dependency without it, e.g. --disable-nls for gettext/libintl)" >&2
      exit 1
    fi
    echo "macOS install names rewritten; no build-tree paths remain."
    ;;
  android-*|ios-*|maccatalyst-*)
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
