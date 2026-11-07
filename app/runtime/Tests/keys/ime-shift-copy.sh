#!/bin/bash
# mac-ime: the real copy of a passed Shift (#357; ime-shift-copy.m). Local
# only, not in CI: it needs an active HID tap (Accessibility), an unlocked
# screen, and it brings a small window to the front and posts Shift presses
# at the HID level for about 3 s. So it refuses while a person may be at the
# Mac: HID idle under 60 s (--force skips that check, for a person running
# it on purpose).
#   ime-shift-copy.sh [--force]
# Exit 0 ok, 1 FAIL, 2 skipped (the reason is printed).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
if [[ ${1:-} != --force ]]; then
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ && !n {n = 1; print int($NF / 1000000000)}')
  (( ${idle:-0} >= 60 )) || { echo "SKIP someone may be at this Mac (HID idle $idle s < 60; --force to run anyway)"; exit 2; }
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ime-shift-copy.XXXXXX")
trap 'rm -rf "$work"' EXIT
for p in omacvm-cocoa-ime-logic.patch omacvm-cocoa-ime-shift-logic.patch; do
  patch -s -d "$work" -p1 -f -i "$patches/$p"
done
cc -fobjc-arc -Wall -Wextra -Werror -I"$work/ui" "$here/ime-shift-copy.m" \
  -framework AppKit -framework ApplicationServices -framework Carbon -o "$work/t"
"$work/t"
