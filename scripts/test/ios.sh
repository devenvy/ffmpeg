#!/usr/bin/env bash
# Apple framework-target test — iOS device (ios-arm64), iOS simulator (ios-sim-arm64) and
# Mac Catalyst (maccatalyst-arm64 / maccatalyst-x64). All three ship the identical artifact
# shape (one dynamic .framework per libav* library), so they share this script rather than a
# near-duplicate; the deltas are the expected arch, the Mach-O platform, and how the smoke
# program is compiled. Structural checks plus an ABI link check. The artifact is one dynamic .framework per libav* library (Mach-O dylibs);
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
# maccatalyst-x64 is the only x86_64 slice in this family; everything else is arm64.
case "$RID" in
  maccatalyst-x64) EXPECT_ARCH=x86_64 ;;
  *)               EXPECT_ARCH=arm64  ;;
esac
for base in avcodec avformat avutil avfilter swscale swresample; do
  bin="${FWDIR}/lib${base}.framework/lib${base}"
  [ -e "$bin" ] || { fail "missing lib${base}.framework"; continue; }
  check_arch "$bin" "Mach-O 64-bit dynamically linked shared library ${EXPECT_ARCH}"
  check_symbol "$bin" "${base}_version"
  check_shared_object "$bin"
done

# The single most important Catalyst gate. A macabi binary differs from a plain macOS one
# only by the LC_BUILD_VERSION platform byte (6 = MACCATALYST, 1 = MACOS) -- same SDK, same
# arch, same everything else. If `-target …-macabi` silently stopped applying, the build would
# still succeed and produce a working-looking dylib, but Xcode would reject the slice when the
# xcframework was consumed, and CI would not have noticed. Read the platform out of the binary.
if [ "${RID#maccatalyst-}" != "${RID}" ]; then
  if command -v otool >/dev/null 2>&1; then
    for base in avcodec avutil; do
      bin="${FWDIR}/lib${base}.framework/lib${base}"
      [ -e "$bin" ] || continue
      plat="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/^ *platform/{print $2; exit}')"
      case "${plat}" in
        6|MACCATALYST|maccatalyst) pass "lib${base} is a Mac Catalyst binary (LC_BUILD_VERSION platform ${plat})" ;;
        "")            fail "lib${base} has no LC_BUILD_VERSION — cannot confirm it is macabi" ;;
        *)             fail "lib${base} platform is ${plat}, expected 6/MACCATALYST — -target macabi did not apply" ;;
      esac
    done
  else
    skip "Mach-O platform check: otool not available"
  fi
fi

# Feature/license from the embedded config (present in each framework's binary).
load_config_string "${FWDIR}/libavutil.framework/libavutil" "${FWDIR}/libavcodec.framework/libavcodec"

# Vulkan is v3-only (MoltenVK + Vulkan-Headers are Apache-2.0, dropped from the v2
# App-Store series). The embedded --enable-version3 flag distinguishes the series.
#
# On iOS, Vulkan is STATICALLY linked: MoltenVK is the driver and we don't build the Khronos
# loader for iOS here (vulkan-loader.sh supplies no iOS CMake toolchain — upstream does
# support iOS, this is our configuration), so FFmpeg's dlopen path (which only ever tries the
# leaf names libvulkan.dylib / libvulkan.1.dylib / libMoltenVK.dylib) can never resolve inside
# an app bundle. --enable-vulkan-static makes FFmpeg call vkGetInstanceProcAddr directly.
case " ${CONFIG_STR} " in
  *" --enable-version3 "*)
    # WIRING GUARD ONLY. check_config greps the embedded ./configure COMMAND LINE, not the
    # feature set configure actually resolved, and moltenvk.sh appends --enable-vulkan-static
    # unconditionally on every v3 iOS slice. So this proves the flag was passed; it can never
    # prove Vulkan survived configure. (It also cannot fail independently of
    # "--enable-vulkan": the pattern matches INSIDE "--enable-vulkan-static".)
    check_config "--enable-vulkan-static" "Vulkan statically linked (MoltenVK)"
    # The real gate, read out of the BINARY: av_vkfmt_from_pixfmt is public libavutil API
    # compiled only under CONFIG_VULKAN, so it is absent entirely — not merely undefined —
    # if Vulkan silently dropped out of configure. (Not vkGetInstanceProcAddr: check_symbol
    # falls back to plain `nm`, which also lists UNDEFINED symbols, so that would pass even
    # on a build where MoltenVK was never linked.)
    check_symbol "${FWDIR}/libavutil.framework/libavutil" "av_vkfmt_from_pixfmt"
    ;;
  *)
    check_config_absent "--enable-vulkan" "Vulkan (v2: dropped)"
    check_config_absent "--enable-vulkan-static" "Vulkan static (v2: dropped)"
    ;;
esac

# L1/L2: MoltenVK is Apache-2.0. It must be folded into the libav* frameworks on v3 and
# be entirely absent on v2. Either way it must NEVER ship as its own framework, and the
# Khronos loader / ICD JSON must never appear (we don't build the loader for iOS, and
# upstream MoltenVK only emits the ICD JSON for its macOS slice).
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
  # Catalyst compiles against the macOS SDK with an ios*-macabi target triple -- there is no
  # "maccatalyst" SDK and no -m…-version-min flag for it; -target carries both the arch and the
  # deployment floor, mirroring scripts/platform/apple.sh. -arch is therefore NOT passed for
  # Catalyst: it would conflict with the arch already named in the triple.
  case "$RID" in
    ios-sim-arm64)   IOS_SDK=iphonesimulator; IOS_MIN=-mios-simulator-version-min=13.0 ;;
    maccatalyst-*)   IOS_SDK=macosx;          IOS_MIN="-target ${EXPECT_ARCH}-apple-ios14.0-macabi" ;;
    *)               IOS_SDK=iphoneos;        IOS_MIN=-miphoneos-version-min=13.0 ;;
  esac
  case "$RID" in
    maccatalyst-*) ARCH_FLAG="" ;;
    *)             ARCH_FLAG="-arch arm64" ;;
  esac
  # Catalyst compiles MoltenVK as the macOS variant (MVK_MACOS covers TARGET_OS_MACCATALYST),
  # which pulls in MVKDevice.mm's IOKit IORegistry calls. libavutil records IOKit as its own
  # load command, so this is belt-and-braces for the relink -- but it keeps the smoke link an
  # honest stand-in for what a consumer links, and iOS genuinely does not need it.
  MCAT_FW=()
  case "$RID" in
    maccatalyst-*) MCAT_FW=(-framework IOKit) ;;
  esac
  SDK="$(xcrun --sdk "${IOS_SDK}" --show-sdk-path 2>/dev/null)"
  CC="$(xcrun --sdk "${IOS_SDK}" --find clang 2>/dev/null)"
  # Dynamic link against the frameworks: the static deps (whisper/ggml, opus, kvazaar, …) are
  # baked INTO each framework's binary, so we link only the libav* frameworks plus the Apple
  # system frameworks/libs they load. -F resolves BOTH the -framework links and smoke.c's
  # <libavcodec/…> header imports; -rpath points at the frameworks dir so a run could resolve
  # them (a device app resolves via the embedded Frameworks dir + @rpath).
  check_smoke_link "${CC} ${ARCH_FLAG} ${IOS_MIN} -isysroot ${SDK}" \
    "${FWDIR}" /tmp/smoke_ios \
    -F "${FWDIR}" \
    -framework libavformat -framework libavcodec -framework libavfilter \
    -framework libavutil -framework libswscale -framework libswresample \
    -Wl,-rpath,"${FWDIR}" \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation -framework CoreServices \
    -framework Security -framework Foundation -framework Metal -framework MetalKit \
    -framework Accelerate -framework QuartzCore -framework IOSurface -framework UIKit \
    ${MCAT_FW[@]+"${MCAT_FW[@]}"} \
    -lc++ -liconv -lz
  # Catalyst is the only slice in this family that RUNS on the build host: macabi binaries are
  # native macOS Mach-O and dyld loads them directly, so the link check can be promoted to a real
  # execution. iOS device cannot be executed on CI at all, and the simulator needs simctl
  # (ios-run.sh). Only when the host arch matches the slice -- running the x86_64 slice on an
  # Apple-Silicon runner would depend on Rosetta being installed, which is not guaranteed.
  if [ "${RID#maccatalyst-}" != "${RID}" ] && [ -x /tmp/smoke_ios ]; then
    if [ "$(uname -m)" = "${EXPECT_ARCH}" ]; then
      if DYLD_FRAMEWORK_PATH="${FWDIR}" /tmp/smoke_ios >/tmp/smoke-run.out 2>&1; then
        pass "Catalyst smoke program EXECUTES on the host: $(head -1 /tmp/smoke-run.out)"
      else
        fail "Catalyst smoke program linked but failed to run: $(tail -3 /tmp/smoke-run.out | tr '
' ' ')"
      fi
    else
      skip "Catalyst smoke run: host is $(uname -m), slice is ${EXPECT_ARCH}"
    fi
  fi
else
  skip "smoke link: Xcode/xcrun not available (run in the macOS build job)"
fi

finish
