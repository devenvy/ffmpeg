#!/usr/bin/env bash
# Compare the full set of external libraries a given FFmpeg supports against what
# this repo actually enables, and print the gap. Used two ways:
#   - manually, to audit coverage;
#   - by check-updates.yml, to flag new libraries when FFmpeg is bumped.
#
# Usage:
#   scripts/gen-coverage.sh <version>        # downloads that FFmpeg's configure
#   scripts/gen-coverage.sh --configure PATH # uses a local configure file
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source the shared helpers for the retrying curl wrapper. These scripts fetch FFmpeg's
# configure over the network, and without it a DNS or TLS blip fails them outright: curl's own
# --retry does not cover connection-level errors (6 resolve, 7 connect, 35 TLS), which is what
# actually goes wrong on a CI runner. lib.sh defines wrappers only; nothing runs on source.
# shellcheck source=scripts/lib.sh
. "${ROOT_DIR}/scripts/lib.sh"

if [[ "${1:-}" == "--configure" ]]; then
  CONF_FILE="$2"
else
  VER="${1:?usage: gen-coverage.sh <version> | --configure <path>}"
  CONF_FILE="$(mktemp)"
  curl -fsSL \
    "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n${VER}/configure" -o "${CONF_FILE}" \
    || curl -fsSL "https://raw.githubusercontent.com/FFmpeg/FFmpeg/refs/tags/n${VER}/configure" -o "${CONF_FILE}"
fi

PYBIN="$(resolve_python)"
"${PYBIN}" - "${CONF_FILE}" "${ROOT_DIR}" <<'PY'
import sys, re, glob, os
conf = open(sys.argv[1]).read(); root = sys.argv[2]
blocks = re.findall(r'(\w*(?:LIBRARY|HWACCEL)\w*_LIST)="\n(.*?)\n"', conf, re.S)
universe = {}
for name, body in blocks:
    items = [m.group(1) for l in body.splitlines()
             if (s:=l.strip()) and not s.startswith(('$','#'))
             and (m:=re.match(r'^([a-z0-9_]+)', s))]
    universe.setdefault(name, []).extend(items)

ours = set()
for f in glob.glob(f"{root}/scripts/deps/*.sh") + glob.glob(f"{root}/scripts/steps/*.sh"):
    ours |= {m.replace('-', '_') for m in re.findall(r'--enable-([a-z0-9_-]+)', open(f).read())}

groups = [
  ("permissive/LGPL-safe libraries", "EXTERNAL_LIBRARY_LIST"),
  ("GPL libraries", "EXTERNAL_LIBRARY_GPL_LIST"),
  ("hardware accel (autodetect)", "HWACCEL_AUTODETECT_LIBRARY_LIST"),
]
skip = {"avfoundation","xlib","zlib","bzlib","lzma","iconv","sndio","sdl2"}  # noise/built-in-ish
any_gap = False
for title, key in groups:
    items = sorted(set(universe.get(key, [])) - skip)
    have = [i for i in items if i in ours]
    miss = [i for i in items if i not in ours]
    print(f"\n## {title} — {len(have)}/{len(items)} enabled")
    if miss:
        any_gap = True
        print("not enabled: " + ", ".join(miss))
print("\n" + ("Gaps exist — review whether any are worth enabling." if any_gap else "Full coverage."))
PY
