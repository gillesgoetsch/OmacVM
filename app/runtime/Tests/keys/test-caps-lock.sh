#!/bin/bash
# The guest's Caps Lock follows the Mac's (#784,
# omacvm-cocoa-caps-lock-logic.patch, omacvm-cocoa-caps-lock.patch,
# omacvm-virtio-input-leds-reset.patch): the patch makes ui/omacvm-capslock.h
# in an empty folder and test-caps-lock.c runs the report's case, the guards and
# random runs against a model guest (LED reports only on a change, the keyboard's
# start and reset as patched), and QEMU's old rule, which must fail the report
# and Shift + Caps Lock. In the repo (CI): also that the app gives QEMU exactly
# one keyboard (the LED mask is read from the first). With ui/cocoa.m as
# argument (the runtime build, after the wiring patches): also that the LED
# notifier feeds it, every input event goes through it, and the virtio keyboard
# reports its start and reset.
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

# One keyboard for QEMU: qemu_input_get_leds_mask(dcl.con) reads the first one.
runner=$here/../../../app/Sources/OmacVM/Runner.swift
if [[ -f $runner ]]; then
  kbds=$(grep -oE '"(virtio-keyboard|usb-kbd|virtio-input-host|i8042|ps2-kbd|virtio-keyboard-device)[^"]*"' "$runner" | sort | uniq -c)
  [[ $(awk '{n += $1} END {print n}' <<<"$kbds") == 1 && $kbds == *'"virtio-keyboard-pci,romfile="' ]] ||
    { echo "test-caps-lock: $runner: QEMU must get exactly one keyboard (virtio-keyboard-pci), found: $kbds" >&2; exit 1; }
  echo "ok   one keyboard for QEMU (virtio-keyboard-pci, Runner.swift)"
elif (( ! $# )); then
  echo "test-caps-lock: no $runner" >&2; exit 1
fi

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
grep -q '^QEMU_BUILD_BUG_ON(OMACVM_CAPS_LED != QEMU_CAPS_LOCK_LED);' "$m" || fail "the Caps Lock LED bit is not checked against QEMU's"
tr -s ' \n' ' ' < "$m" | grep -qF "static void omacvm_caps_led_changed(Notifier *notifier, void *data) { omacvm_caps_leds(&omacvm_caps, qemu_input_get_leds_mask(dcl.con), qemu_clock_get_ms(QEMU_CLOCK_REALTIME)); }" ||
  fail "the guest's LED reports (the whole mask) do not reach the Caps Lock rules"
tr -s ' \n' ' ' <<<"$handle" | grep -qF "if (!omacvm_caps_listening) { omacvm_caps_start(&omacvm_caps, qemu_input_get_leds_mask(dcl.con)); qemu_input_led_notifier_add(&omacvm_caps_led_notifier); omacvm_caps_listening = true; }" ||
  fail "the LED notifier is not added once, from the LEDs as they are"
tr -s ' \n' ' ' <<<"$handle" | grep -qF 'if (omacvm_caps_step(&omacvm_caps, !!(modifiers & NSEventModifierFlagCapsLock), qkbd_state_modifier_get(kbd, QKBD_MOD_SHIFT), qemu_clock_get_ms(QEMU_CLOCK_REALTIME))) { qkbd_state_key_event(kbd, KEY_CAPSLOCK, true); qkbd_state_key_event(kbd, KEY_CAPSLOCK, false); }' ||
  fail "the Caps Lock press is not decided by omacvm_caps_step from the flag, the guest's Shift and the time"
[[ $(grep -c 'omacvm_caps_step(' "$m") == 1 ]] || fail "omacvm_caps_step is not called exactly once"
[[ $(grep -c 'qemu_input_led_notifier_add(&omacvm_caps_led_notifier)' "$m") == 1 ]] || fail "the LED notifier is added more than once"
# Once per input event: after the event-type filter, before the other modifiers.
awk '!f && /case NSEventTypeMagnify:/{f=NR} /omacvm_caps_step\(/{c=NR} /\[self omacvmSyncModifiers:event\];/{s=NR}
     END{exit !(f && c > f && s > c)}' <<<"$handle" || fail "the Caps Lock check is not between the input filter and the modifiers"
# A keyboard's start is reported with its LEDs, a reset one reports no LED lit
# (omacvm-virtio-input-leds-reset.patch), keyboards only.
v=$(dirname "$m")/../hw/input/virtio-input-hid.c
[[ -f $v ]] || fail "no hw/input/virtio-input-hid.c beside it"
active=$(awk '/^static void virtio_input_hid_change_active\(VirtIOInput \*vinput\)$/ {on=1} on {print} on && /^}$/ {exit}' "$v")
tr -s ' \n' ' ' <<<"$active" | perl -pe 's#/\*.*?\*/##g' | tr -s ' ' |
  grep -qF 'if (vinput->active) { qemu_input_handler_activate(vhid->hs); if (vhid->handler->mask & INPUT_EVENT_MASK_KEY) { qemu_input_handler_set_leds_mask(vhid->hs, vhid->ledstate); } } else { if ((vhid->handler->mask & INPUT_EVENT_MASK_KEY) && vhid->ledstate) { vhid->ledstate = 0; qemu_input_handler_set_leds_mask(vhid->hs, 0); } qemu_input_handler_deactivate(vhid->hs); }' ||
  fail "a virtio keyboard's start is not reported, or a reset one keeps its old LEDs ($v)"
echo "test-caps-lock: $m: wiring ok"
