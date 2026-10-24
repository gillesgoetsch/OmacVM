#!/bin/bash
# The VM's time zone follows the Mac's (src/bridge/guest/omacvm-timezone):
# start, changes, a zone set by hand kept, bad zones ignored, a refused set
# (timezone.py, a stand-in for /, the Bridge client and timedatectl). Then the
# Bridge sends the zone ("timezone" feed, GET /timezone) and the guest check
# reads the agent's state.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0
python3 -I src/tests/timezone.py src/bridge/guest/omacvm-timezone || fail=1
grep -q 'Feed(event: "timezone"' src/bridge/mac/main.swift && grep -q 'case ("GET", "/timezone")' src/bridge/mac/server.swift &&
  grep -q 'NSSystemTimeZoneDidChange' src/bridge/mac/main.swift && echo "ok   the Bridge sends the Mac's zone (feed, GET /timezone, on change)" ||
  { echo "FAIL the Bridge's timezone feed or route is missing"; fail=1; }
grep -q 'omacvm-timezone --status' src/guest/check.sh && echo "ok   omacvm check reads the agent's state" ||
  { echo "FAIL no time zone line in src/guest/check.sh"; fail=1; }
exit $fail
