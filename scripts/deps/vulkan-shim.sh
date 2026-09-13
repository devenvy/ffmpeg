#!/usr/bin/env bash
# Vulkan-Shim-Loader (MIT) — a STATIC stub that resolves the real Vulkan loader at RUNTIME
# instead of importing it. SOURCED by scripts/steps/06_build_libraries.sh; not standalone.
#
# Why this exists. On Windows, whisper's ggml-vulkan links Vulkan directly, and mingw ships no
# Vulkan import library, so we used to synthesize one with dlltool. That produces a HARD import:
#
#     $ objdump -p avfilter-12.dll | grep 'DLL Name'
#     DLL Name: vulkan-1.dll        <-- machine without it cannot load avfilter at all
#
# and since libavfilter carries af_whisper, a machine with no vulkan-1.dll could not start
# ffmpeg.exe AT ALL. Not a degraded filter — a dead artifact. vulkan-1.dll normally arrives with
# a GPU driver, so this is invisible on a developer desktop and fatal on a headless server,
# a container, or a fresh VM.
#
# The fix follows BtbN/FFmpeg-Builds, the reference Windows FFmpeg publisher, which uses this
# same shim for this same reason. Comparing published artifacts of the same FFmpeg version:
#
#                    vulkan symbols compiled in   vulkan-1.dll hard import
#     BtbN                      2                          0
#     ours (9.0.1.6)            2                          1
#
# i.e. identical capability, but only ours is undeployable without the DLL. The shim links
# kernel32 and calls LoadLibraryExA("vulkan-1.dll") on first use (dlopen("libvulkan.so.1")
# elsewhere), so Vulkan present => filters and GPU whisper work exactly as before; Vulkan absent
# => the binary still starts and Vulkan degrades instead of the artifact being dead on arrival.
#
# IMPERSONATE mode makes the static library's name vulkan-1 on Windows (vulkan elsewhere), so it
# drops into the same -DVulkan_LIBRARY slot the dlltool import-lib occupied, with no change to
# how ggml-vulkan or libplacebo are configured.
[[ "${BUILD_VULKAN}" == "1" && "${BUILD_VULKAN_SHIM:-0}" == "1" ]] || {
  echo "Skipping Vulkan shim loader (not needed for ${RID})."; return 0
}

echo "Building Vulkan shim loader (static, runtime-resolved)..."
cd "${WORK_DIR}" || exit 1
rm -rf Vulkan-Shim-Loader
clone_dep vulkan-shim "${WORK_DIR}/Vulkan-Shim-Loader"
cd Vulkan-Shim-Loader || exit 1

# The generator reads its Vulkan-Headers submodule directly (CMakeLists uses
# ${CMAKE_CURRENT_SOURCE_DIR}/Vulkan-Headers/include), so the submodule is required even though
# vulkan-headers.sh has already installed headers into DEPS_DIR. The git wrapper in
# scripts/lib.sh retries `submodule` as well as `clone`, so this gets the same backoff.
git submodule update --init --depth 1

# CMAKE_CXX_COMPILER is not optional: the Vulkan-Headers submodule's own CMakeLists calls
# project() with CXX enabled, and configure fails its compiler test without it. Found by
# building this for mingw locally before wiring it in, not by a CI round-trip.
cmake -B _build \
  -DCMAKE_INSTALL_PREFIX="${DEPS_DIR}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DVULKAN_SHIM_IMPERSONATE=ON \
  ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"}
cmake --build _build -j"$(${NPROC})"

# Install by hand rather than `cmake --install`: upstream's install rules are aimed at its own
# vulkan-shim naming, and what we need is precisely the impersonating archive in DEPS_DIR/lib.
VK_SHIM_LIB="$(find _build -name 'libvulkan-1.a' -o -name 'libvulkan.a' | head -1)"
[ -n "${VK_SHIM_LIB}" ] || {
  echo "ERROR: Vulkan shim built no impersonating archive (expected libvulkan-1.a / libvulkan.a)." >&2
  find _build -name '*.a' | sed 's/^/  /' >&2
  exit 1
}
mkdir -p "${DEPS_DIR}/lib"
cp "${VK_SHIM_LIB}" "${DEPS_DIR}/lib/"
VULKAN_SHIM_LIB="${DEPS_DIR}/lib/$(basename "${VK_SHIM_LIB}")"

# Guard the whole premise: if this ever resolved to an import library rather than a real static
# archive, the hard dependency would silently come back and we would only find out from a user.
if ! file -b "${VULKAN_SHIM_LIB}" | grep -qiE 'archive|current ar archive'; then
  echo "ERROR: expected a static archive for the Vulkan shim, got: $(file -b "${VULKAN_SHIM_LIB}")" >&2
  exit 1
fi
# shellcheck disable=SC2034  # exported for scripts/deps/whisper.sh
export VULKAN_SHIM_LIB
echo "Vulkan shim loader built: ${VULKAN_SHIM_LIB} (no hard dependency on the Vulkan runtime)."
