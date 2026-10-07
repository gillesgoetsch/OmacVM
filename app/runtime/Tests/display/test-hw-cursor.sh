#!/bin/bash
# The guest's pointer as the Mac's cursor (omacvm-cocoa-hw-cursor-logic.patch):
# the patch makes ui/omacvm-hw-cursor.h in an empty folder, and
# test-hw-cursor.c runs against it. No QEMU, no display. CI and the runtime
# build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hw-cursor.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hw-cursor-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-hw-cursor.c" -o "$work/test-hw-cursor" -lm
"$work/test-hw-cursor"
