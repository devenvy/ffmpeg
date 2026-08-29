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
    # Strip -lgcc_s wherever a dep over-captured the implicit compiler link line into Libs.private
    # (SRT's srt.pc does this). -lgcc_s pulls the SHARED gcc unwinder (libgcc_s_seh-1.dll), which
    # both adds a runtime DLL dep and collides with the static libgcc_eh that -static-libgcc pulls
    # → "multiple definition of _Unwind_Resume" at the DLL link. Idempotent; must run BEFORE the
    # -Bstatic skip below, since srt.pc already carries -Bstatic (so the skip would pass it over).
    sed -i -e 's/ -lgcc_s / /g' -e 's/ -lgcc_s$//' "$pc"
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
  # Mobile ships libraries only (no ffmpeg/ffprobe CLI). iOS is DYNAMIC like every other
  # platform — the static-.a build was an anomaly. It also matters for LICENSING: LGPLv2.1
  # §6 requires the end user be able to relink the app against a modified library; static
  # linking forces shipping object files for that, dynamic frameworks satisfy it inherently.
  # So the App-Store lgplv2 iOS build MUST be dynamic. Same shared libav*.dylib as macOS.
  ios-*|android-*)
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
