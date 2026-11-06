#!/bin/bash
# The Mac's battery in the VM, offline: watts and time left need the Mac's
# current (UPower guesses watts without it, and the guess is noise).
#   - the snapshot from ioreg-like readings (OmacVM.app's HostBattery.swift):
#     signed current, power
#   - the agent (omacvm-battery): its line per module version
#   - the module (omacvm-battery.c) on a stand-in for the kernel: parse,
#     current_now's sign, power_now, the charge limit
#   - all three in a row: snapshot -> line -> what UPower reads
# No VM, no Bridge, nothing changes on this Mac.
#   src/tests/battery.sh [--live]   --live: also print this Mac's snapshot
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
B=$R/src/tests/battery
AGENT=$R/src/battery/guest/omacvm-battery
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

swiftc -O -swift-version 5 -o "$T/snap-app" "$R/app/app/Sources/OmacVM/HostBattery.swift" \
  "$B/snapshot/main.swift" || { echo "battery: app snapshot build failed"; exit 1; }
cc -std=gnu11 -Wall -Wextra -Wno-unused-parameter -Werror -I "$B" -o "$T/module" "$B/module-test.c" \
  || { echo "battery: module build failed"; exit 1; }

echo "== snapshot (OmacVM.app)"; "$T/snap-app" || fail=1
echo "== agent"; python3 -I "$B/agent-test.py" "$AGENT" || fail=1
echo "== module"; "$T/module" || fail=1

echo "== snapshot -> agent -> module"
dkms=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$R/src/battery/guest/module/dkms.conf")
mod=$(sed -n 's/^MODULE_VERSION("\(.*\)");/\1/p' "$R/src/battery/guest/module/omacvm-battery.c")
if [[ $dkms == "$mod" ]]; then ok "DKMS and the module say the same version ($mod)"
else bad "DKMS says $dkms, the module $mod (DKMS rebuilds only on a new version)"; fi
for snap in "$T/snap-app"; do
  which=OmacVM.app
  json=$("$snap" -573)
  line=$(python3 -I "$B/agent-test.py" "$AGENT" line "$mod" <<<"$json")
  out=$("$T/module" "$line")
  for want in current_now=-573000 power_now=7042170 status=2 voltage_now=12290000 time_to_empty_now=54660 \
      charge_control_end_threshold=100; do
    grep -qx "$want" <<<"$out" && ok "$which, discharging 573 mA: $want" || bad "$which, discharging 573 mA: no $want in: $(tr '\n' ' ' <<<"$out")"
  done
  out=$("$T/module" "$(python3 -I "$B/agent-test.py" "$AGENT" line "$mod" <<<"$("$snap" 2100)")")
  grep -qx current_now=2100000 <<<"$out" && grep -qx status=1 <<<"$out" && grep -qx time_to_full_now=2400 <<<"$out" \
    && ok "$which, charging 2100 mA: current_now above 0, time to full" || bad "$which, charging 2100 mA: $(tr '\n' ' ' <<<"$out")"
  # The VM's module still 1.0.0 (not reloaded yet): the agent leaves the words out.
  line=$(python3 -I "$B/agent-test.py" "$AGENT" line 1.0.0 <<<"$json")
  [[ $line != *current_now* && $line != *power_now* ]] && ok "$which, module 1.0.0: no current_now/power_now" \
    || bad "$which, module 1.0.0 gets: $line"
done
# An older Mac side (no current): the module has none, UPower reads none.
old=$("$T/snap-app" -573 | python3 -c 'import json, sys; d = json.load(sys.stdin); d.pop("currentMicroA"); d.pop("powerMicroW"); print(json.dumps(d))')
out=$("$T/module" "$(python3 -I "$B/agent-test.py" "$AGENT" line "$mod" <<<"$old")")
grep -qx current_now=ENODATA <<<"$out" && grep -qx power_now=ENODATA <<<"$out" \
  && ok "an older Mac side: current_now and power_now not there (ENODATA)" || bad "an older Mac side: $(tr '\n' ' ' <<<"$out")"

if [[ ${1:-} == --live ]]; then
  echo "== this Mac (read only)"
  "$T/snap-app" live
fi
(( fail )) && { echo "battery: FAILED"; exit 1; }
echo "battery: all passed"
