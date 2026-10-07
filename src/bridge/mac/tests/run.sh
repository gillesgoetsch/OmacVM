#!/bin/bash
# The Bridge's offline tests: the control centre's request policy
# (control_policy.swift), Touch ID's (touchid_policy.swift) and the Touch ID
# panel's parts without AppKit (touchid_theme.swift, touchid_panel_model.swift).
# No Bridge, no VM, no network, no window.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -o "$out/control-tests" \
  control_policy.swift tests/control_tests.swift
"$out/control-tests"
# Touch ID (ADR 0041): LocalAuthentication and the Mac's state mocked.
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -o "$out/touchid-tests" \
  control_policy.swift touchid_policy.swift tests/touchid_tests.swift
"$out/touchid-tests"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -o "$out/touchid-panel-tests" \
  control_policy.swift touchid_policy.swift touchid_theme.swift touchid_panel_model.swift tests/touchid_panel_tests.swift
"$out/touchid-panel-tests"
