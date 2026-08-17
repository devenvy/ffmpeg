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
  win-*)     exec bash "${HERE}/test/win.sh"            "$DIR" ;;
  android-*) exec bash "${HERE}/test/android.sh"        "$DIR" ;;
  osx-*)     exec bash "${HERE}/test/macos.sh"   "$RID" "$DIR" ;;
  ios-*)     exec bash "${HERE}/test/ios.sh"     "$RID" "$DIR" ;;
  *) echo "test.sh: unknown RID '$RID'" >&2; exit 2 ;;
esac
