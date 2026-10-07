#!/bin/bash
# OmacVM.app's note about the VM's keyboard tap (KeyAccess.swift): it shows
# when QEMU's log from the last start says macOS refused the tap ("Could not
# create event tap"), and not for a log without it, an empty or missing log,
# or a line far past the log's start. The permission check itself asks macOS
# (no prompt) and is only printed. Compiles KeyAccess.swift on its own; no
# window, no VM, no prompt.
#   src/tests/app-key-access.sh
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
switch a[1] {
case "tap": print(KeyAccess.tapFailed(folder: URL(fileURLWithPath: a[2])) ? "refused" : "fine")
case "record": print(KeyAccess.record)
default: exit(2)
}
SWIFT
swiftc -O -o "$T/key-access" "$R/app/app/Sources/OmacVM/KeyAccess.swift" "$T/main.swift" 2>"$T/cc.log" || { cat "$T/cc.log"; exit 1; }
vm() { mkdir -p "$T/$1/logs"; printf '%b' "$2" > "$T/$1/logs/qemu.log"; "$T/key-access" tap "$T/$1"; }
expect "MacBook 2026-10-06: QEMU's warning -> note shown" refused \
  "$(vm mb 'OmacVM: network: vmnet\nomacvm: full screen: area 2056x1286 on a 2056x1329 display\nOmacVM: warning: Could not create event tap, system key combos will not be captured.\nomacvm: macOS shortcuts stay with macOS (OMACVM_MAC_SHORTCUTS=1)\n')"
expect "Mac mini: no warning -> no note" fine \
  "$(vm mini 'OmacVM: network: user\nomacvm: macOS shortcuts stay with macOS (OMACVM_MAC_SHORTCUTS=1)\n')"
expect "empty log -> no note" fine "$(vm empty '')"
mkdir -p "$T/none"
expect "no log (never started) -> no note" fine "$("$T/key-access" tap "$T/none")"
big=$(head -c 70000 /dev/zero | tr '\0' 'x')
expect "the words only after 64 KB (not QEMU's start) -> no note" fine "$(vm late "$big\nCould not create event tap\n")"
r=$("$T/key-access" record)
case $r in
  "keys: Input Monitoring "*" for OmacVM") echo "ok   qemu.log line: $r" ;;
  *) echo "FAIL qemu.log line: '$r'"; fail=1 ;;
esac
exit $fail
