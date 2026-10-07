#!/bin/bash
# The guest's size, picked so Omarchy's scale presets fit
# (omacvm-cocoa-clean-size-logic.patch): the patch makes
# ui/omacvm-clean-size.h in an empty folder, and test-clean-size.c runs
# against it. No QEMU, no display. CI and the runtime build run it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-clean-size.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-clean-size-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-clean-size.c" -o "$work/test-clean-size"
"$work/test-clean-size"
