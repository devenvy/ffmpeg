#!/usr/bin/env bash
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
    cp -a "${PREFIX_DIR}/lib/"*.a "${OUT_DIR}/lib/"
    # A static .a does NOT embed its dependencies the way a shared lib does: FFmpeg's
    # libav*.a reference symbols that live in the dependency archives (zimg, whisper/
    # ggml, opus, openssl, freetype, ...), which sit in DEPS_DIR — not the FFmpeg
    # prefix. Ship them too, or a consumer (and our ABI smoke link) can't resolve them.
    cp -a "${DEPS_DIR}/lib/"*.a "${OUT_DIR}/lib/" 2>/dev/null || true
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
    echo "Mobile build — no rpath/install_name fixup needed."
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
