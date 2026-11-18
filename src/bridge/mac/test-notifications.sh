#!/bin/bash
# Live test of POST /notifications/dismiss's part on the Mac
# (notifications.swift), in this Mac user's session: a test banner goes up
# (osascript), every banner and alert on screen closes at once through the
# Bridge's own code, all of them must close, and the test banner must be
# gone. It closes the others on screen too, and prints none of their text.
# Needs Accessibility for the terminal it runs in and notifications on for
# Script Editor; not in CI (no screen there).
#   test-notifications.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/notifications-live" \
  "$HERE/notifications-model.swift" "$HERE/notifications.swift" "$HERE/tests/notifications/main.swift" -framework AppKit
L=$T/notifications-live
title="OmacVM test banner $$"
osascript -e "display notification \"test-notifications.sh closes it\" with title \"$title\""
# A banner shows for about 5 s: close as soon as it is there.
for _ in $(seq 50); do "$L" shows "$title" && break; sleep 0.1; done
"$L" shows "$title" || { echo "FAIL: the test banner did not show (Script Editor's notifications off, or a Focus on?)"; exit 1; }
echo "on screen: $("$L" count), the test banner among them"
r=$("$L" close)
echo "close: $r"
[[ $r =~ \"found\":\ ([0-9]+),\ \"closed\":\ ([0-9]+) ]] && (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[2] == BASH_REMATCH[1] )) ||
  { echo "FAIL: not every one on screen closed"; exit 1; }
sleep 0.5
if "$L" shows "$title"; then echo "FAIL: the test banner is still on screen"; exit 1; fi
echo "on screen after: $("$L" count)"
echo "notifications: ok"
