#!/bin/bash
# "Restart the Desktop…" in the app menu (omacvm-cocoa-restart-desktop.patch):
# the patch's ui/omacvm-desktop-restart.h goes into an empty folder, and
# test-restart-desktop.c runs against it. No QEMU, no display. CI and the
# runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-restart-desktop.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Only the header's part of the patch (the rest changes ui/cocoa.m).
awk '/^diff --git /{on = ($0 ~ /ui\/omacvm-desktop-restart\.h/)} on' \
  "$patches/omacvm-cocoa-restart-desktop.patch" > "$work/header.patch"
patch -s -d "$work" -p1 -f -i "$work/header.patch"
cc -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-restart-desktop.c" -o "$work/test-restart-desktop"
mkdir "$work/logs"
"$work/test-restart-desktop" "$work/logs"
