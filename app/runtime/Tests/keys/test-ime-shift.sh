#!/bin/bash
# mac-ime: Shift also goes on to macOS while an input method has the keys
# (#357; omacvm-cocoa-ime-shift-logic.patch, omacvm-cocoa-ime-shift.patch).
# The rules: the logic patch and mac-ime's (omacvm-cocoa-ime-logic.patch) make
# their headers in an empty folder and test-ime-shift.c runs a table, real
# CGEvents and the copies against them. The wiring in ui/cocoa.m: the tap
# still takes every modifier change first (its mask), passes on only what the
# rules say after the VM had it, and handleEvent drops the copy first.
#   test-ime-shift.sh                       (CI: the wiring from the patch)
#   test-ime-shift.sh <patched ui/cocoa.m>  (the runtime build: the whole file)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ime-shift.XXXXXX")
trap 'rm -rf "$work"' EXIT
for p in omacvm-cocoa-ime-logic.patch omacvm-cocoa-ime-shift-logic.patch; do
  [[ -f $patches/$p ]] || { echo "FAIL $p is missing"; exit 1; }
  patch -s -d "$work" -p1 -f -i "$patches/$p"
done
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$work/ui" \
  "$here/test-ime-shift.c" -framework ApplicationServices -o "$work/t" -lm
"$work/t"

full=0
if [[ $# -ge 1 ]]; then
  src=$1
  full=1
else
  [[ -f $patches/omacvm-cocoa-ime-shift.patch ]] || { echo "FAIL omacvm-cocoa-ime-shift.patch is missing"; exit 1; }
  # The patch's new side: context and added lines, without the removed ones.
  src=$work/new.m
  awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' \
    "$patches/omacvm-cocoa-ime-shift.patch" > "$src"
fi
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1"; fi; }
num() { { grep -n "$@" || true; } | head -1 | cut -d: -f1; }   # first matching line's number, or nothing
line() { num -xF -- "$2" <<<"$1"; }

grep -qxF '#include "ui/omacvm-ime-shift.h"' "$src" && ok "ui/omacvm-ime-shift.h is used" ||
  bad "ui/omacvm-ime-shift.h is not included"

# The tap: the pass branch inside "the VM took it", right before its NULL.
cap='    if ([view isKeyboardCaptured] && [view handleEvent:event]) {'
br='        if (type == kCGEventFlagsChanged && omacvm_ime_on && omacvm_ime_shift_to_macos(cgEvent)) {'
tap=$(awk -v c="$cap" '$0 == c {on=1} on {print} on && /^    }$/ {exit}' "$src")
c=$(line "$tap" "$cap"); b=$(line "$tap" "$br"); n=$(line "$tap" '        return NULL;')
r=$(line "$tap" '            return cgEvent;')
between=$(sed -n "$(( ${c:-1} + 1 )),$(( ${b:-1} - 1 ))p" <<<"$tap" | grep -vE '^ +(/\*|\*)' || true)
[[ -n $c && -n $b && -n $n && -n $r && $b -gt $c && $r == $(( b + 1 )) && $n -gt $r && -z $between ]] &&
  ok "the tap: a Shift the VM took goes on (returned) only by the rules, else deleted as before" ||
  bad "the tap's pass branch is not right after 'the VM took it' and before its NULL"
[[ $(grep -cF 'omacvm_ime_shift_to_macos(' "$src" || true) -eq 3 ]] &&
  ok "... the only call (declaration, definition, the tap)" || bad "omacvm_ime_shift_to_macos is not declared, defined and called once each (the tap)"

# handleEvent: the copy first, before anything else looks at it.
he=$(body "$src" '- (bool) handleEvent:(NSEvent *)event')
first=$(sed -n '3,4p' <<<"$he" | { grep -vE '^ +/\*' || true; } | head -1)
[[ $first == '    if (omacvm_ime_on && omacvm_ime_shift_back(event)) {' ]] &&
  [[ $({ grep -A1 -xF "$first" <<<"$he" || true; } | tail -1) == '        return true;' ]] &&
  ok "handleEvent: the copy that comes back is dropped first" || bad "handleEvent does not drop the copy first"
[[ $(grep -cF 'omacvm_ime_shift_back(' "$src" || true) -eq 3 ]] &&
  ok "... the only call (declaration, definition, handleEvent)" || bad "omacvm_ime_shift_back is not declared, defined and called once each (handleEvent)"

# The tap's side reads the event as the rules expect and remembers it.
to=$(body "$src" 'static bool omacvm_ime_shift_to_macos(CGEventRef cgEvent)')
has "the rules get mac-ime's state now and its off delay" "$to" '&omacvm_ime, omacvm_ime_off.waiting)) {'
has "... and the off switch" "$to" 'flags, !omacvm_ime_shift_off,'
p=$(num -F 'omacvm_ime_shift_pass(' <<<"$to"); s=$(num -F 'omacvm_ime_shift_sent(&omacvm_ime_shift, CGEventGetTimestamp(cgEvent), key);' <<<"$to")
[[ -n $p && -n $s && $s -gt $p ]] && ok "an event that goes on is remembered (time stamp, key code)" ||
  bad "an event that goes on is not remembered after the rules"
back=$(body "$src" 'static bool omacvm_ime_shift_back(NSEvent *event)')
has "the copy: only a flagsChanged" "$back" '[event type] != NSEventTypeFlagsChanged'
has "... told by its time stamp and key code" "$back" 'omacvm_ime_shift_again(&omacvm_ime_shift, CGEventGetTimestamp(cgEvent), [event keyCode])'
init=$(body "$src" 'static void omacvm_ime_init(void)')
(( full )) || init=$(cat "$src")   # the patch has only the end of omacvm_ime_init
has "OMACVM_IME_SHIFT=0 turns it off" "$init" 'omacvm_ime_shift_off = getenv("OMACVM_IME_SHIFT") && !strcmp(getenv("OMACVM_IME_SHIFT"), "0");'
has "... and qemu.log says which" "$init" 'cocoa: mac-ime: Shift also goes to macOS while an input method has the keys: %s'

if (( full )); then
  # The tap still takes every modifier change first (the VM's order), and the
  # Touch ID panel and the escape combo still go past it before anything else.
  grab=$(body "$src" '- (void) setFullGrab:(id)sender')
  has "the full-grab tap still takes modifier changes (its mask)" "$grab" 'CGEventMaskBit(kCGEventFlagsChanged);'
  cb=$(body "$src" 'static CGEventRef handleTapEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent, void *userInfo)')
  t=$(num -F 'if (omacvm_touchid_up) {' <<<"$cb"); e=$(num -F 'if (omacvm_is_escape_combo(' <<<"$cb")
  c=$(line "$cb" "$cap"); b=$(line "$cb" "$br")
  [[ -n $t && -n $e && -n $c && -n $b && $t -lt $e && $e -lt $c && $c -lt $b ]] &&
    ok "... Touch ID's panel and the escape combo go past it first, as before" ||
    bad "the tap's order (Touch ID, escape combo, the VM, the pass branch) changed"
  [[ $(grep -c 'omacvm_ime_shift_off = ' "$src" || true) -eq 1 ]] && ok "the off switch is set in one place" ||
    bad "omacvm_ime_shift_off is not set in exactly one place"
fi
exit $fail
