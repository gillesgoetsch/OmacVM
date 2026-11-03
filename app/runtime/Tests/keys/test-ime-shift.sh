#!/bin/bash
# mac-ime: Shift also goes on to macOS while an input method has the keys
# (#357; omacvm-cocoa-ime-shift-logic.patch, omacvm-cocoa-ime-shift.patch).
# The rules: the logic patch and mac-ime's (omacvm-cocoa-ime-logic.patch) make
# their headers in an empty folder and test-ime-shift.c runs a table, real
# CGEvents, copies that differ and the orders against them. The wiring in
# ui/cocoa.m: the tap still takes every modifier change first (its mask),
# decides before handleEvent, passes on only what the rules say after the VM
# had it; handleEvent takes the copy first and gives it to the input method
# only, and omacvm_ime_key gives a due Shift before any other key.
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
count() { [[ $(grep -cF -- "$2" "$src" || true) -eq $3 ]] && ok "$1" || bad "$1 (want $3 lines with '$2')"; }

# The tap: decides before handleEvent, says what it hands over, a passed Shift
# is returned (after the VM took it) and anything else the VM took deleted.
d1='    bool omacvm_pass = type == kCGEventFlagsChanged && omacvm_ime_on && [view isKeyboardCaptured] &&'
d2='                       omacvm_ime_shift_will_pass(cgEvent);'
s1='    omacvm_ime_tap_now = omacvm_pass ? OMACVM_IME_TAP_SHIFT : OMACVM_IME_TAP_KEY;'
hv='    bool omacvm_took = [view isKeyboardCaptured] && [view handleEvent:event];'
s0='    omacvm_ime_tap_now = OMACVM_IME_TAP_NONE;'
tk='    if (omacvm_took) {'
tap=$(awk -v c="$d1" '$0 == c {on=1} on {print} on && /^    }$/ {exit}' "$src")
a=$(line "$tap" "$d1"); b=$(line "$tap" "$d2"); c=$(line "$tap" "$s1"); h=$(line "$tap" "$hv"); z=$(line "$tap" "$s0")
t=$(line "$tap" "$tk"); p=$(line "$tap" '        if (omacvm_pass) {'); m=$(line "$tap" '            omacvm_ime_shift_to_macos(cgEvent);')
r=$(line "$tap" '            return cgEvent;'); n=$(line "$tap" '        return NULL;')
[[ -n $a && -n $b && -n $c && -n $h && -n $z && -n $t && -n $p && -n $m && -n $r && -n $n &&
   $b == $(( a + 1 )) && $c == $(( b + 1 )) && $h == $(( c + 1 )) && $z == $(( h + 1 )) && $t == $(( z + 1 )) &&
   $p == $(( t + 1 )) && $m == $(( p + 1 )) && $r == $(( m + 1 )) && $n -gt $r ]] &&
  ok "the tap: decides before handleEvent; a passed Shift goes on after the VM took it, else deleted as before" ||
  bad "the tap's decision, handleEvent and the pass branch are not in that order"
count "omacvm_ime_shift_will_pass: declared, defined, the tap" 'omacvm_ime_shift_will_pass(' 3
count "omacvm_ime_shift_to_macos: declared, defined, the tap" 'omacvm_ime_shift_to_macos(' 3
count "the tap says what it hands over, and nothing else sets it" 'omacvm_ime_tap_now = ' 2

# handleEvent: the copy first, before anything else looks at it.
he=$(body "$src" '- (bool) handleEvent:(NSEvent *)event')
first=$(sed -n '3,4p' <<<"$he" | { grep -vE '^ +/\*' || true; } | head -1)
[[ $first == '    if (omacvm_ime_on && omacvm_ime_shift_back(event)) {' ]] &&
  [[ $({ grep -A1 -xF "$first" <<<"$he" || true; } | tail -1) == '        return true;' ]] &&
  ok "handleEvent: the copy that comes back never reaches the VM" || bad "handleEvent does not take the copy first"
count "omacvm_ime_shift_back: declared, defined, handleEvent" 'omacvm_ime_shift_back(' 3

will=$(body "$src" 'static bool omacvm_ime_shift_will_pass(CGEventRef cgEvent)')
has "the rules get mac-ime's state now and its off delay" "$will" '&omacvm_ime, omacvm_ime_off.waiting);'
has "... the window's key state first, as omacvm_ime_key" "$will" 'omacvm_ime.window_key = omacvm_ime_window_key();'
has "... and the off switch" "$will" 'omacvm_ime_shift_mode_now != OMACVM_IME_SHIFT_OFF,'
to=$(body "$src" 'static void omacvm_ime_shift_to_macos(CGEventRef cgEvent)')
has "an event that goes on is remembered with the time now" "$to" 'omacvm_ime_shift_sent(&omacvm_ime_shift, i, key, flags, omacvm_ime_shift_now(), due);'
has "... a copy kept while the input method is due it" "$to" 'omacvm_ime_shift_ev[i] = due ? CGEventCreateCopy(cgEvent) : NULL;'
has "... only with OMACVM_IME_SHIFT on (skip: never to the input method)" "$to" 'bool due = omacvm_ime_shift_mode_now == OMACVM_IME_SHIFT_ON;'
has "... a slot still due goes to the input method first" "$to" 'omacvm_ime_shift_give(i, nil);'
back=$(body "$src" 'static bool omacvm_ime_shift_back(NSEvent *event)')
has "the copy: only from the app's queue, only a flagsChanged" "$back" 'if (omacvm_ime_tap_now != OMACVM_IME_TAP_NONE || [event type] != NSEventTypeFlagsChanged) {'
has "... told by key code and the NSEvent's flags" "$back" 'i = omacvm_ime_shift_copy(&omacvm_ime_shift, key, (uint64_t)[event modifierFlags], now);'
has "... older ones due first, then the copy to the input method" "$back" 'omacvm_ime_shift_flush_before(omacvm_ime_shift.sent[i].seq, false);'
has "... the copy itself" "$back" 'what = omacvm_ime_shift_give(i, event);'
grep -qE 'CGEvent\]|CGEventGetTimestamp|handleEventLocked' <<<"$back" &&
  bad "the copy is read from its CGEvent or time stamp, or reaches the VM" ||
  ok "... never from its CGEvent or time stamp, never to the VM"
give=$(body "$src" 'static const char *omacvm_ime_shift_give(int i, NSEvent *event)')
has "the input method gets it with omacvm_ime_key's check" "$give" 'if (event && (omacvm_ime_active(&omacvm_ime) || omacvm_ime_off.waiting)) {'
grep -q 'handleEventLocked' <<<"$give" && bad "omacvm_ime_shift_give sends to the VM" || ok "... never to the VM"
key=$(body "$src" 'static bool omacvm_ime_key(NSEvent *event)')
(( full )) || key=$(cat "$src")    # the patch has only the parts it changes
fl=$(num -xF '    omacvm_ime_shift_flush(omacvm_ime_tap_now == OMACVM_IME_TAP_SHIFT);' <<<"$key")
fb=$(num -xF '    if (kt == OMACVM_IME_FLAGS) {' <<<"$key")
[[ -n $fl && -n $fb && $fl -lt $fb ]] && ok "omacvm_ime_key: what the input method is due goes before every key" ||
  bad "omacvm_ime_key does not give the due Shift first"
has "... a Shift that goes on is not given to the input method in the tap" "$key" '        if (active && !later) {'
has "... later = the tap hands over a Shift that goes on" "$key" '        bool later = omacvm_ime_tap_now == OMACVM_IME_TAP_SHIFT;'
init=$(body "$src" 'static void omacvm_ime_init(void)')
(( full )) || init=$(cat "$src")   # the patch has only the end of omacvm_ime_init
has "OMACVM_IME_SHIFT is read (0 off, skip a test)" "$init" 'omacvm_ime_shift_mode_now = omacvm_ime_shift_mode(getenv("OMACVM_IME_SHIFT"));'
has "... and qemu.log says which" "$init" 'cocoa: mac-ime: Shift also goes to macOS while an input method has the keys: %s'

if (( full )); then
  # The tap still takes every modifier change first (the VM's order), and the
  # Touch ID panel and the escape combo still go past it before anything else.
  grab=$(body "$src" '- (void) setFullGrab:(id)sender')
  has "the full-grab tap still takes modifier changes (its mask)" "$grab" 'CGEventMaskBit(kCGEventFlagsChanged);'
  cb=$(body "$src" 'static CGEventRef handleTapEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent, void *userInfo)')
  t=$(num -F 'if (omacvm_touchid_up) {' <<<"$cb"); e=$(num -F 'if (omacvm_is_escape_combo(' <<<"$cb")
  c=$(line "$cb" "$d1"); b=$(line "$cb" "$hv")
  [[ -n $t && -n $e && -n $c && -n $b && $t -lt $e && $e -lt $c && $c -lt $b ]] &&
    ok "... Touch ID's panel and the escape combo go past it first, as before" ||
    bad "the tap's order (Touch ID, escape combo, the VM, the pass branch) changed"
  [[ $(grep -c 'omacvm_ime_shift_mode_now = ' "$src" || true) -eq 1 ]] && ok "the off switch is set in one place" ||
    bad "omacvm_ime_shift_mode_now is not set in exactly one place"
fi
exit $fail
