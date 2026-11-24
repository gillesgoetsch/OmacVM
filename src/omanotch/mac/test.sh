#!/bin/bash
# Offline tests (no VM, no screen): which guest the strip serves, the handshake,
# the strip's layout, hover and drag (#849).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/GuestPicker.swift Sources/GuestAuth.swift Tests/main.swift -o build/tests
build/tests
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/StripLayout.swift Tests/StripLayout/main.swift -o build/strip-layout-tests
build/strip-layout-tests
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/StripHover.swift Tests/StripHover/main.swift -o build/strip-hover-tests
build/strip-hover-tests
swiftc -swift-version 5 -target arm64-apple-macos14.0 Sources/StripDrag.swift Tests/StripDrag/main.swift -o build/strip-drag-tests
build/strip-drag-tests
