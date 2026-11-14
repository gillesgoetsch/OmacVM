#!/bin/bash
# Offline tests of the Bridge's rules without AppKit: when the media-key tap
# is created again, where each media key goes (the Mac mini with one LG
# UltraFine and a Scarlett 2i2, the MacBook with an external display),
# QEMU's control socket from its command line, the tap's place with
# OmacVM.app's shareKeyboard (keys-model.swift), the steady Wi-Fi state
# (wifi-model.swift) and which of the Mac's notifications on screen close, by
# which action (notifications-model.swift). No permissions, no Wi-Fi.
# test-vm-keys.sh types the keys into a real (headless) QEMU.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/models-test" "$HERE/keys-model.swift" "$HERE/wifi-model.swift" "$HERE/notifications-model.swift" \
  "$HERE/tests/models/main.swift"
"$T/models-test"
