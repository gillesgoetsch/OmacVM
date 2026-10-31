#!/bin/bash
# "USB Devices…" in the app menu (omacvm-cocoa-usb-menu.patch).
#   test-usb-menu.sh                the header's rules (the patch's ui/omacvm-usb-menu.h in an empty
#                                   folder, test-usb-menu.c) and the patch's own cocoa.m lines. No QEMU,
#                                   no display: CI and the runtime build run it.
#   test-usb-menu.sh --qemu QEMU    then also a QEMU of a runtime (an app's
#                                   Contents/Resources/runtime/bin/OmacVM): hidden (no window, no Dock
#                                   icon), no disk, CPUs stopped (a ramfb display: cocoa needs a
#                                   graphic console), its menu items pressed through
#                                   Accessibility on its own pid (no input events), with "Features…"
#                                   as the control (it proves the menu can be reached):
#                                     with OMACVM_USB_REQUEST: "USB Devices…" is there, each press
#                                     posts its name once and nothing under Features…'s name;
#                                     without it: no "USB Devices…", Features… still there.
#                                   A runtime without the patch fails. Needs Accessibility for this
#                                   shell; every wait has a limit, the QEMUs are stopped at the end.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
patch_file=$patches/omacvm-cocoa-usb-menu.patch
QEMU=""
while (( $# )); do
  case $1 in
    --qemu) QEMU=$2; shift 2 ;;
    *) sed -n '2,16s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-usb-menu.XXXXXX")
QPID=""
stop_qemu() { [[ -n $QPID ]] && { kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; }; QPID=""; }
trap 'stop_qemu; rm -rf "$work"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- the header (only its part of the patch)
awk '/^diff --git /{on = ($0 ~ /ui\/omacvm-usb-menu\.h/)} on' "$patch_file" > "$work/header.patch"
patch -s -d "$work" -p1 -f -i "$work/header.patch" || { echo "FAIL the patch has no ui/omacvm-usb-menu.h"; exit 1; }
cc -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -I"$work/ui" "$here/test-usb-menu.c" -o "$work/test-usb-menu" ||
  { echo "FAIL test-usb-menu.c does not build"; exit 1; }
if r=$("$work/test-usb-menu"); then ok "header: $r"; else echo "$r"; bad "header rules"; fi

# --- the patch's cocoa.m lines
added=$(awk '/^diff --git /{on = ($0 ~ / b\/ui\/cocoa\.m$/)} on' "$patch_file")
# The item goes right under Features… in the app menu (create_initial_menus).
[[ $(grep -A1 '^ *    omacvm_add_features_item(menu);$' <<<"$added" | tail -1) == '+    omacvm_add_usb_item(menu);' ]] &&
  ok "the item is added right under Features…" || bad "omacvm_add_usb_item(menu) is not right under omacvm_add_features_item(menu)"
[[ $(grep -c 'omacvm_add_usb_item(menu);' <<<"$added") == 1 ]] && ok "added in one place" || bad "omacvm_add_usb_item is called more than once"
# No item without the name.
item=$(awk '/^\+static void omacvm_add_usb_item\(NSMenu \*menu\)$/{on=1} on{print} on&&/^\+}$/{exit}' <<<"$added")
[[ $(sed -n 3p <<<"$item") == '+    if (!omacvm_usb_request()) {' && $(sed -n 4p <<<"$item") == '+        return;'* ]] &&
  ok "no item without OMACVM_USB_REQUEST" || bad "omacvm_add_usb_item does not return first without OMACVM_USB_REQUEST"
# The click: activation handed to the app before the name is posted, only to the app the name names.
open=$(awk '/^\+@implementation OmacvmUSBItem$/{on=1} on{print} on&&/^\+@end$/{exit}' <<<"$added")
y=$(grep -n 'yieldActivationToApplication:app' <<<"$open" | cut -d: -f1); p=$(grep -n 'postNotificationName:' <<<"$open" | cut -d: -f1)
[[ -n $y && -n $p ]] && (( y < p )) && ok "activation yielded before the name is posted" || bad "no yield before postNotificationName in open:"
grep -q 'omacvm_usb_is_launcher(name, \[\[app bundleIdentifier\] UTF8String\])' <<<"$open" &&
  ok "yielded only to the app with the name's bundle id" || bad "the yield does not check the bundle id"

# --- a QEMU of the runtime, hidden
if [[ -n $QEMU ]]; then
  [[ -x $QEMU ]] || { echo "FAIL no QEMU at $QEMU"; exit 1; }
  xcrun swiftc -O "$here/usb-menu-tool.swift" -o "$work/usb-menu-tool" > "$work/tool.log" 2>&1 ||
    { cat "$work/tool.log"; echo "FAIL usb-menu-tool.swift does not build"; exit 1; }
  T=$work/usb-menu-tool
  fname="org.omacvm.test.usb-menu.features.$$"; uname="org.omacvm.test.usb-menu.usb.$$"
  MSG=""
  start() {   # with|without: a hidden QEMU with Features…'s name, and USB's when "with" (sets QPID; MSG why not)
    local i
    stop_qemu
    if [[ $1 == with ]]; then
      env OMACVM_COCOA_HIDDEN=1 OMACVM_FEATURES_REQUEST="$fname" OMACVM_USB_REQUEST="$uname" "$QEMU" -machine virt -accel hvf \
        -cpu host -m 128 -nodefaults -device ramfb -S -display cocoa -serial none -monitor none -name usb-menu-test > "$work/qemu-$1.log" 2>&1 &
    else
      env -u OMACVM_USB_REQUEST OMACVM_COCOA_HIDDEN=1 OMACVM_FEATURES_REQUEST="$fname" "$QEMU" -machine virt -accel hvf \
        -cpu host -m 128 -nodefaults -device ramfb -S -display cocoa -serial none -monitor none -name usb-menu-test > "$work/qemu-$1.log" 2>&1 &
    fi
    QPID=$!
    for ((i = 0; i < 30; i++)); do   # 15 s: its menu is built at the start
      kill -0 "$QPID" 2>/dev/null || { MSG="QEMU ended: $(tail -3 "$work/qemu-$1.log" | tr '\n' ' ')"; return 1; }
      [[ $("$T" items "$QPID" 2>/dev/null | grep -c '^Features…$') -ge 1 ]] && return 0
      sleep 0.5
    done
    MSG="no Features… item in 15 s: $("$T" items "$QPID" 2>&1 | head -3 | tr '\n' ' ')"; return 1
  }
  if start with; then
    ok "QEMU $QPID with OMACVM_USB_REQUEST: Features… in its menu (Accessibility reaches it)"
    r=$("$T" press "$QPID" "Features…" 1 "$fname" "$uname")
    [[ $r == "Features…: pressed 1; $fname: 1; $uname: 0" ]] && ok "control: $r" || bad "control: $r"
    r=$("$T" press "$QPID" "USB Devices…" 2 "$uname" "$fname")
    [[ $r == "USB Devices…: pressed 2; $uname: 2; $fname: 0" ]] && ok "with the name: $r" || bad "with the name: $r"
  else bad "QEMU with OMACVM_USB_REQUEST: $MSG"; fi
  if start without; then
    items=$("$T" items "$QPID")
    [[ $(grep -c '^USB Devices…$' <<<"$items") == 0 ]] && ok "without the name: no USB Devices… ($(grep -c . <<<"$items") items)" ||
      bad "without the name: USB Devices… is in the menu"
    r=$("$T" press "$QPID" "Features…" 1 "$fname" "$uname")
    [[ $r == "Features…: pressed 1; $fname: 1; $uname: 0" ]] && ok "without the name, control: $r" || bad "without the name, control: $r"
  else bad "QEMU without OMACVM_USB_REQUEST: $MSG"; fi
  stop_qemu
fi
(( fails == 0 )) && echo "usb menu: all ok" || echo "usb menu: $fails FAIL"
(( fails == 0 ))
