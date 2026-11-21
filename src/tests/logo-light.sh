#!/bin/bash
# The Apple logo's light: the Bridge's side (src/bridge/mac/logo-model.swift,
# logo.swift) on a made-up logo. With --live, also on this Mac's lit Apple
# logo through the Bridge's own code: each mode for its seconds, then its
# owner ends and the logo is macOS's again. Stop a Bridge that plays a mode first: two writers fight over the logo.
#   src/tests/logo-light.sh [--live [WORDS SECONDS]...]   e.g. --live "on 50" 8 breathe 20 off 8
#   src/tests/logo-light.sh --state                      what the logo and macOS say now (reads only)
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
M=$R/src/bridge/mac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/logo-test" \
  "$M/control_policy.swift" "$M/logo-model.swift" "$M/logo.swift" "$M/tests/logo/main.swift" -framework IOKit
case ${1:-} in
  --live) shift; [[ $# -gt 0 ]] || set -- "on 50" 8 "on 80" 6 breathe 20 off 8 auto 5
          (cd "$T" && ./logo-test live "$@") ;;
  --state) "$T/logo-test" state ;;
  *) "$T/logo-test" || fail=1 ;;
esac
exit "$fail"
