#!/bin/bash
# Offline test of the camera's pick and its start again after a loss
# (camera.swift, tests/camera/main.swift): a made-up VM and a camera stand-in.
# No camera, no permission, nothing shown.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/camera-test" "$HERE/camera.swift" "$HERE/tests/camera/main.swift" \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo
"$T/camera-test"
