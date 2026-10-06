#!/bin/bash
# OmacVM.app's "Magic Mouse swipe" setting (3 or 4 fingers, default 4):
# - it lives in OmacVM Gestures' settings domain under the key Gestures reads
#   (MouseSwipeFingers); 3 is 3, anything else counts as 4, as in Gestures;
# - a Magic Mouse is found by Apple's multitouch family 112 or an Apple
#   product id 0x030d, 0x0269, 0x0323 (as Gestures finds it);
# - the row shows in the setup and the VM window only with a Magic Mouse
#   (drawn to PNGs in OUT_DIR, light and dark, from a fixture home; nothing
#   opens on screen, the real home, VMs and settings are not touched).
# A throwaway settings domain, no VM.
#   src/tests/app-mouse-swipe.sh [OUT_DIR]
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
OUT=${1:-$T/png}; mkdir -p "$OUT"
D=org.omacvm.test.mouse-swipe.$$
BIN=omacvm-mouse-swipe-render
trap 'defaults delete "$D" >/dev/null 2>&1; defaults delete "$BIN" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$D.plist"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
switch a[1] {
case "get":   // DOMAIN [set N]
  let d = UserDefaults(suiteName: a[2])!
  if a.count > 4 { MouseSwipeSetting.set(Int(a[4])!, d) }
  print(MouseSwipeSetting.current(d))
case "rule":  // vendor product family (- = none)
  let n = { (s: String) in s == "-" ? nil : Int(s, radix: 16) }
  print(MagicMouse.isMagicMouse(vendor: n(a[2]), product: n(a[3]), family: a[4] == "-" ? nil : Int(a[4])) ? "mouse" : "no")
case "now":
  print(MagicMouse.connected() ? "connected" : "none")
default: exit(2)
}
SWIFT
swiftc -module-cache-path "$T/mc" -o "$T/t" "$R/app/app/Sources/OmacVM/MouseSwipeSetting.swift" \
  "$R/app/app/Sources/OmacVM/EscapeSetting.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL MouseSwipeSetting.swift does not compile on its own"; exit 1; }

# The setting.
expect "mouse swipe: never chosen: 4 fingers" 4 "$("$T/t" get "$D")"
expect "3 chosen: 3" 3 "$("$T/t" get "$D" set 3)"
expect "... read back" 3 "$("$T/t" get "$D")"
expect "stored as a number, as Gestures reads it" 3 "$(defaults read "$D" MouseSwipeFingers)"
expect "4 chosen: 4" 4 "$("$T/t" get "$D" set 4)"
"$T/t" get "$D" set 5 >/dev/null
expect "anything else chosen (5): stored as 4" 4 "$(defaults read "$D" MouseSwipeFingers)"
defaults write "$D" MouseSwipeFingers 3
expect "written by hand as text \"3\": 3 (Gestures too)" 3 "$("$T/t" get "$D")"
for v in "-int 5" "-int 0" "-float 3.5" "three" "-bool true"; do
  defaults write "$D" MouseSwipeFingers $v
  expect "written by hand as $v: 4" 4 "$("$T/t" get "$D")"
done
# Gestures reads the same key in the same domain.
grep -q 'CFSTR("MouseSwipeFingers"), GESTURES_DOMAIN' "$R/src/gestures/mac/omacvm-gestures.c" &&
  grep -q 'static let key = "MouseSwipeFingers"' "$R/app/app/Sources/OmacVM/MouseSwipeSetting.swift" &&
  grep -q 'appDomain' "$R/app/app/Sources/OmacVM/MouseSwipeSetting.swift" &&
  echo "ok   the app and Gestures use the same domain and key" || { echo "FAIL the app and Gestures use another domain or key"; fail=1; }

# Which devices count.
expect "Magic Mouse 2 over Bluetooth (004c:0269)" mouse "$("$T/t" rule 4c 269 -)"
expect "Magic Mouse (05ac:030d)" mouse "$("$T/t" rule 5ac 30d -)"
expect "Magic Mouse USB-C (004c:0323)" mouse "$("$T/t" rule 4c 323 -)"
expect "multitouch family 112, no ids" mouse "$("$T/t" rule 0 0 112)"
expect "built-in trackpad (family 111)" no "$("$T/t" rule 5ac 8104 111)"
expect "Magic Trackpad (004c:0265)" no "$("$T/t" rule 4c 265 -)"
expect "another vendor's 0x0269" no "$("$T/t" rule 46d 269 -)"
echo "info this Mac now: $("$T/t" now) (not checked: the mouse may be off)"

# The row in the windows, drawn.
H=$T/home
mkdir -p "$H/OmacVM/Omarchy/logs"
printf "NAME='Omarchy'\nCPUS=4\nMEM_MB=8192\nDISK_GB=64\nSSH_PORT=52222\nVM_USER='me'\n" > "$H/OmacVM/Omarchy/vm.env"
: > "$H/OmacVM/Omarchy/disk.img"; : > "$H/OmacVM/Omarchy/efi-vars.fd"; : > "$H/OmacVM/Omarchy/ready"
# The app's own modules first (as SwiftPM builds them), then its sources with
# this test's main instead of the app's.
mkdir -p "$T/mods"
for m in OmacVMUpdate OmacVMNet OmacVMUSB OmacVMFolder OmacVMFeatures OmacVMBuildProgress OmacVMWindow; do
  swiftc -swift-version 5 -parse-as-library -module-cache-path "$T/mc" -module-name $m -emit-module \
    -emit-module-path "$T/mods/$m.swiftmodule" -emit-library -static -o "$T/lib$m.a" "$R"/app/app/Sources/$m/*.swift ||
    { echo "FAIL $m does not build"; exit 1; }
done
srcs=()
for f in "$R"/app/app/Sources/OmacVM/*.swift; do
  case $(basename "$f") in main.swift|RenderUpdateUI.swift) ;; *) srcs+=("$f") ;; esac   # the app's main and its own render mode
done
swiftc -swift-version 5 -module-cache-path "$T/mc" -I "$T/mods" -L "$T" -lOmacVMUpdate -lOmacVMNet -lOmacVMUSB -lOmacVMFolder -lOmacVMFeatures -lOmacVMBuildProgress -lOmacVMWindow -o "$T/$BIN" \
  "${srcs[@]}" "$R/src/tests/app-mouse-swipe/main.swift" || { echo "FAIL the render test does not build"; exit 1; }
HOME=$H CFFIXED_USER_HOME=$H OMACVM_RESOURCES=$R/app "$T/$BIN" "$OUT" || fail=1
echo "PNGs: $OUT"
exit $fail
