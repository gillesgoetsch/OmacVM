#!/bin/bash
# App VMs skip the routes of a network card without a link at once
# (ignore_routes_with_linkdown), so moving between OmacVM.app's two cards
# (fast network <-> QEMU's user network) leaves no gap; other routes do not
# get the setting, and lose it when they had it. No VM needed: the block of
# src/guest/install.sh runs with sysctl replaced and its file in a temp dir.
#   src/tests/net-linkdown.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/net-linkdown.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

F=/etc/sysctl.d/90-omacvm-net.conf
block=$(awk '/^# Network cards without a link: their routes are skipped/ {on = 1} on {print} on && /^fi$/ {exit}' "$R/src/guest/install.sh")
[[ $block == *"$F"* ]] || { echo "FAIL linkdown block not found in src/guest/install.sh"; exit 1; }
block=${block//"$F"/"$T/net.conf"}

guest() {   # TYPE -> the sysctl calls and the file's settings
  ( TYPE=$1 CALLS=""
    sysctl() { CALLS+="sysctl $* "; }
    eval "$block"
    echo "${CALLS% }|$(grep -v '^#' "$T/net.conf" 2>/dev/null | tr '\n' ' ')" )
}
on="net.ipv4.conf.all.ignore_routes_with_linkdown = 1 net.ipv6.conf.all.ignore_routes_with_linkdown = 1 "
expect "app VM: file written and loaded" "sysctl -q -p $T/net.conf|$on" "$(guest app)"
expect "app VM again: the same" "sysctl -q -p $T/net.conf|$on" "$(guest app)"
for t in other; do
  rm -f "$T/net.conf"
  expect "$t: nothing" "|" "$(guest $t)"
done
guest app >/dev/null
expect "app VM now another type: file gone, setting back to 0" \
  "sysctl -q -w net.ipv4.conf.all.ignore_routes_with_linkdown=0 net.ipv6.conf.all.ignore_routes_with_linkdown=0|" "$(guest other)"
[[ ! -e $T/net.conf ]]; expect "and the file is gone" 0 $?

exit $fail
