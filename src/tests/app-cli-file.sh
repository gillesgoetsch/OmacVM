#!/bin/bash
# Which OmacVM.app copies write the Bridge's cli file (ControlCLI.swift) and
# which count as the test identity (TestIdentity in MacLinks.swift). Only
# OmacVM (org.omacvm.app) writes the user's file; the test identity and a
# lane's copy of it (org.omacvm.app.test.<lane>) write their own; a
# self-update test build or a build without a bundle id write nothing.
# Compiles the two files on their own with a fake home; no window, no VM.
#   src/tests/app-cli-file.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
let id: String? = a[2] == "-" ? nil : a[2]
switch a[1] {
case "test": print(TestIdentity.isTest(id) ? "test" : "not")
case "refresh": ControlCLI.refresh(bundle: URL(fileURLWithPath: a[3]), bundleID: id)
default: exit(2)
}
SWIFT
swiftc -O -o "$T/cli" "$R/app/app/Sources/OmacVM/MacLinks.swift" "$R/app/app/Sources/OmacVM/ControlCLI.swift" \
  "$R/app/app/Sources/OmacVMWindow/CommandLineInstall.swift" "$T/main.swift" 2>"$T/cc.log" || { cat "$T/cc.log"; exit 1; }
expect "org.omacvm.app.test is the test identity" test "$("$T/cli" test org.omacvm.app.test)"
expect "a lane copy org.omacvm.app.test.final301 is too" test "$("$T/cli" test org.omacvm.app.test.final301)"
expect "OmacVM itself is not" not "$("$T/cli" test org.omacvm.app)"
expect "org.omacvm.app.tester is not (only the dot form)" not "$("$T/cli" test org.omacvm.app.tester)"
expect "no bundle id is not" not "$("$T/cli" test -)"

H=$T/home; F="$H/Library/Application Support/omacvm/cli"
app() { mkdir -p "$T/$1.app/Contents/Resources/omacvm"; : > "$T/$1.app/Contents/Resources/omacvm/omacvm"; echo "$T/$1.app"; }
run() { HOME=$H CFFIXED_USER_HOME=$H "$T/cli" refresh "$1" "$(app "$2")" 2>>"$T/err.log"; }
mkdir -p "$H"
run org.omacvm.sutest su
expect "a self-update test build writes no cli file" none "$([[ -e $F ]] && cat "$F" || echo none)"
run - dev
expect "a build without a bundle id writes none" none "$([[ -e $F ]] && cat "$F" || echo none)"
run org.omacvm.app rel
expect "OmacVM writes it" "$T/rel.app/Contents/Resources/omacvm/omacvm" "$(cat "$F" 2>/dev/null)"
run org.omacvm.sutest su2
expect "then a test build leaves it as it was" "$T/rel.app/Contents/Resources/omacvm/omacvm" "$(cat "$F" 2>/dev/null)"
grep -q "is not OmacVM: the Bridge's cli file stays" "$T/err.log" && echo "ok   it says why" || { echo "FAIL no reason in stderr"; fail=1; }

# A checkout keeps the file, unless its OmacVM is older than the app's (#233;
# cli_file_app in src/lib/mac.sh, src/tests/version-guard.sh, has the same rule).
ver() { mkdir -p "$(dirname "$1")/src"; echo "$2" > "$(dirname "$1")/src/VERSION"; }
co=$T/checkout/omacvm; mkdir -p "$T/checkout"; : > "$co"
mkdir -p "$T/v303.app/Contents/Resources/omacvm"; ver "$T/v303.app/Contents/Resources/omacvm/omacvm" 3.0.3
for c in "2.9.1 app $T/v303.app/Contents/Resources/omacvm/omacvm" "3.0.3 checkout $co" "3.0.4 checkout $co"; do
  read -r v who want <<<"$c"
  ver "$co" "$v"; printf '%s\n' "$co" > "$F"
  run org.omacvm.app v303
  expect "checkout $v, OmacVM.app 3.0.3: the $who's omacvm runs" "$want" "$(cat "$F" 2>/dev/null)"
done
exit $fail
