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
    mkdir -p "${OUT_DIR}/include" "${OUT_DIR}/lib"
    cp -a "${PREFIX_DIR}/include/." "${OUT_DIR}/include/"
    # iOS is --enable-shared now: copy each libav* dylib under its UNVERSIONED name
    # (libavcodec.dylib, not libavcodec.62.dylib) so the xcframework names come out clean.
    # The static dependency archives (whisper/ggml, kvazaar, opus, ...) are linked INTO
    # these dylibs, so each is self-contained — no dep .a to ship (unlike the old static
    # build, which had to ship the DEPS_DIR archives for the consumer to resolve).
    # cp (without -P/-a) dereferences the libavcodec.dylib -> libavcodec.NN.dylib symlink and
    # writes the REAL dylib content under the unversioned name. (No `readlink -f` — BSD/macOS
    # readlink, which is what runs here, has no -f.)
    for base in avcodec avformat avutil avfilter swscale swresample; do
      src="${PREFIX_DIR}/lib/lib${base}.dylib"
      [ -e "${src}" ] && cp "${src}" "${OUT_DIR}/lib/lib${base}.dylib"
    done
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
  android-*)
    echo "Mobile build — no rpath/install_name fixup needed."
    ;;
  ios-*)
    # Point each dylib's own id — and its references to sibling libav*/libsw* dylibs — at
    # @rpath so the frameworks are relocatable (Xcode embeds them under the app's Frameworks
    # dir and supplies the runpath). Mirrors the macOS fixup, but reads the ACTUAL recorded
    # dependency names via otool, so the dylib version suffixes don't have to be hardcoded.
    echo "Fixing iOS dylib install-names for @rpath..."
    for t in "${OUT_DIR}/lib/"*.dylib; do
      [ -e "${t}" ] || continue
      install_name_tool -id "@rpath/$(basename "${t}")" "${t}"
      otool -L "${t}" | awk 'NR>1{print $1}' | while read -r ref; do
        b="$(basename "${ref}")"; stem="${b%%.*}"
        case "${stem}" in
          libav*|libsw*) install_name_tool -change "${ref}" "@rpath/${stem}.dylib" "${t}" 2>/dev/null || true ;;
        esac
      done
    done
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
