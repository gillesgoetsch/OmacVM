#!/bin/bash
# Which Omarchy a new VM gets (3.4.0 on): Omarchy 4.5 on Omarchy's own aarch64
# repos, stable, always. omarchy-mac 4.0 only with OMACVM_TEST_OMARCHY=4.0
# (tests: the move matrix's 4.0 bases). The CLI (src/lib/setup.sh, build.sh's
# summary) and the app's create script (app/scripts/vm-common.sh) give the same
# answer, and nothing asks omarchy-mac's GitHub for a channel on a build.
#   src/tests/omarchy-route.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d -t omarchy-route); trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The two functions of each file, on their own (vm-common.sh sources more).
for f in src/lib/setup.sh app/scripts/vm-common.sh; do
  o=$T/$(basename "$f")
  awk '/^omarchy(_route|45_channel)\(\)/ { on = 1 } on { print } on && /}$/ && (/^}/ || /\(\) \{.*}$/) { on = 0 }' "$R/$f" > "$o"
  expect "$f: has omarchy_route and omarchy45_channel" 2 "$(grep -cE '^omarchy(_route|45_channel)\(\)' "$o")"
done

ask() {   # FILE TYPE TEST TEST_CHANNEL -> "route channel"
  (unset OMACVM_TEST_OMARCHY OMACVM_TEST_OMARCHY_CHANNEL TYPE
   [[ -n $2 ]] && TYPE=$2; [[ -n $3 ]] && export OMACVM_TEST_OMARCHY=$3
   [[ -n $4 ]] && export OMACVM_TEST_OMARCHY_CHANNEL=$4
   source "$T/$1"; echo "$(omarchy_route) $(omarchy45_channel)")
}
for f in setup.sh vm-common.sh; do
  expect "$f: a new VM: Omarchy 4.5 stable" "4.5 stable" "$(ask $f "" "" "")"
  expect "$f: TYPE app: Omarchy 4.5 stable" "4.5 stable" "$(ask $f app "" "")"
  expect "$f: no other TYPE brings back omarchy-mac" "4.5 stable" "$(ask $f other "" "")"
  expect "$f: tests, OMACVM_TEST_OMARCHY=4.0: omarchy-mac 4.0" "4.0 stable" "$(ask $f "" 4.0 "")"
  expect "$f: OMACVM_TEST_OMARCHY=4.5" "4.5 stable" "$(ask $f "" 4.5 "")"
  expect "$f: OMACVM_TEST_OMARCHY anything else: 4.5" "4.5 stable" "$(ask $f "" 3.9 "")"
  expect "$f: tests, channel rc" "4.5 rc" "$(ask $f "" "" rc)"
  expect "$f: channel not stable/rc/edge: stable" "4.5 stable" "$(ask $f "" "" 'x;y')"
done

# build.sh: no omarchy-mac channel on a build (it asked omarchy-mac's GitHub
# every time) and no --channel option.
expect "build.sh asks no omarchy-mac channel" 0 "$(grep -c 'omarchy_channel\|--channel' "$R/src/cmd/build.sh")"
expect "setup.sh has no omarchy_channel" 0 "$(grep -c '^omarchy_channel' "$R/src/lib/setup.sh")"
exit $fail
