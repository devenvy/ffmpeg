#!/usr/bin/env bash
# iOS (ios-arm64 device / ios-sim-arm64 simulator) test — structural checks plus an ABI
# link check. The artifact is one dynamic .framework per libav* library (Mach-O dylibs);
# we verify arch, core symbols, and features/headers, then (macOS build job) link the smoke
# program against the frameworks to prove they resolve. EXECUTING it on the simulator is
# scripts/test/ios-run.sh.
set -uo pipefail
RID="${1:?usage: ios.sh <rid> <artifact-native-dir>}"
DIR="${2:?usage: ios.sh <rid> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/lib.sh"
info "iOS structural checks (${RID}, ${DIR})"

FWDIR="${DIR}/frameworks"
for base in avcodec avformat avutil avfilter swscale swresample; do
  bin="${FWDIR}/lib${base}.framework/lib${base}"
  [ -e "$bin" ] || { fail "missing lib${base}.framework"; continue; }
  check_arch "$bin" 'Mach-O 64-bit dynamically linked shared library arm64'
  check_symbol "$bin" "${base}_version"
  check_shared_object "$bin"
done

# Feature/license from the embedded config (present in each framework's binary).
load_config_string "${FWDIR}/libavutil.framework/libavutil" "${FWDIR}/libavcodec.framework/libavcodec"

# Vulkan is v3-only (MoltenVK + Vulkan-Headers are Apache-2.0, dropped from the v2
# App-Store series). The embedded --enable-version3 flag distinguishes the series.
#
# On iOS, Vulkan is STATICALLY linked: MoltenVK is the driver and there is no Khronos
# loader for the iOS SDK, so FFmpeg's dlopen path (which only ever tries the leaf names
# libvulkan.dylib / libvulkan.1.dylib / libMoltenVK.dylib) can never resolve inside an
# app bundle. --enable-vulkan-static makes FFmpeg call vkGetInstanceProcAddr directly.
case " ${CONFIG_STR} " in
  *" --enable-version3 "*)
    # Only the -static flag is asserted: lib.sh's check_config pattern matches INSIDE
    # "--enable-vulkan-static", so a separate "--enable-vulkan" check here could never fail
    # and would manufacture confidence. FFmpeg declares vulkan_static_deps="vulkan", so
    # --enable-vulkan-static cannot be accepted unless Vulkan is enabled — coverage is kept.
    check_config "--enable-vulkan-static" "Vulkan statically linked (MoltenVK)"
    ;;
  *)
    check_config_absent "--enable-vulkan" "Vulkan (v2: dropped)"
    check_config_absent "--enable-vulkan-static" "Vulkan static (v2: dropped)"
    ;;
esac

# L1/L2: MoltenVK is Apache-2.0. It must be folded into the libav* frameworks on v3 and
# be entirely absent on v2. Either way it must NEVER ship as its own framework, and the
# Khronos loader / ICD JSON must never appear (they are not built for the iOS SDK).
for stray in "${FWDIR}/MoltenVK.framework" "${FWDIR}/vulkan.framework" "${FWDIR}/MoltenVK_icd.json"; do
  [ -e "${stray}" ] \
    && fail "unexpected artifact $(basename "${stray}") — iOS links Vulkan statically" \
    || pass "no stray $(basename "${stray}") in the framework set"
done

# L3: attribution must survive the switch to static linking. The MoltenVK binary is no
# longer a visible file in the artifact, so this is the only thing proving its Apache-2.0
# text still ships. v2 never builds MoltenVK, so it must NOT carry the text either.
case " ${CONFIG_STR} " in
  *" --enable-version3 "*)
    if compgen -G "${DIR}/legal/licenses/MoltenVK/*" >/dev/null 2>&1; then
      pass "MoltenVK Apache-2.0 text present (legal/licenses/MoltenVK/)"
    else
      fail "MoltenVK is linked in but legal/licenses/MoltenVK/ is missing — attribution lost"
    fi
    ;;
  *)
    [ -d "${DIR}/legal/licenses/MoltenVK" ] \
      && fail "v2 cell carries MoltenVK attribution — Apache-2.0 leaked into an LGPLv2.1 build" \
      || pass "no MoltenVK attribution in the v2 cell (correct: not built)"
    ;;
esac

# Record which Apple system frameworks libavutil itself loads. Static MoltenVK links Metal /
# IOSurface / Foundation / QuartzCore / CoreGraphics into libavutil; if they show up here they
# are libavutil's own recorded dependencies and a consumer does NOT have to re-link them. This
# is informational — it decides what the install docs claim, and it is not a gate.
if command -v otool >/dev/null 2>&1 && [ -e "${FWDIR}/libavutil.framework/libavutil" ]; then
  info "libavutil load commands: $(otool -L "${FWDIR}/libavutil.framework/libavutil" \
    | awk 'NR>1{print $1}' | grep -oE '[A-Za-z]+\.framework' | sort -u | tr '\n' ' ')"
fi

check_config "--enable-videotoolbox" "VideoToolbox"
check_config "--enable-whisper" "Whisper ASR filter"
check_tls
# ios-sim is the lean slice (04_select_license drops x264/x265 on the simulator);
# the device slice keeps full GPL parity.
LEAN=""; [ "$RID" = "ios-sim-arm64" ] && LEAN=lean
check_license_boundary "$LEAN"

[ -f "${FWDIR}/libavcodec.framework/Headers/avcodec.h" ] \
  && pass "framework headers present (libavcodec.framework/Headers/avcodec.h)" \
  || fail "missing libavcodec.framework/Headers/avcodec.h"

# ABI link check for BOTH slices (macOS build job): DYNAMICALLY link the smoke program
# against the dylibs. iOS is dynamic now, so this resolves cleanly at build time — no
# -all_load static whack-a-mole — which is why this is a GATING check again (SMOKE_SOFT
# gone). A real Tier-2 signal even for the DEVICE slice, which can't be executed on CI
# (the simulator RUN, on the Apple-Silicon runner, is ios-run.sh).
if command -v xcrun >/dev/null 2>&1; then
  case "$RID" in
    ios-sim-arm64) IOS_SDK=iphonesimulator; IOS_MIN=-mios-simulator-version-min=13.0 ;;
    *)             IOS_SDK=iphoneos;        IOS_MIN=-miphoneos-version-min=13.0 ;;
  esac
  SDK="$(xcrun --sdk "${IOS_SDK}" --show-sdk-path 2>/dev/null)"
  CC="$(xcrun --sdk "${IOS_SDK}" --find clang 2>/dev/null)"
  # Dynamic link against the frameworks: the static deps (whisper/ggml, opus, kvazaar, …) are
  # baked INTO each framework's binary, so we link only the libav* frameworks plus the Apple
  # system frameworks/libs they load. -F resolves BOTH the -framework links and smoke.c's
  # <libavcodec/…> header imports; -rpath points at the frameworks dir so a run could resolve
  # them (a device app resolves via the embedded Frameworks dir + @rpath).
  check_smoke_link "${CC} -arch arm64 ${IOS_MIN} -isysroot ${SDK}" \
    "${FWDIR}" /tmp/smoke_ios \
    -F "${FWDIR}" \
    -framework libavformat -framework libavcodec -framework libavfilter \
    -framework libavutil -framework libswscale -framework libswresample \
    -Wl,-rpath,"${FWDIR}" \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation -framework CoreServices \
    -framework Security -framework Foundation -framework Metal -framework MetalKit \
    -framework Accelerate -framework QuartzCore \
    -lc++ -liconv -lz
else
  skip "smoke link: Xcode/xcrun not available (run in the macOS build job)"
fi

finish
