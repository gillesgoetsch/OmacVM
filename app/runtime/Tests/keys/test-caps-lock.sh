#!/bin/bash
# The guest's Caps Lock follows the Mac's (#784,
# omacvm-cocoa-caps-lock-logic.patch, omacvm-cocoa-caps-lock.patch): the patch
# makes ui/omacvm-capslock.h in an empty folder and test-caps-lock.c runs the
# report's case, the guards and a random run against a model guest, and QEMU's
# old rule, which must fail the report. With ui/cocoa.m as argument (the
# runtime build, after the wiring patch): also that the LED notifier feeds it
# and every input event goes through it.
#   test-caps-lock.sh                       (CI)
#   test-caps-lock.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-caps-lock.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-caps-lock-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-caps-lock.c" -o "$work/t"
"$work/t"

(( $# )) || exit 0
m=$1
fail() { echo "test-caps-lock: $m: $*" >&2; exit 1; }
body() { awk -v h="$1" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$m"; }
handle=$(body '- (bool) handleEventLocked:(NSEvent *)event')
[[ -n $handle ]] || fail "handleEventLocked is missing"
grep -q '#include "ui/omacvm-capslock.h"' "$m" || fail "ui/omacvm-capslock.h is not used"
grep -q "^static OmacVMCaps omacvm_caps;" "$m" || fail "no state for the Caps Lock rules"
# QEMU's own count of its presses decides nothing any more.
! grep -q 'QKBD_MOD_CAPSLOCK' <<<"$handle" || fail "the press still follows QEMU's own record (QKBD_MOD_CAPSLOCK)"
# The LED notifier feeds the guest's LED; the Mac's flag and the time decide; one press and release come out.
grep -q '^static Notifier omacvm_caps_led_notifier = {' "$m" && grep -q '    .notify = omacvm_caps_led_changed' "$m" ||
  fail "no LED notifier for the Caps Lock rules"
led='omacvm_caps_led(&omacvm_caps, qemu_input_get_leds_mask(dcl.con) & QEMU_CAPS_LOCK_LED, qemu_clock_get_ms(QEMU_CLOCK_REALTIME));'
tr -s ' \n' ' ' < "$m" | grep -qF "static void omacvm_caps_led_changed(Notifier *notifier, void *data) { $led }" ||
  fail "the guest's LED reports do not reach the Caps Lock rules"
tr -s ' \n' ' ' <<<"$handle" | grep -qF "if (!omacvm_caps_listening) { $led qemu_input_led_notifier_add(&omacvm_caps_led_notifier); omacvm_caps_listening = true; }" ||
  fail "the LED notifier is not added once, from the LED as it is"
tr -s ' \n' ' ' <<<"$handle" | grep -qF 'if (omacvm_caps_step(&omacvm_caps, !!(modifiers & NSEventModifierFlagCapsLock), qemu_clock_get_ms(QEMU_CLOCK_REALTIME))) { qkbd_state_key_event(kbd, KEY_CAPSLOCK, true); qkbd_state_key_event(kbd, KEY_CAPSLOCK, false); }' ||
  fail "the Caps Lock press is not decided by omacvm_caps_step from the flag and the time"
[[ $(grep -c 'omacvm_caps_step(' "$m") == 1 ]] || fail "omacvm_caps_step is not called exactly once"
[[ $(grep -c 'qemu_input_led_notifier_add(&omacvm_caps_led_notifier)' "$m") == 1 ]] || fail "the LED notifier is added more than once"
# Once per input event: after the event-type filter, before the other modifiers.
awk '!f && /case NSEventTypeMagnify:/{f=NR} /omacvm_caps_step\(/{c=NR} /\[self omacvmSyncModifiers:event\];/{s=NR}
     END{exit !(f && c > f && s > c)}' <<<"$handle" || fail "the Caps Lock check is not between the input filter and the modifiers"
# A reset keyboard reports no LED lit (omacvm-virtio-input-leds-reset.patch), keyboards only.
v=$(dirname "$m")/../hw/input/virtio-input-hid.c
[[ -f $v ]] || fail "no hw/input/virtio-input-hid.c beside it"
active=$(awk '/^static void virtio_input_hid_change_active\(VirtIOInput \*vinput\)$/ {on=1} on {print} on && /^}$/ {exit}' "$v")
tr -s ' \n' ' ' <<<"$active" | perl -pe 's#/\*.*?\*/##g' | tr -s ' ' |
  grep -qF '} else { if ((vhid->handler->mask & INPUT_EVENT_MASK_KEY) && vhid->ledstate) { vhid->ledstate = 0; qemu_input_handler_set_leds_mask(vhid->hs, 0); } qemu_input_handler_deactivate(vhid->hs); }' ||
  fail "a reset virtio keyboard keeps its old LEDs ($v)"
echo "test-caps-lock: $m: wiring ok"
