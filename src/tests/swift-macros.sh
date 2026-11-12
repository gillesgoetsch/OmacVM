#!/bin/bash
# The tests that build OmacVM.app's SwiftUI sources (app-settings.sh, app-mouse-swipe.sh,
# app-storage-ui.sh) take a toolchain that expands SwiftUI's macros (swift-toolchain.sh), so a
# Command Line Tools swiftc never fails them again (the 3.4.4 suites: "plugin for module
# 'SwiftUIMacros' not found"):
#  - the toolchain this shell has: kept when it expands @State;
#  - DEVELOPER_DIR at the Command Line Tools, and their usr/bin first on PATH: Xcode's instead;
#  - after it, swiftc builds a SwiftUI view with @State;
#  - the three tests source it before they build.
# Needs Xcode on the Mac for the second row (skipped, and said, without one). Command Line Tools
# that expand @State themselves (a later release): no cause row, no switch, they only typecheck.
#   src/tests/swift-macros.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-swift-macros.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
printf 'import SwiftUI\nstruct V: View { @State var on = false; var body: some View { Toggle("x", isOn: $on) } }\n' > "$T/v.swift"
# ENV...: a shell with that environment sources the helper, then typechecks v.swift
probe() {
  env "$@" /bin/bash -c 'source "$1/src/tests/swift-toolchain.sh"; swift_toolchain || exit 1
    swiftc -typecheck -module-cache-path "$2/mc" "$2/v.swift" > "$2/tc.log" 2>&1 && echo "typecheck ok" || { echo "typecheck FAIL"; head -3 "$2/tc.log"; }' \
    _ "$R" "$T"
}

out=$(probe PATH="$PATH")
expect "this shell's toolchain: @State typechecks" "typecheck ok" "$(tail -1 <<<"$out")"
echo "     ($(head -1 <<<"$out"))"

CLT=/Library/Developer/CommandLineTools
xc=""
for d in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer; do [[ -d $d/Platforms/MacOSX.platform ]] && { xc=$d; break; }; done
if [[ ! -x $CLT/usr/bin/swiftc ]]; then
  echo "skip the Command Line Tools rows: none on this Mac"
elif [[ -z $xc ]]; then
  echo "skip the Command Line Tools rows: no Xcode on this Mac to fall back to"
elif out=$(env -u SDKROOT DEVELOPER_DIR="$CLT" PATH="$PATH" /bin/bash -c 'swiftc -typecheck -module-cache-path "$1/mc0" "$1/v.swift" > "$1/clt.log" 2>&1 && echo expands ||
    grep -m1 -o "plugin for module .SwiftUIMacros. not found" "$1/clt.log"' _ "$T"); [[ $out == expands ]]; then
  # A later Command Line Tools with SwiftUI's macro plugin: nothing to switch, the helper keeps them.
  echo "skip the cause row and the switch to Xcode: this Command Line Tools swiftc expands @State"
  for p in "$PATH" "$CLT/usr/bin:$PATH"; do
    out=$(probe -u SDKROOT DEVELOPER_DIR="$CLT" PATH="$p")
    expect "DEVELOPER_DIR at the Command Line Tools$([[ $p == "$CLT"* ]] && echo ', their usr/bin first'): @State typechecks" \
      "typecheck ok" "$(tail -1 <<<"$out")"
  done
else
  expect "the cause: a Command Line Tools swiftc cannot expand @State" "plugin for module 'SwiftUIMacros' not found" "$out"
  out=$(probe -u SDKROOT DEVELOPER_DIR="$CLT" PATH="$PATH")
  expect "DEVELOPER_DIR at the Command Line Tools: Xcode's, @State typechecks" "swift toolchain: Xcode's, $xc|typecheck ok" \
    "$(head -1 <<<"$out" | sed 's/ (.*//')|$(tail -1 <<<"$out")"
  out=$(probe -u SDKROOT DEVELOPER_DIR="$CLT" PATH="$CLT/usr/bin:$PATH")
  expect "... and their usr/bin first on PATH: Xcode's, @State typechecks" "swift toolchain: Xcode's, $xc|typecheck ok" \
    "$(head -1 <<<"$out" | sed 's/ (.*//')|$(tail -1 <<<"$out")"
fi

for t in app-settings app-mouse-swipe app-storage-ui; do
  expect "$t.sh takes the toolchain before it builds" yes \
    "$(awk '/^source .*swift-toolchain.sh.*; swift_toolchain/ { s = NR } /swiftc / && !b { b = NR } END { print (s && s < b) ? "yes" : "no" }' "$R/src/tests/$t.sh")"
done

(( fail == 0 )) && echo "swift-macros: all passed"
exit $fail
