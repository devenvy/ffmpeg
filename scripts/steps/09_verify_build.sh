#!/usr/bin/env bash
set -euo pipefail
############################################
# Step 9: Verify Build
#
# Static verification gate — fail the build on regressions: whisper enabled,
# no GPL components in an LGPL build, the platform hardware decoder
# registered, mobile headers present, and Android sonames unversioned.
#
# Sourced by build.sh (shares its environment); not a standalone script.
############################################

# ── Static verification gate ──────────────────────────────────────────────
echo "Running static verification checks..."
VERIFY_FAIL=0
COMPONENTS="${SRC_DIR}/config_components.h"

# 1b. Whisper filter — must be enabled in every build (always-on).
grep -q 'CONFIG_WHISPER_FILTER 1' "${COMPONENTS}" \
  || { echo "VERIFY FAIL: whisper filter not enabled"; VERIFY_FAIL=1; }

# 2. License boundary — lgpl builds must not enable GPL encoders.
if [[ "${LICENSE}" == "lgpl" ]]; then
  if grep -qE 'CONFIG_LIBX264 1|CONFIG_LIBX265 1|CONFIG_GPL 1' "${SRC_DIR}/config.h" 2>/dev/null; then
    echo "VERIFY FAIL: lgpl build enables GPL components"; VERIFY_FAIL=1
  fi
fi

# 3. Platform hw decoder registered.
case "${RID}" in
  android-*)
    grep -q 'CONFIG_H264_MEDIACODEC_DECODER 1' "${COMPONENTS}" \
      || { echo "VERIFY FAIL: h264_mediacodec decoder not registered"; VERIFY_FAIL=1; }
    ;;
  ios-*|osx-*)
    grep -q 'CONFIG_H264_VIDEOTOOLBOX_HWACCEL 1' "${COMPONENTS}" \
      || { echo "VERIFY FAIL: h264_videotoolbox hwaccel not registered"; VERIFY_FAIL=1; }
    ;;
esac

# 4. Deliverable shape — every RID ships dev headers alongside runtime libs. iOS ships them
# inside each .framework/Headers (dynamic-framework layout); every other RID uses include/.
if [[ "${RID}" == ios-* ]]; then
  [ -f "${OUT_DIR}/frameworks/libavcodec.framework/Headers/avcodec.h" ] \
    || { echo "VERIFY FAIL: missing libavcodec.framework/Headers/avcodec.h"; VERIFY_FAIL=1; }
else
  [ -f "${OUT_DIR}/include/libavcodec/avcodec.h" ] \
    || { echo "VERIFY FAIL: missing include/libavcodec/avcodec.h"; VERIFY_FAIL=1; }
fi

# 4b. Windows ships one MSVC import library (.lib) per runtime DLL.
if [[ "${RID}" == win-* ]]; then
  ndll=$(ls "${OUT_DIR}"/*.dll 2>/dev/null | wc -l)
  nlib=$(ls "${OUT_DIR}/lib"/*.lib 2>/dev/null | wc -l)
  if [ "${nlib}" -eq 0 ] || [ "${nlib}" -lt "${ndll}" ]; then
    echo "VERIFY FAIL: expected >= ${ndll} import libs in lib/, found ${nlib}"; VERIFY_FAIL=1
  fi
fi

# 5. Android unversioned soname.
if [[ "${RID}" == android-* ]]; then
  for so in "${OUT_DIR}/lib/${ANDROID_ABI}"/*.so; do
    [ -e "${so}" ] || continue
    sn="$(patchelf --print-soname "${so}")"
    case "${sn}" in
      *.so) ;;
      *) echo "VERIFY FAIL: ${so} has versioned soname ${sn}"; VERIFY_FAIL=1 ;;
    esac
  done
fi

if [[ "${VERIFY_FAIL}" != "0" ]]; then
  echo "Static verification FAILED."
  exit 1
fi
echo "Static verification passed."
