#!/bin/bash
# OmacVM.app's note about the VM's keyboard tap (KeyAccess.swift): it shows
# when QEMU's log from the last start says macOS refused the tap ("Could not
# create event tap"), and not for a log without it, an empty or missing log,
# or a line far past the log's start. The permission check itself asks macOS
# (no prompt) and is only printed; Allow… asks for what QEMU's tap needs.
# Compiles KeyAccess.swift on its own; no window, no VM, no prompt.
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
case "list": print(KeyAccess.listName)
case "reset-args": print(KeyAccess.resetArguments(a[2], id: a[3]).joined(separator: " "))
case "allow":   // a[2]: macOS's answer at each check in turn, such as refused,allowed (none: no answer)
    var answers: [Bool?] = a[2].split(separator: ",").map { $0 == "none" ? nil : $0 == "allowed" }
    var steps: [String] = []
    KeyAccess.allow(reset: { steps.append("reset \($0)") }, post: { steps.append("check"); return answers.removeFirst() },
                    ask: { steps.append("ask") })
    print(steps.joined(separator: ", "))
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
# The list in System Settings by the name this macOS shows it (macOS 27.2:
# "Device Control and Data Access", before: "Accessibility").
n=$("$T/key-access" list)
case $n in
  ""|ACCESSIBILITY) echo "FAIL the list's name: '$n'"; fail=1 ;;
  *) echo "ok   the list's name on this macOS: $n" ;;
esac
# Allow… with an old entry (MacBook 2026-10-07: tccd "Failed to match existing
# code requirement ... kTCCServicePostEvent", OmacVM on under Accessibility):
# the app's own "control the computer" entry goes first, without a password.
expect "tccutil resets only this app's entry" "reset PostEvent org.omacvm.app" "$("$T/key-access" reset-args PostEvent org.omacvm.app)"
# macOS 27.2: OmacVM switched on in System Settings, then two more clicks
# on Allow… a second later, while the note was still red: each reset took the
# grant away again, and the next VM start had no tap.
expect "Allow…, allowed now: no reset, no ask" "check" "$("$T/key-access" allow allowed)"
expect "Allow…, no answer from macOS: no reset, no ask" "check" "$("$T/key-access" allow none)"
expect "Allow…, no answer after the old entry went: Accessibility stays" "check, reset PostEvent, check" "$("$T/key-access" allow refused,none)"
expect "Allow…, Accessibility on: the old entry goes, nothing else" "check, reset PostEvent, check" "$("$T/key-access" allow refused,allowed)"
expect "Allow…, still refused: both entries go, then macOS asks" "check, reset PostEvent, check, reset Accessibility, ask" "$("$T/key-access" allow refused,refused)"
# What the window asks for: what QEMU's active tap needs ("control the
# computer", the Accessibility pane), not Input Monitoring.
src=$R/app/app/Sources/OmacVM/KeyAccess.swift
has() { if grep -qF "$2" "$src"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
hasnt() { if grep -qF "$2" "$src"; then echo "FAIL $1"; fail=1; else echo "ok   $1"; fi; }
has "Allow… asks for control the computer" '_ = CGRequestPostEventAccess()'
has "... and opens Accessibility" 'Privacy_Accessibility'
hasnt "... not Input Monitoring" 'CGRequestListenEventAccess'
hasnt "... nor its pane" 'Privacy_ListenEvent'
has "the steps name the list as this macOS does" 'Privacy & Security › \(listName).'
has "the window checks control the computer" 'static var allowed: Bool { post }'
has "... asked again in a new process (macOS keeps a process's first answer)" '"--key-access"'
has "Allow… takes macOS's answer now, not this process's first one" 'allow(reset: reset, post: fresh,'
src=$R/app/app/Sources/OmacVM/Views.swift
has "... and only that (not Input Monitoring)" 'KeyNote.decide(allowedNow: allowed || fresh() == true,'
src=$R/app/app/Sources/OmacVM/main.swift
has "the new process asks control the computer" 'print(CGPreflightPostEventAccess() ? "1" : "0")'
hasnt "... not Input Monitoring there either" 'CGPreflightListenEventAccess() ? "1"'
src=$R/app/app/Sources/OmacVM/SettingsRows.swift
has "... and so does the (i) of an allowed row" 'Privacy & Security › \(KeyAccess.listName).'
has "a red note clears an old entry once by itself" 'KeyAccess.clearOldEntryOnce'
has "Allow… looks again when it is done" 'KeyAccess.request { refreshKeyNote() }'
exit $fail
