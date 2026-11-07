#!/bin/bash
# OmacVM.app's prebuilt, signed Mac helpers (src/lib/helpers.sh): apply and
# update install the app's copy only when it was built from the same sources
# as the OmacVM that installs it, and build one otherwise (a source checkout
# without the app, another version). Also src/mac/install.sh's use of it, with
# a made-up home, stand-in installers and a stand-in launchctl: nothing is
# installed, no LaunchAgent is touched, the Mac's helpers stay as they are.
#   src/tests/prebuilt-helpers.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d /tmp/omacvm-helpers.XXXXXX)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
source "$R/src/lib/helpers.sh"

# A made-up OmacVM.app: src/ as committed and two "helpers" (signed ad hoc).
APP=$T/Apps/OmacVM.app
mkdir -p "$APP/Contents/Resources/omacvm" "$APP/Contents/Helpers"
cp -R "$R/src" "$APP/Contents/Resources/omacvm/src"
rm -rf "$APP/Contents/Resources/omacvm/src/bridge/mac/build" "$APP/Contents/Resources/omacvm/src/gestures/mac/build" \
  "$APP/Contents/Resources/omacvm/src/omanotch/mac/build"
fake_helper() {   # NAME.app ID
  local b=$APP/Contents/Helpers/$1
  mkdir -p "$b/Contents/MacOS"
  cp /usr/bin/true "$b/Contents/MacOS/helper"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>helper</string></dict></plist>' "$2" > "$b/Contents/Info.plist"
  codesign --force --sign - --identifier "$2" "$b" 2>/dev/null
}
fake_helper OmacVMBridge.app org.omacvm.bridge
fake_helper OmacVMGestures.app org.omacvm.gestures
fake_helper Omanotch.app ch.gillesgoetsch.omanotch
IN=$APP/Contents/Resources/omacvm/src
H=$(cd "$APP/Contents/Helpers" && pwd)

expect "the app's own src/: its Bridge" "$H/OmacVMBridge.app" "$(helpers_prebuilt "$IN" bridge/mac OmacVMBridge.app)"
expect "the app's own src/: its Gestures" "$H/OmacVMGestures.app" "$(helpers_prebuilt "$IN" gestures/mac OmacVMGestures.app)"
# apply-vm.sh runs a copy of the app's src/ and points at the app's Helpers.
cp -R "$IN" "$T/copy"
expect "a copy of it (apply-vm.sh): not found without OMACVM_HELPERS" "" "$(helpers_prebuilt "$T/copy" bridge/mac OmacVMBridge.app)"
expect "... found with OMACVM_HELPERS" "$H/OmacVMBridge.app" "$(OMACVM_HELPERS=$H helpers_prebuilt "$T/copy" bridge/mac OmacVMBridge.app)"
# A source checkout of another version: built here.
cp -R "$IN" "$T/other"
echo "// another version" >> "$T/other/bridge/mac/keys.swift"
expect "other Bridge sources: built here" "" "$(OMACVM_HELPERS=$H helpers_prebuilt "$T/other" bridge/mac OmacVMBridge.app)"
expect "... Gestures unchanged there: the app's" "$H/OmacVMGestures.app" "$(OMACVM_HELPERS=$H helpers_prebuilt "$T/other" gestures/mac OmacVMGestures.app)"
echo "x" >> "$T/other/lib/sign.sh"
expect "... the signing script changed: built here too" "" "$(OMACVM_HELPERS=$H helpers_prebuilt "$T/other" gestures/mac OmacVMGestures.app)"
# A build folder from an earlier local build does not count as a change.
mkdir -p "$T/copy/bridge/mac/build/x" && touch "$T/copy/bridge/mac/build/x/junk"
expect "a local build/ folder is no change" "$H/OmacVMBridge.app" "$(OMACVM_HELPERS=$H helpers_prebuilt "$T/copy" bridge/mac OmacVMBridge.app)"
# A helper whose signature no longer holds: never installed.
cp -R "$APP" "$T/Broken.app"
printf 'x' >> "$T/Broken.app/Contents/Helpers/OmacVMBridge.app/Contents/MacOS/helper"
expect "a broken signature: built here" "" "$(OMACVM_HELPERS=$T/Broken.app/Contents/Helpers helpers_prebuilt "$T/Broken.app/Contents/Resources/omacvm/src" bridge/mac OmacVMBridge.app)"
expect "no Helpers anywhere: built here" "" "$(OMACVM_HELPERS=$T/none helpers_prebuilt "$T/copy" bridge/mac OmacVMBridge.app | grep -v "^$T/Apps" || true)"
expect "the team of an ad hoc copy" "adhoc" "$(helpers_team "$H/OmacVMBridge.app")"
expect "the team of nothing" "" "$(helpers_team "$T/nothing.app")"

# src/mac/install.sh with stand-ins: which installer call it makes.
S=$T/run/src; mkdir -p "$T/run" "$T/home" "$T/bin"
cp -R "$IN" "$S"
for d in bridge/mac gestures/mac omanotch/mac; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$d" "$T" > "$S/$d/install.sh"; chmod +x "$S/$d/install.sh"
done
# The stand-ins are part of the helpers' sources: the app's copy gets the same.
for d in bridge/mac gestures/mac omanotch/mac; do cp "$S/$d/install.sh" "$IN/$d/install.sh"; done
printf '#!/bin/bash\nexit 1\n' > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"   # nothing installed, nothing running
run() { rm -f "$T/calls"; HOME=$T/home PATH=$T/bin:$PATH OMACVM_HELPERS=$1 "$S/mac/install.sh" --quiet >/dev/null 2>&1; cat "$T/calls" 2>/dev/null; }
calls=$(run "$H")
expect "install.sh: the Bridge from the app" "bridge/mac --prebuilt $H/OmacVMBridge.app" "$(grep ^bridge <<<"$calls")"
expect "install.sh: Gestures from the app" "gestures/mac --prebuilt $H/OmacVMGestures.app" "$(grep ^gestures <<<"$calls")"
rm -f "$T/calls"
HOME=$T/home PATH=$T/bin:$PATH OMACVM_HELPERS=$H "$S/mac/install.sh" --omanotch --quiet >/dev/null 2>&1
expect "install.sh --omanotch: Omanotch from the app" "omanotch/mac --prebuilt $H/Omanotch.app" "$(grep ^omanotch "$T/calls")"
calls=$(run "$T/none")
expect "install.sh without the app: built here" "bridge/mac " "$(grep ^bridge <<<"$calls")"
rm -f "$T/calls"
HOME=$T/home PATH=$T/bin:$PATH OMACVM_HELPERS=$H "$S/mac/install.sh" --keys-only --quiet >/dev/null 2>&1
expect "install.sh --keys-only: the app's Gestures, keys only" "gestures/mac --prebuilt $H/OmacVMGestures.app --keys-only" "$(grep ^gestures "$T/calls")"

# The Bridge runs from ~/Applications, never from the app's Helpers: macOS
# charges Bluetooth, the camera and the microphone of a helper inside an app
# to that app, and killed a Bridge started in place right after it asked for
# Bluetooth (OS_REASON_TCC: the app had no NSBluetoothAlwaysUsageDescription).
b=$R/src/bridge/mac/install.sh
expect "the Bridge is installed as a copy in ~/Applications" "1" \
  "$(grep -c '^ditto "$APP" "$HOME/Applications/OmacVMBridge.app"$' "$b")"
expect "its LaunchAgent runs that copy" "1" \
  "$(grep -c '<string>$HOME/Applications/OmacVMBridge.app/Contents/MacOS/omacvm-bridge</string>' "$b")"
# And should one run in place, the app has a reason for each of those the Bridge uses.
for k in NSBluetoothAlwaysUsageDescription NSCameraUsageDescription NSMicrophoneUsageDescription; do
  grep -q "<key>$k</key>" "$R/src/bridge/mac/build.sh" || continue
  expect "the app's Info.plist has $k (the Bridge uses it)" "1" "$(grep -c "<key>$k</key>" "$R/app/scripts/build-app.sh")"
done
exit $fail
