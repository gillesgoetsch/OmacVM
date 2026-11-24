#!/bin/bash
# The VM's touch screen, only on a Mac with a touch display (#843):
# - a touch display is a HID device whose DeviceUsagePairs say touch screen
#   (Digitizer 0x0D, usage 0x04; a trackpad's say touch pad, 0x0D/0x05);
# - the Touch display switch (experimental, off by default) and one: QEMU
#   gets the virtio-multitouch device, last of all its arguments (no other
#   device moves), and OMACVM_TOUCH=1 for its window; else nothing, and 0;
# - the settings row shows only on a Mac with one (or while it is on);
# - OMACVM_TOUCH_SCREEN=1 or 0 decides it whatever the switch and the Mac say;
# - the device is the one QEMU's window looks for (omacvm-cocoa-touch.patch),
#   and qemu.log says what this start did.
# No VM, no settings touched.
#   src/tests/app-touch-display.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
func b(_ s: String) -> Bool? { s == "1" ? true : s == "0" ? false : nil }
switch a[1] {
case "rule":    // PAGE:USAGE ... (hex), or "none" (no such property), or "text" (not a list)
  let pairs: Any? = a[2] == "none" ? nil : a[2] == "text" ? "touch screen" as Any :
    a[2...].map { p -> Any in
      let n = p.split(separator: ":").map { Int($0, radix: 16)! }
      return ["DeviceUsagePage": NSNumber(value: n[0]), "DeviceUsage": NSNumber(value: n[1])] as [String: Any]
    } as [Any]
  print(TouchDisplay.isTouchScreen(usagePairs: pairs) ? "touch screen" : "no")
case "forced":  // the variable's value, or - for unset
  let f = TouchDisplay.forced(a[2] == "-" ? [:] : ["OMACVM_TOUCH_SCREEN": a[2]])
  print(f.map { $0 ? "with" : "without" } ?? "the Mac's own")
case "start":   // SETTING(1|0) FORCED(1|0|-) CONNECTED(1|0): the arguments, OMACVM_TOUCH, the record, and whether the display was asked
  var asked = false
  let on = TouchDisplay.wanted(setting: a[2] == "1", forced: b(a[3]), connected: { asked = true; return a[4] == "1" })
  print(TouchDisplay.arguments(on: on).joined(separator: " ") + "|" + TouchDisplay.environment(on: on) + "|" +
        TouchDisplay.record(on: on, setting: a[2] == "1", forced: b(a[3])) + (asked ? "" : "|not asked"))
case "row":     // SETTING(1|0) CONNECTED(1|0)
  print(TouchDisplay.shown(setting: a[2] == "1", connected: { a[3] == "1" }) ? "shown" : "hidden")
case "now":
  print(TouchDisplay.connected() ? "a touch display" : "none")
default: exit(2)
}
SWIFT
if ! swiftc -O -o "$T/t" "$R/app/app/Sources/OmacVM/TouchDisplay.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
  cat "$T/swiftc.log"; echo "FAIL TouchDisplay.swift does not compile on its own"; exit 1
fi

# Which devices count (the pairs as macOS 27 shows them in the IORegistry).
expect "the touch display (touch screen and a vendor pair)" "touch screen" "$("$T/t" rule d:4 ff00:23)"
expect "the built-in trackpad (mouse, pointer, touch pad, vendor pairs)" no "$("$T/t" rule 1:2 1:1 d:5 ff00:c)"
expect "a keyboard" no "$("$T/t" rule 1:6)"
expect "a pen digitizer (0x0D, 0x02)" no "$("$T/t" rule d:2)"
expect "usage 4 on another page" no "$("$T/t" rule 1:4)"
expect "a device without the property" no "$("$T/t" rule none)"
expect "a property that is no list" no "$("$T/t" rule text)"

# The switch.
expect "OMACVM_TOUCH_SCREEN unset: the Mac's own" "the Mac's own" "$("$T/t" forced -)"
expect "OMACVM_TOUCH_SCREEN=1: with" with "$("$T/t" forced 1)"
expect "OMACVM_TOUCH_SCREEN=0: without" without "$("$T/t" forced 0)"
expect "OMACVM_TOUCH_SCREEN=yes: the Mac's own" "the Mac's own" "$("$T/t" forced yes)"

# What a start does.
dev="-device virtio-multitouch-pci,romfile="
on="on (Touch display, experimental: taps, scrolling and a pinch's two fingers go to the VM)"
expect "switch off (the default), a touch display: nothing, the display not even asked" \
  "|0|off (the Touch display switch is off)|not asked" "$("$T/t" start 0 - 1)"
expect "switch on, a touch display: the VM gets a touch screen, QEMU's window the touches" "$dev|1|$on" "$("$T/t" start 1 - 1)"
expect "switch on, no touch display: nothing (the VM as before)" "|0|off (no touch display on this Mac)" "$("$T/t" start 1 - 0)"
expect "switch off, but OMACVM_TOUCH_SCREEN=1: a touch screen" "$dev|1|on (OMACVM_TOUCH_SCREEN=1)|not asked" "$("$T/t" start 0 1 0)"
expect "switch on and one, but OMACVM_TOUCH_SCREEN=0: nothing" "|0|off (OMACVM_TOUCH_SCREEN=0)|not asked" "$("$T/t" start 1 0 1)"

# The settings row: only on a Mac with a touch display, or while it is on.
expect "row: no touch display, switch off: hidden" hidden "$("$T/t" row 0 0)"
expect "row: a touch display: shown" shown "$("$T/t" row 0 1)"
expect "row: switch on (a VM from another Mac): shown, to switch it off" shown "$("$T/t" row 1 0)"
echo "info this Mac now: $("$T/t" now)"

# The wiring.
run=$R/app/app/Sources/OmacVM/Runner.swift
chk() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
after() { local a b; a=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1); [[ -n $a && -n $b ]] && (( a < b )); }
chk "the touch screen is the last of QEMU's devices (no other device moves)" \
  after "$run" 'a = DropPlan.finish(arguments: a,' 'return a + TouchDisplay.arguments(on: touchScreen)'
chk "decided at each start, from the switch" grep -qF 'touchScreen = TouchDisplay.wanted(setting: touchSetting)' "$run"
chk "QEMU's window takes touches only with it (OMACVM_TOUCH)" grep -qF 'env["OMACVM_TOUCH"] = TouchDisplay.environment(on: touchScreen)' "$run"
chk "qemu.log says what this start did" grep -qF 'OmacVM: touch screen: \(TouchDisplay.record(on: touchScreen, setting: touchSetting))' "$run"
chk "the switch is off by default (a plain UserDefaults bool)" grep -qF 'get { UserDefaults.standard.bool(forKey: TouchDisplay.key) }' "$R/app/app/Sources/OmacVM/Model.swift"
chk "the row is in the settings, shown by TouchDisplay.shown" grep -qF 'TouchDisplay.shown(setting:' "$R/app/app/Sources/OmacVM/SettingsView.swift"
chk "QEMU's window looks for the same device (omacvm-cocoa-touch.patch)" \
  grep -qF 'object_resolve_path_type("", "virtio-multitouch-device", NULL)' "$R/app/runtime/patches/omacvm-cocoa-touch.patch"
exit $fail
