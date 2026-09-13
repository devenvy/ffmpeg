#!/usr/bin/env bash
# Dispatcher — runs the right per-platform test for a build's RID.
# The release/CI workflow calls this after each build:
#   scripts/test.sh <RID> <artifact-native-dir>
# Per-platform logic lives in scripts/test/<platform>.sh; shared helpers in
# scripts/test/lib.sh. Each test does structural checks always, and functional
# checks when the target can be executed (natively, or via Wine/QEMU).
set -uo pipefail
RID="${1:?usage: test.sh <RID> <artifact-native-dir>}"
DIR="${2:?usage: test.sh <RID> <artifact-native-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$RID" in
  linux-*)   exec bash "${HERE}/test/linux.sh"   "$RID" "$DIR" ;;
  win-*)     exec bash "${HERE}/test/win.sh"     "$RID" "$DIR" ;;
  android-*) exec bash "${HERE}/test/android.sh" "$RID" "$DIR" ;;
  osx-*)     exec bash "${HERE}/test/macos.sh"   "$RID" "$DIR" ;;
  # Catalyst ships the same per-library .framework layout as iOS, so it shares ios.sh
  # (which branches internally on arch, Mach-O platform and how it compiles the smoke
  # program). Matched before ios-* would be irrelevant -- the prefixes do not overlap --
  # but it is listed next to it to keep the family together.
  ios-*)     exec bash "${HERE}/test/ios.sh"     "$RID" "$DIR" ;;
  maccatalyst-*) exec bash "${HERE}/test/ios.sh" "$RID" "$DIR" ;;
  *) echo "test.sh: unknown RID '$RID'" >&2; exit 2 ;;
esac
