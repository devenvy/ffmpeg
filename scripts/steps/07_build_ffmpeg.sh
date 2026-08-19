#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 7: Build FFmpeg
#
# Download the pinned upstream FFmpeg source, patch the dependency
# pkg-config files for static Windows linking, then configure and build
# FFmpeg (shared libs + ffmpeg/ffprobe, or static libs for mobile) against
# everything built above.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── FFmpeg ────────────────────────────────────────────────────────────────

cd "${WORK_DIR}" || exit 1
rm -rf "${SRC_DIR}" "${PREFIX_DIR}"

echo "Downloading FFmpeg ${FFMPEG_VERSION}..."
# ffmpeg.org is the canonical source but has been intermittently flaky (transient
# TLS "unexpected eof"). Retry hard (including mid-transfer errors), then fall back
# to the identical source from the GitHub release tag so a single-host blip does
# not fail the whole build.
FF_ARCHIVE=""
# --retry-all-errors (retry on HTTP/connection errors, not just transient) needs
# curl >= 7.71. Old-glibc build hosts (e.g. the manylinux_2_28 container used for
# portable Linux builds) ship curl 7.61, which rejects the flag — probe for it and
# only pass it when supported, so the download degrades gracefully to plain --retry.
CURL_RETRY_ALL=()
if curl --retry-all-errors --version >/dev/null 2>&1; then
  CURL_RETRY_ALL=(--retry-all-errors)
fi
for url in \
  "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" ; do
  case "${url}" in *.xz) out=ffmpeg.tar.xz ;; *) out=ffmpeg.tar.gz ;; esac
  if curl -fsSL --retry 5 --retry-delay 5 "${CURL_RETRY_ALL[@]}" --connect-timeout 30 "${url}" -o "${out}"; then
    FF_ARCHIVE="${out}"; break
  fi
  echo "  download failed from ${url} — trying next mirror..." >&2
done
[ -n "${FF_ARCHIVE}" ] || { echo "ERROR: could not download FFmpeg ${FFMPEG_VERSION} from any mirror" >&2; exit 1; }
mkdir -p "${SRC_DIR}"
tar -xf "${FF_ARCHIVE}" -C "${SRC_DIR}" --strip-components=1

# ── Patch pkg-config for Windows static linking ──────────────────────────
# Dependency .pc files declare -lpthread and -lstdc++ in Libs/Libs.private.
# When FFmpeg links shared DLLs, -static-libgcc/-static-libstdc++ are
# ignored (GCC ignores them with -shared), so these resolve dynamically,
# creating runtime deps on libwinpthread-1.dll and libstdc++-6.dll.
# Fix: wrap them with -Bstatic/-Bdynamic in the .pc files themselves.
if [[ "${RID}" == win-* ]]; then
  echo "Patching pkg-config files for static GCC runtime linking..."
  for pc in "${DEPS_DIR}"/lib/pkgconfig/*.pc; do
    [ -f "$pc" ] || continue
    grep -q -- '-Wl,-Bstatic' "$pc" && continue
    sed -i \
      -e 's/-lpthread/-Wl,-Bstatic -lpthread -Wl,-Bdynamic/g' \
      -e 's/-lstdc++/-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic/g' \
      "$pc"
  done
fi

# ── Configure & Build ─────────────────────────────────────────────────────

cd "${SRC_DIR}" || exit 1

# ── Library kind & programs (RID-aware) ───────────────────────────────────
LIB_MODE_FLAGS=(--enable-shared --disable-static)
PROGRAM_FLAGS=(--enable-ffmpeg --enable-ffprobe --disable-ffplay)
case "${RID}" in
  ios-*)
    LIB_MODE_FLAGS=(--disable-shared --enable-static)
    PROGRAM_FLAGS=(--disable-programs)
    ;;
  android-*)
    PROGRAM_FLAGS=(--disable-programs)
    ;;
esac

CONFIGURE_CMD=(
  ./configure
  --prefix="${PREFIX_DIR}"
  "${PROGRAM_FLAGS[@]}"
  "${LIB_MODE_FLAGS[@]}"
  --disable-doc
  --disable-debug
  "${THREAD_FLAG}"
  --disable-nonfree
  --disable-autodetect
  --pkg-config-flags="--static"
  "${CONFIGURE_FLAGS[@]}"
  --extra-cflags="${EXTRA_CFLAGS}"
  ${PIC_FLAG:+"${PIC_FLAG}"}
  ${EXTRA_CXXFLAGS:+--extra-cxxflags="${EXTRA_CXXFLAGS}"}
  ${EXTRA_LDFLAGS:+--extra-ldflags="${EXTRA_LDFLAGS}"}
  ${EXTRA_LIBS:+--extra-libs="${EXTRA_LIBS}"}
)

echo "Configuring FFmpeg..."
"${CONFIGURE_CMD[@]}"

echo "Building FFmpeg..."
make -j"$(${NPROC})"
make install

############################################
