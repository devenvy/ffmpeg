#!/usr/bin/env bash
# Regenerate the build coverage matrix — ONE file per maintained FFmpeg major and
# license variant (docs/matrix/ffmpeg-<major>-<gpl|lgpl>.md) plus an index
# (docs/matrix/README.md).
#
# Each matrix's rows are DISCOVERED from that version's own configure component
# lists (HWACCEL_AUTODETECT_LIBRARY_LIST, HWACCEL_LIBRARY_LIST,
# EXTERNAL_LIBRARY_LIST, EXTERNAL_LIBRARY_GPL_LIST) — the complete universe of
# things that FFmpeg version can be built with. Whether we build each is read
# from the build scripts (per-RID BUILD_* flags + the --enable-* each active
# deps/<x>.sh appends, plus the hwaccel --enable-* in 02_configure), per license.
# Because the universe is version-specific, a newer FFmpeg that gained a library
# shows it in its own file, and the index flags libraries that differ by version.
#
# Cell markers:  ✓ built · n/a not applicable on the platform · — FFmpeg supports
# it but we don't build it here (a choice) · ✗ (lgpl only) can't be included for
# license reasons (GPL / conflicting). Curation (label, category, footnote) is
# OVERLAY ONLY and can never hide a row.
#
# Usage:  bash scripts/gen-matrix.sh   (regenerates from every deps.json .ffmpeg entry)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

RIDS=(linux-x64 linux-arm64 linux-armhf linux-musl-x64 win-x64 osx-x64 osx-arm64 android-arm64 ios-arm64 ios-sim-arm64)

# FFmpeg configure for EVERY maintained version (deps.json's .ffmpeg list) — the source of
# truth for each version's library universe. Each is rendered to its own files.
mapfile -t VERSIONS < <(jq -r '.ffmpeg[]' deps.json)
[ "${#VERSIONS[@]}" -gt 0 ] || { echo "ERROR: no versions in deps.json .ffmpeg" >&2; exit 1; }
CONF_DIR="$(mktemp -d)"; MANIFEST_FILE="$(mktemp)"; : > "${MANIFEST_FILE}"
for V in "${VERSIONS[@]}"; do
  CF="${CONF_DIR}/${V}.configure"
  if curl -fsSL --retry 3 --retry-connrefused \
       "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n${V}/configure" -o "${CF}" 2>/dev/null; then
    printf '%s\t%s\n' "${V}" "${CF}" >> "${MANIFEST_FILE}"
  else
    echo "ERROR: could not fetch FFmpeg n${V} configure — cannot build the matrix." >&2
    exit 1
  fi
done

# --- Simulate each RID under EACH license -> per-(RID,license) enabled sets ----
# Each line is "RID|LICENSE|hwaccels|BUILD_* flags". Kept separate (not unioned)
# so the matrix can be sliced per license: gpl builds get x264/x265, lgpl kvazaar.
simfile="$(mktemp)"
for RID in "${RIDS[@]}"; do
  for CELL in gplv3 gplv2 lgplv3 lgplv2; do
  (
    set +u
    xcrun() { echo /dummy-sdk; }
    LIC="${CELL%v*}"; VER="${CELL##*v}"          # gplv3 -> LIC=gpl VER=3
    ROOT_DIR="${ROOT_DIR}"; RID="$RID"; LICENSE="$LIC"; BUILD_RID="$RID"
    BUILD_LICENSE="$LIC"; BUILD_LICENSE_VERSION="$VER"
    # Use the runner's REAL NDK (same resolution as the build: ANDROID_NDK_HOME or the
    # preinstalled ANDROID_NDK_LATEST_HOME). android.sh looks up the toolchain host dir
    # (ls "$NDK/toolchains/llvm/prebuilt"), which fails under set -e if the NDK is a bare stub —
    # so a dummy dir isn't enough. /tmp remains only as a last-resort fallback where no NDK exists.
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-/tmp}}"; ANDROID_ABI=arm64-v8a; API=28; TOOLCHAIN=/dummy
    WORK_DIR=/tmp/sim; DEPS_DIR=/tmp/sim/deps; SRC_DIR=/tmp/sim/src
    # These are the environment the sourced config scripts read. export (in this isolated
    # subshell — no leak) both makes that intent explicit and marks them used for shellcheck.
    export LIC VER ROOT_DIR RID LICENSE BUILD_RID BUILD_LICENSE BUILD_LICENSE_VERSION \
           ANDROID_NDK_HOME ANDROID_ABI API TOOLCHAIN WORK_DIR DEPS_DIR SRC_DIR
    # shellcheck source=/dev/null  # don't follow — these config scripts source a dynamic platform file
    source scripts/steps/02_configure.sh >/dev/null 2>&1
    # shellcheck source=/dev/null
    source scripts/steps/04_select_license.sh >/dev/null 2>&1
    hw=$(printf '%s\n' "${CONFIGURE_FLAGS[@]}" \
         | grep -oE '^--enable-[a-z0-9_-]+' | sed 's/--enable-//' \
         | grep -vE '^(cross-compile|gpl|version3|hwaccel|decoder|encoder|shared|static|pic|pthreads|w32threads)$' \
         | tr '\n' ' ')
    flags=""
    for v in ${!BUILD_@}; do [ "${!v}" = 1 ] && flags="$flags ${v}"; done
    echo "${RID}|${CELL}|${hw}|${flags}"
  ) >> "$simfile"
  done
done

mkdir -p docs/matrix
python3 - "$simfile" "$MANIFEST_FILE" "${ROOT_DIR}/docs" <<'PY'
import sys, re, glob, os

# --- per-(RID, license) enabled sets ------------------------------------------
sim = {}
for line in open(sys.argv[1]):
    rid, cell, hw, flags = line.rstrip("\n").split("|")
    d = sim.setdefault((rid, cell), {"hw": set(), "flags": set()})
    d["hw"]    |= set(t.replace("-", "_") for t in hw.split())
    d["flags"] |= set(flags.split())

# --- maintained versions, grouped by major (highest version wins per major) ---
def vkey(v): return tuple(int(x) for x in re.findall(r"\d+", v))
by_major = {}
for line in open(sys.argv[2]):
    line = line.rstrip("\n")
    if not line: continue
    v, path = line.split("\t", 1)
    mj = v.split(".")[0]
    if mj not in by_major or vkey(v) > vkey(by_major[mj][0]):
        by_major[mj] = (v, open(path).read())
MAJORS = sorted(by_major, key=int)
OUTDIR = sys.argv[3]

RIDS = ["linux-x64","linux-arm64","linux-armhf","linux-musl-x64","win-x64",
        "osx-x64","osx-arm64","android-arm64","ios-arm64","ios-sim-arm64"]
ALL = set(RIDS)
LINUX = {r for r in RIDS if r.startswith("linux")}
WIN = {"win-x64"}; APPLE = {"osx-x64","osx-arm64","ios-arm64","ios-sim-arm64"}
MAC = {"osx-x64","osx-arm64"}; IOS = {"ios-arm64","ios-sim-arm64"}
ANDROID = {"android-arm64"}; DESKTOP = LINUX | WIN | MAC

# HAVE_* backends FFmpeg supports but that aren't in any *_LIBRARY_LIST.
EXTRA = {"mediafoundation": "hw", "schannel": "net", "securetransport": "net"}

# --- What we build: map each --enable-<token> to its dep's BUILD_* guard -------
active = set()
for line in open("scripts/steps/06_build_libraries.sh"):
    m = re.match(r'\s*\.\s+"\$\{D\}/([a-z0-9_-]+)\.sh"', line)
    if m: active.add(m.group(1))
tok_build = {}; tok_uncond = set(); tok_dep = {}
for f in sorted(glob.glob("scripts/deps/*.sh")):   # sorted -> deterministic token ownership across hosts
    name = os.path.basename(f)[:-3]
    if name not in active: continue
    # Strip comments first: a commented-out --enable / clone_dep must never be mistaken for a
    # real flag or ledger association (e.g. moltenvk.sh's doc comment mentioning --enable-vulkan
    # would otherwise hijack the "vulkan" key away from vulkan-headers.sh).
    code = "\n".join(re.sub(r'#.*', '', ln) for ln in open(f).read().splitlines())
    g = re.search(r'\$\{(BUILD_[A-Z0-9_]+)\}', code)
    # the ledger key this script pulls (clone_dep/build_cmake_dep/dep_version/dep_source KEY) —
    # used to look up the pinned version in deps.json. The FFmpeg --enable token often differs
    # from the ledger key (e.g. --enable-vaapi comes from libva.sh -> key "libva").
    km = re.search(r'\b(?:clone_dep|build_cmake_dep|dep_version|dep_source)\s+([a-z0-9][a-z0-9_-]*)', code)
    key = km.group(1) if km else None
    for tok in re.findall(r'--enable-([a-z0-9_-]+)', code):
        t = tok.replace("-", "_")
        if g: tok_build[t] = g.group(1)
        else: tok_uncond.add(t)
        if key: tok_dep.setdefault(t, key)   # first (sorted-order) owner wins, not "last file the glob visited"
# hwaccel/header rows whose version comes from a ledger header package that is enabled in
# 02_configure (not via a deps/*.sh --enable), so the scan above can't associate them.
tok_dep.setdefault("vulkan", "vulkan-headers")
tok_dep.setdefault("ffnvcodec", "nv-codec")
tok_dep.setdefault("amf", "amf")
tok_dep.setdefault("vaapi", "libva")     # VAAPI hwaccel is enabled in 02_configure; the lib is libva
tok_dep.setdefault("libvpl", "libvpl")   # QSV (oneVPL) dispatcher

# --- Ledger (deps.json): the exact pinned ref per dep, resolved override-else-default -----
import json as _json
DEPS = _json.load(open("deps.json"))
def dep_ref(key, major, rid=None):
    """The upstream ref this build pins for <key> on FFmpeg <major> / <rid>. An override wins over
    the default, but a platform-scoped override (with a "platforms" list) applies only on its RIDs."""
    if not key: return ""
    ov = (DEPS.get("overrides", {}).get(str(major), {}) or {}).get(key)
    if ov is not None and (ov.get("platforms") is None or (rid in (ov.get("platforms") or []))):
        d = ov
    else:
        d = DEPS.get("defaults", {}).get(key)
    if not d: return ""
    if d.get("tag"):    return d["tag"]
    if d.get("branch"): return "branch:" + d["branch"]
    if d.get("commit"): return d["commit"][:9]
    return ""

def enabled(tok, rid, cid):
    t = tok.replace("-", "_")
    s = sim[(rid, cid)]
    if t in s["hw"]: return True
    if t in tok_uncond: return True
    bv = tok_build.get(t)
    return bool(bv) and bv in s["flags"]

# --- Overlay (pure metadata; NEVER removes a row) -----------------------------
CAT = {
  "libx264":"video","libx265":"video","libopenh264":"video","libdav1d":"video",
  "libaom":"video","libsvtav1":"video","libvpx":"video","libkvazaar":"video",
  "liblcevc_dec":"video","liboapv":"video","librav1e":"video","libsvtjpegxs":"image",
  "libtheora":"video","libuavs3d":"video","libvvenc":"video","libxevd":"video",
  "libxevdb":"video","libxeve":"video","libxeveb":"video","libdavs2":"video",
  "libxavs":"video","libxavs2":"video","libxvid":"video","ohcodec":"video",
  "libopus":"audio","libmp3lame":"audio","libvorbis":"audio","libbs2b":"audio",
  "libcelt":"audio","libcodec2":"audio","libflite":"audio","libgme":"audio",
  "libgsm":"audio","libilbc":"audio","liblc3":"audio","libmodplug":"audio",
  "libopenmpt":"audio","libshine":"audio","libspeex":"audio","libtwolame":"audio",
  "libmysofa":"audio","librubberband":"audio","libsoxr":"audio",
  "libwebp":"image","libfreetype":"image","libfontconfig":"image","libass":"image",
  "libfribidi":"image","libharfbuzz":"image","cairo":"image","libaribcaption":"image",
  "libjxl":"image","libopenjpeg":"image","librsvg":"image","libtesseract":"image",
  "libzvbi":"image","libqrencode":"image",
  "libzimg":"proc","lcms2":"proc","libglslang":"proc","libopencolorio":"proc",
  "libopencv":"proc","libopenvino":"proc","libplacebo":"proc","libshaderc":"proc",
  "libtensorflow":"proc","libtorch":"proc","libvmaf":"proc","vapoursynth":"proc",
  "frei0r":"proc","libvidstab":"proc","ladspa":"proc","lv2":"proc","libsnappy":"proc",
  "libzmq":"proc","chromaprint":"proc",
  "openssl":"net","gnutls":"net","libtls":"net","librist":"net","librtmp":"net",
  "libsrt":"net","libssh":"net","libsmbclient":"net","librabbitmq":"net","gcrypt":"net",
  "schannel":"net","securetransport":"net",
  "whisper":"stt","pocketsphinx":"stt",
  "libbluray":"other","libcaca":"other","libdc1394":"other","libiec61883":"other",
  "libjack":"other","libklvanc":"other","libpulse":"other","libquirc":"other",
  "libv4l2":"other","libxml2":"other","openal":"other","opengl":"other",
  "libcdio":"other","libdvdnav":"other","libdvdread":"other","avisynth":"other",
  "vulkan_static":"other","jni":"other",
}
DESC = {
  "libx264":"x264 — H.264 encode","libx265":"x265 — H.265 encode",
  "libopenh264":"OpenH264 — H.264 encode","libdav1d":"dav1d — AV1 decode",
  "libaom":"libaom — AV1 enc/dec","libsvtav1":"SVT-AV1 — AV1 encode",
  "libvpx":"libvpx — VP8/VP9","libopus":"libopus — Opus","libmp3lame":"libmp3lame — MP3 encode",
  "libvorbis":"libvorbis — Vorbis","libwebp":"libwebp — WebP","libfreetype":"FreeType — drawtext",
  "libfontconfig":"fontconfig — font-by-name","libass":"libass — SSA/ASS subtitles",
  "libfribidi":"libfribidi — bidi text (drawtext)","libharfbuzz":"libharfbuzz — text shaping",
  "libzimg":"zimg — scaling/colorspace","whisper":"whisper.cpp — af_whisper ASR",
  "openssl":"OpenSSL — TLS/https","libsoxr":"SoX resampler",
  "libkvazaar":"Kvazaar — HEVC encoder","libvvenc":"vvenc — H.266/VVC encoder",
  "libtheora":"libtheora — Theora","libopenjpeg":"OpenJPEG — JPEG 2000",
  "libuavs3d":"uavs3d — AVS3 decode","liboapv":"OpenAPV — APV codec",
  "libxeve":"XEVE — MPEG-5 EVC encode","libxevd":"XEVD — MPEG-5 EVC decode",
  "libxevdb":"XEVD baseline — EVC decode","libxeveb":"XEVE baseline — EVC encode",
  "liblcevc_dec":"LCEVC decode","libsvtjpegxs":"SVT JPEG-XS","ohcodec":"OpenHarmony HW codec",
  "librav1e":"rav1e — AV1 encoder (Rust)","libdavs2":"davs2 — AVS2 decode",
  "libxavs":"xavs — AVS1 encode","libxavs2":"xavs2 — AVS2 encode","libxvid":"Xvid — MPEG-4 ASP",
  "libspeex":"Speex — speech","libgsm":"libgsm — GSM","libilbc":"iLBC — speech",
  "libcodec2":"Codec2 — low-bitrate speech","libtwolame":"TwoLAME — MP2 encode",
  "libshine":"Shine — fixed-point MP3","libopenmpt":"libopenmpt — tracker music",
  "libmodplug":"libmodplug — tracker music","libgme":"Game Music Emu","libcelt":"CELT — audio (legacy)",
  "libbs2b":"bs2b — stereo→binaural","libmysofa":"libmysofa — SOFA HRTF",
  "libflite":"Flite — speech synthesis","librubberband":"Rubber Band — time-stretch/pitch",
  "liblc3":"LC3 — Bluetooth audio","libaribcaption":"ARIB caption decode",
  "libzvbi":"libzvbi — teletext/VBI","librsvg":"librsvg — SVG rasterize",
  "libtesseract":"Tesseract — OCR","libqrencode":"libqrencode — QR encode",
  "cairo":"Cairo — vector rendering","lcms2":"Little CMS — color management",
  "libopencolorio":"OpenColorIO","libplacebo":"libplacebo — GPU processing",
  "libglslang":"glslang — shader compile","libshaderc":"shaderc — shader compile",
  "libopencv":"OpenCV — CV filters","libopenvino":"OpenVINO — DNN backend",
  "libtensorflow":"TensorFlow — DNN backend","libtorch":"LibTorch — DNN backend",
  "libvmaf":"libvmaf — VMAF quality metric","vapoursynth":"VapourSynth — frameserver",
  "frei0r":"frei0r — effect plugins","libvidstab":"vid.stab — stabilization",
  "ladspa":"LADSPA — audio plugins","lv2":"LV2 — audio plugins","libsnappy":"Snappy — HAP",
  "libzmq":"ZeroMQ — zmq/azmq filters","chromaprint":"Chromaprint — audio fingerprint",
  "gnutls":"GnuTLS — TLS/https","libtls":"libtls (LibreSSL) — TLS","librist":"RIST — reliable stream",
  "librtmp":"librtmp — RTMP","libsrt":"SRT — secure transport","libssh":"libssh — SFTP",
  "libsmbclient":"SMB/CIFS","librabbitmq":"RabbitMQ — AMQP","gcrypt":"libgcrypt — crypto",
  "pocketsphinx":"PocketSphinx — speech recognition","libbluray":"libbluray — Blu-ray input",
  "libcaca":"libcaca — ASCII-art output","libdc1394":"libdc1394 — IIDC cameras",
  "libiec61883":"FireWire capture","libjack":"JACK — audio I/O","libklvanc":"KLV/VANC",
  "libpulse":"PulseAudio — audio I/O","libquirc":"quirc — QR decode","libv4l2":"Video4Linux2",
  "libxml2":"libxml2 — DASH/IMF parse","openal":"OpenAL — audio capture","opengl":"OpenGL — output",
  "libcdio":"libcdio — CD input","libdvdnav":"libdvdnav — DVD nav","libdvdread":"libdvdread — DVD read",
  "avisynth":"AviSynth — frameserver","vulkan_static":"Vulkan (static ICD)","jni":"JNI (Android bridge)",
  "cuda":"CUDA","cuda_llvm":"CUDA (LLVM/NVVM)","cuvid":"CUVID (NVIDIA decode)",
  "nvenc":"NVENC (NVIDIA encode)","nvdec":"NVDEC (NVIDIA decode)","ffnvcodec":"ffnvcodec headers",
  "vaapi":"VAAPI","vdpau":"VDPAU","libdrm":"libdrm","v4l2_m2m":"V4L2-M2M","amf":"AMF (AMD)",
  "d3d11va":"D3D11VA","d3d12va":"D3D12VA","dxva2":"DXVA2","mediafoundation":"MediaFoundation",
  "videotoolbox":"VideoToolbox","audiotoolbox":"AudioToolbox","mediacodec":"MediaCodec (Android)",
  "vulkan":"Vulkan (filters + whisper GPU)","libvpl":"QSV (oneVPL)","libmfx":"QSV (MediaSDK, legacy)",
  "mmal":"MMAL (Raspberry Pi)","omx":"OpenMAX IL","opencl":"OpenCL",
  "schannel":"SChannel — TLS/https (OS-native)","securetransport":"SecureTransport — TLS/https (OS-native)",
}
APPLIES = {
  "cuda":LINUX|WIN,"cuda_llvm":LINUX|WIN,"cuvid":LINUX|WIN,"nvenc":LINUX|WIN,
  "nvdec":LINUX|WIN,"ffnvcodec":LINUX|WIN,"vaapi":LINUX,"vdpau":{"linux-x64"},
  "libdrm":LINUX,"v4l2_m2m":LINUX,"libvpl":LINUX|WIN,"libmfx":LINUX|WIN,
  "d3d11va":WIN,"d3d12va":WIN,"dxva2":WIN,"amf":WIN,"mediafoundation":WIN,
  "videotoolbox":APPLE,"audiotoolbox":MAC,"mediacodec":ANDROID,"vulkan":ALL,
  "mmal":LINUX,"omx":LINUX,"schannel":WIN,"securetransport":APPLE,
  "libsvtav1":ALL-{"linux-armhf","android-arm64","ios-arm64","ios-sim-arm64"},
  "libwebp":DESKTOP, "libfontconfig":LINUX|MAC,
}
TITLES = [("video","Video codecs"),("audio","Audio codecs"),
          ("image","Images / subtitles / text"),("proc","Processing"),
          ("stt","Speech-to-text"),("net","Networking / streaming / TLS"),
          ("hw","Hardware acceleration"),("other","Other / miscellaneous")]
DEFCAT = {"hw":"hw","lib":"other"}
SHORT = {"linux-x64":"lin-x64","linux-arm64":"lin-a64","linux-armhf":"lin-hf",
         "linux-musl-x64":"musl","win-x64":"win","osx-x64":"osx-x64",
         "osx-arm64":"osx-a64","android-arm64":"android","ios-arm64":"ios","ios-sim-arm64":"ios-sim"}

# Footnotes: rendered as GitHub [^ref] superscripts inline on the row, auto-listed
# and auto-numbered (by first appearance) at the bottom of the file.
FN_REF = {
  "d3d12va":"d3d12", "libfontconfig":"fontconfig", "libsvtav1":"svtav1", "libwebp":"webp",
  "openssl":"tls", "gnutls":"tls", "schannel":"tls", "securetransport":"tls",
}
FN_TEXT = {
  "tls": "TLS/https backend — depends on the license SERIES. v3 builds link OpenSSL 3.x "
         "(Apache-2.0, requires --enable-version3) on Linux/Android. The App-Store-safe v2 builds "
         "instead use GnuTLS on gpl-2 (its GMP/nettle deps are fine under GPLv2) and DROP TLS "
         "ENTIRELY on lgpl-2 (GMP/nettle are never LGPLv2.1 and no other backend is either). "
         "Windows uses SChannel and Apple uses SecureTransport (OS-native) in every series. All "
         "enable the `https`/`tls` protocols EXCEPT lgpl-2 on Linux/Android, which has no TLS.",
  "d3d12": "Not built: FFmpeg's `d3d12va` needs `ID3D12VideoDecoder` from `d3d12video.h`, which the "
           "mingw-w64 cross-toolchain doesn't ship (it has `d3d12.h` only). Windows hw decode is "
           "covered by D3D11VA + DXVA2.",
  "svtav1": "Needs 64-bit and a toolchain it cross-compiles under, so it is n/a on armhf and mobile. "
            "AV1 encode is still available via libaom.",
  "webp": "Image-only codec; not built on mobile (its CMake build ships no pkg-config file).",
  "fontconfig": "Off on Windows/Android/iOS (native DirectWrite/CoreText, or an explicit "
                "`fontfile=`); libass still renders via those providers.",
}

def parse_list(conf, name):
    m = re.search(name + r'="\n(.*?)\n"', conf, re.S)
    if not m: return []
    out = []
    for l in m.group(1).splitlines():
        s = l.strip()
        if not s or s.startswith(("$", "#")): continue
        mm = re.match(r"^([a-z0-9_]+)", s)
        if mm: out.append(mm.group(1))
    return out

def render(version, conf, cid):
    """Return (markdown, universe_set, gpl_set) for one FFmpeg version + license CELL
    (cid is one of gplv3 / gplv2 / lgplv3 / lgplv2)."""
    fam = "gpl" if cid.startswith("gpl") else "lgpl"
    major = version.split(".")[0]   # ledger overrides are keyed by FFmpeg major
    LABEL = {"gplv3":"GPLv3","gplv2":"GPLv2","lgplv3":"LGPLv3","lgplv2":"LGPLv2.1"}[cid]
    hw  = parse_list(conf, "HWACCEL_AUTODETECT_LIBRARY_LIST") + parse_list(conf, "HWACCEL_LIBRARY_LIST")
    ext = parse_list(conf, "EXTERNAL_LIBRARY_LIST")
    gpl = parse_list(conf, "EXTERNAL_LIBRARY_GPL_LIST")
    GPLSET = set(gpl)
    KIND = {}
    for t in ext + gpl: KIND[t] = "lib"
    for t in hw:        KIND[t] = "hw"
    for t in EXTRA:     KIND[t] = "hw"
    UNIVERSE = list(dict.fromkeys(hw + list(EXTRA) + ext + gpl))

    def cell(tok, rid):
        applies = APPLIES.get(tok, ALL)
        if rid not in applies: return "n/a"
        if rid == "ios-sim-arm64" and KIND.get(tok) == "lib" \
           and enabled(tok, "ios-arm64", cid) and not enabled(tok, "ios-sim-arm64", cid):
            return "n/a"
        if enabled(tok, rid, cid): return "✓"
        if fam == "lgpl" and tok in GPLSET: return "✗"   # GPL lib, can't go in an LGPL build
        return "—"

    used_fn = set()
    buckets = {key: [] for key, _ in TITLES}
    for tok in UNIVERSE:
        cat = CAT.get(tok) or DEFCAT[KIND.get(tok, "lib")]
        base = DESC.get(tok, tok)
        if tok in GPLSET and "(GPL)" not in base: base += " (GPL)"
        disp = base
        if tok in FN_REF:
            disp += f"[^{FN_REF[tok]}]"; used_fn.add(FN_REF[tok])
        cells = [cell(tok, r) for r in RIDS]
        buckets[cat].append((not ("✓" in cells), base.lower(), disp, cells, tok))
    for key in buckets: buckets[key].sort()

    L = []
    L.append(f"# FFmpeg {version} · {LABEL} — build coverage\n")
    L.append(f"_Auto-generated by `scripts/gen-matrix.sh` from FFmpeg n{version}'s `configure` and "
             f"the build scripts — do not edit by hand. Back to the [matrix index](README.md)._\n")
    legend = ("**✓** built · **n/a** not applicable on this platform · "
              "**—** FFmpeg supports it but we don't build it here (a choice — no license barrier)")
    if fam == "lgpl":
        legend += " · **✗** can't be included: GPL / conflicting license (use the GPL build instead)"
    L.append(legend + "\n")
    L.append("_The **Version** column is the exact upstream ref this build pins for that library — read "
             "from the ledger (`deps.json`), resolved for this FFmpeg major (an `overrides.<major>` hold "
             "wins over the default). It is the ref `clone_dep` checks out, so it is what actually "
             "compiles. Blank = an FFmpeg-internal or OS-native feature with no pinned dependency, or a "
             "row not built in this cell. A dep held back only for this line shows its held ref here and "
             "so differs from the sibling major's file; if a dep ever needed a different version per "
             "platform, the version would move into the per-platform cells instead._\n")
    L.append("_Always-on built-in decoders (H.264/H.265/VP8/VP9 decode, AAC, PCM, …) are compiled "
             "into every build and not listed. The iOS-simulator slice is lean — a library present "
             "on the iOS device slice but dropped there shows n/a._\n")
    L.append(f"_This is the **{LABEL}** cell — one of four ({{gplv3, gplv2, lgplv3, lgplv2}}); the "
             f"siblings are linked from the [matrix index](README.md). Cells differ in x264/x265 "
             f"(gpl) vs kvazaar (lgpl), and in the Apache-2.0 dependencies: **v3** links OpenSSL TLS "
             f"+ Vulkan, while **v2** uses GnuTLS (gpl) or NO TLS (lgpl) and drops Vulkan (Whisper → "
             f"CPU). Every cell ships DYNAMIC libraries — iOS as a dynamic-framework `.xcframework`._\n")
    hdr = "| Feature | Version | " + " | ".join(SHORT[r] for r in RIDS) + " |"
    sep = "|" + "---|"*(len(RIDS)+2)
    for key, title in TITLES:
        rows = buckets[key]
        if not rows: continue
        nb = sum(1 for r in rows if not r[0])
        L.append(f"\n### {title}  \n_{nb} of {len(rows)} built._\n")
        L.append(hdr); L.append(sep)
        for _, _, disp, cells, tok in rows:
            # the pinned dep version we build (ledger, resolved per platform). Blank when the row is
            # an FFmpeg-internal / OS-native feature, or not built in this cell (nothing to pin).
            key = tok_dep.get(tok.replace("-", "_"), "")
            pv = {i: dep_ref(key, major, RIDS[i]) for i, c in enumerate(cells) if c == "✓"}
            uniq = sorted({v for v in pv.values() if v})
            if len(uniq) <= 1:
                ver = uniq[0] if uniq else ""
                out_cells = cells
            else:
                # a platform-scoped override makes the version differ across platforms: put each
                # version in its own cell (in place of ✓) so the divergence shows where it happens
                ver = "per-platform ↓"
                out_cells = [(pv[i] or cells[i]) if cells[i] == "✓" else cells[i]
                             for i in range(len(cells))]
            L.append(f"| {disp} | {ver} | " + " | ".join(out_cells) + " |")
    if used_fn:
        L.append("")   # GitHub auto-numbers footnotes by first reference order
        for k in ["tls", "d3d12", "svtav1", "webp", "fontconfig"]:
            if k in used_fn:
                L.append(f"[^{k}]: {FN_TEXT[k]}")
    return "\n".join(L) + "\n", set(UNIVERSE), GPLSET

# --- Write one matrix file per major × license --------------------------------
os.makedirs(os.path.join(OUTDIR, "matrix"), exist_ok=True)
rendered = []   # (major, version, universe, gplset)  — universe/gpl are license-independent
for mj in MAJORS:
    version, conf = by_major[mj]
    uni = gplset = None
    for cid in ("gplv3", "gplv2", "lgplv3", "lgplv2"):
        body, uni, gplset = render(version, conf, cid)
        with open(os.path.join(OUTDIR, "matrix", f"ffmpeg-{mj}-{cid}.md"), "w", encoding="utf-8") as fh:
            fh.write(body)
    rendered.append((mj, version, uni, gplset))

# --- Write the index (per-license links + cross-version differences) ----------
uni_by_major = {r[0]: r[2] for r in rendered}
gpl_all = set().union(*[r[3] for r in rendered]) if rendered else set()
union = set().union(*[r[2] for r in rendered]) if rendered else set()

idx = []
idx.append("# Build coverage matrix\n")
idx.append("_Auto-generated by `scripts/gen-matrix.sh` — do not edit by hand._\n")
idx.append("Every library FFmpeg supports × every platform, **✓** where this repo builds it. Sliced "
           "per **maintained FFmpeg major** and per **license variant** — the gpl and lgpl builds "
           "differ (gpl has x264/x265; lgpl has kvazaar). Markers: **✓** built · **—** not built "
           "(a choice) · **✗** (lgpl) can't include for license reasons · **n/a** not applicable on "
           "the platform. Each cell file also carries a **Version** column — the exact upstream ref "
           "each built library is pinned to in the ledger (`deps.json`), resolved for that FFmpeg "
           "major — so a dep bump changes these files, not just an FFmpeg change.\n")
idx.append("**Four cells per FFmpeg major** — `gplv3` · `gplv2` · `lgplv3` · `lgplv2`. Family: gpl "
           "has x264/x265, lgpl has kvazaar (no x264/x265). Version: **v3** links the Apache-2.0 deps "
           "(OpenSSL TLS + Vulkan); **v2** (App-Store-safe) uses GnuTLS (gpl) or **no TLS** (lgpl) and "
           "drops Vulkan (Whisper → CPU). Every cell ships **dynamic** libraries, iOS as a "
           "dynamic-framework `.xcframework`. Open two cells side by side to see exactly what differs.\n")
idx.append("## Matrices\n")
for mj, _version, _, _ in rendered:
    # Major only — the exact point version lives in each per-major file's header, so
    # the index changes only when a major is added/removed, not on point bumps.
    idx.append(f"- **FFmpeg {mj}**: "
               f"[GPLv3](ffmpeg-{mj}-gplv3.md) · [GPLv2](ffmpeg-{mj}-gplv2.md) · "
               f"[LGPLv3](ffmpeg-{mj}-lgplv3.md) · [LGPLv2.1](ffmpeg-{mj}-lgplv2.md)")

if len(rendered) > 1:
    diff = sorted([t for t in union if t not in EXTRA
                   and any(t not in uni_by_major[m] for m in uni_by_major)],
                  key=lambda t: DESC.get(t, t).lower())
    idx.append("\n## Library support by FFmpeg version\n")
    if diff:
        idx.append("_Libraries FFmpeg added or removed between the maintained versions — check here "
                   "to see which version you need for a given library. Libraries present in every "
                   "maintained version are omitted._\n")
        idx.append("| Library | " + " | ".join(f"FFmpeg {m}" for m in MAJORS) + " |")
        idx.append("|" + "---|"*(len(MAJORS)+1))
        for t in diff:
            label = DESC.get(t, t)
            if t in gpl_all and "(GPL)" not in label: label += " (GPL)"
            cells = " | ".join("✓" if t in uni_by_major[m] else "—" for m in MAJORS)
            idx.append(f"| {label} | {cells} |")
    else:
        idx.append("_All maintained versions support the same set of libraries._")

with open(os.path.join(OUTDIR, "matrix", "README.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(idx) + "\n")

print("Wrote docs/matrix/README.md + " +
      ", ".join(f"matrix/ffmpeg-{m}-{{gplv3,gplv2,lgplv3,lgplv2}}.md" for m, *_ in rendered))
PY
rm -f "$simfile" "$MANIFEST_FILE"; rm -rf "$CONF_DIR"
