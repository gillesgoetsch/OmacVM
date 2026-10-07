#!/bin/bash
# Build OmacVMBridge.app (agent app, no Dock icon) into ./build and sign it.
# Signed by ../../lib/sign.sh (permissions survive rebuilds; SIGN_IDENTITY for a
# real certificate).
set -euo pipefail
cd "$(dirname "$0")"
# OMACVM_HELPER_TEST=1: the test identity (org.omacvm.test.bridge: port 47931 and
# its own folders, see control.swift; app/scripts/build-app.sh --test-identity).
APP=build/OmacVMBridge.app
ID=org.omacvm.bridge; NAME="OmacVM Bridge"
[[ ${OMACVM_HELPER_TEST:-0} == 1 ]] && { ID=org.omacvm.test.bridge; NAME="OmacVM Test Bridge"; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
../../icon/make-icns.sh "$APP/Contents/Resources/OmacVM.icns"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/omacvm-bridge" main.swift wifi.swift audio.swift server.swift keys.swift keylight.swift display.swift wallpaper.swift bluetooth.swift battery.swift camera.swift control.swift control_policy.swift touchid.swift touchid_policy.swift \
  touchid_theme.swift touchid_panel_model.swift \
  external-model.swift external-brightness.swift keys-model.swift wifi-model.swift vm-keys.swift hid-keys.swift \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreWLAN -framework CoreLocation -framework CoreAudio -framework AudioToolbox -framework ApplicationServices -framework Security -framework SystemConfiguration -framework IOBluetooth -framework CoreBluetooth -framework IOKit -framework LocalAuthentication
WHY="OmacVM Bridge reads the name of the Wi-Fi network this Mac is on, and of nearby networks, to show them in your Linux VM's status bar. macOS only reveals Wi-Fi network names to apps with Location Services access. No location is ever read or stored."
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>omacvm-bridge</string>
  <key>CFBundleIconFile</key><string>OmacVM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>$WHY</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>$WHY</string>
  <key>NSCameraUsageDescription</key><string>OmacVM Bridge passes this Mac's camera to Linux apps in your VM (UTM, VMware Fusion). The camera is on only while one of them uses it.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>OmacVM Bridge shows this Mac's Bluetooth devices in your Linux VM's status bar, and connects, disconnects or forgets them when you ask there.</string>
</dict></plist>
PL
../../lib/sign.sh "$APP" "$ID"
echo "built $APP"
