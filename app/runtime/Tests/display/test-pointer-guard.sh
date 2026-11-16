#!/bin/bash
# The full-screen pointer guard's maths (omacvm-cocoa-pointer-guard.patch):
# the patch makes ui/omacvm-pointer-guard.h in an empty folder, and
# test-pointer-guard.c runs against it. No QEMU, no display. CI and the
# runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-guard.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-pointer-guard.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-pointer-guard.c" -lm -o "$work/test-pointer-guard"
"$work/test-pointer-guard"
# ui/cocoa.m detaches the cursor before the hold's first warp: an attached
# cursor pushed against an edge moves off the warp's target in between (#788).
order=$(awk '/^\+static void omacvm_guard_apply/ { on = 1 }
  on && /CGAssociateMouseAndMouseCursorPosition\(false\)/ { print "detach" }
  on && /CGWarpMouseCursorPosition/ { print "warp" }
  on && /^\+}/ { exit }' "$patches/omacvm-cocoa-fullscreen-edges.patch" | tr '\n' ' ')
if [[ $order != "detach warp " ]]; then
  echo "FAIL omacvm_guard_apply: order '$order', expected 'detach warp '"
  exit 1
fi
echo "test-pointer-guard: apply order ok (detach, then warp)"
