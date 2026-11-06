#!/bin/bash
# The Bridge on a retired route's address (retired.swift; Parallels, UTM and
# VMware Fusion, retired in 3.4.0): its pure parts, then the 3.3.0 guest
# clients of such a VM against it (tests/retired/old_guest.py): the control
# centre shows the move text, no job runs, the event service holds one stream.
# 127.0.0.1 only, a port of its own; no VM, no permission. About 40 s.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/retired" "$HERE/retired.swift" "$HERE/tests/retired/main.swift"
"$T/retired"
python3 "$HERE/tests/retired/old_guest.py" "$T/retired"
