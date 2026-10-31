#!/bin/bash
# Full-grab tap takes no modifier events (#357, omacvm-cocoa-tap-no-flags.patch):
# kCGEventFlagsChanged is left out of the full-grab tap mask so modifier changes
# (Shift, Control, Option, Command) flow through the normal AppKit sendEvent path
# without being deleted from the system stream. macOS global monitors (such as
# WeChat Input / WeType single-Shift switching) receive flagsChanged copies.
#   test-tap-no-flags.sh                       (CI: mask from the patch)
#   test-tap-no-flags.sh <patched ui/cocoa.m>  (the runtime build: also the wiring)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-tap-no-flags.XXXXXX")
trap 'rm -rf "$work"' EXIT
fn='CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);'
if [[ $# -ge 1 ]]; then
  m=$1
else
  patch_file="$patches/omacvm-cocoa-tap-no-flags.patch"
  [[ -f $patch_file ]] || { echo "FAIL omacvm-cocoa-tap-no-flags.patch is missing"; exit 1; }
  grep -qF "+    $fn" "$patch_file" || { echo "FAIL expected mask line not in patch"; exit 1; }
  if grep -qE '^\+.*kCGEventFlagsChanged' "$patch_file"; then echo "FAIL patch still adds kCGEventFlagsChanged"; exit 1; fi
fi

cat > "$work/test.c" << 'C_EOF'
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <assert.h>

int main(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    assert(mask == 0x0c00);
    assert((mask & CGEventMaskBit(kCGEventKeyDown)) != 0);
    assert((mask & CGEventMaskBit(kCGEventKeyUp)) != 0);
    assert((mask & CGEventMaskBit(kCGEventFlagsChanged)) == 0);
    printf("ok   full-grab tap mask excludes kCGEventFlagsChanged (0x%llx)\n", (unsigned long long)mask);
    return 0;
}
C_EOF

cc -Wall -Wextra -Werror "$work/test.c" -framework ApplicationServices -o "$work/t"
"$work/t"

(( $# )) || exit 0
fail() { echo "test-tap-no-flags: $m: $*" >&2; exit 1; }

body() { awk -v h="$1" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$m"; }
grab=$(body '- (void) setFullGrab:(id)sender')
[[ -n $grab ]] || fail "setFullGrab is missing"

grep -qF "$fn" <<<"$grab" || fail "setFullGrab does not set mask without flagsChanged"
if grep -q 'kCGEventFlagsChanged' <<<"$grab"; then fail "setFullGrab still references kCGEventFlagsChanged"; fi
grep -q 'eventsTap = CGEventTapCreate(kCGHIDEventTap, place, kCGEventTapOptionDefault,' <<<"$grab" &&
  grep -q 'mask, handleTapEvent, self);' <<<"$grab" || fail "eventsTap does not use mask"

echo "test-tap-no-flags: $m: wiring ok"
