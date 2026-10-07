#!/bin/bash
# Offline tests (no VM, no screen): which guest the strip serves, the handshake.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/GuestPicker.swift Sources/GuestAuth.swift Tests/main.swift -o build/tests
build/tests
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/StripLayout.swift Tests/StripLayout/main.swift -o build/strip-layout-tests
build/strip-layout-tests
