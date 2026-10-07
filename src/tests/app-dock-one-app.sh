#!/bin/bash
# One OmacVM in the Dock (3.0.1): the VM's QEMU counts as OmacVM.app itself
# (DockIdentity.swift: started through the link Contents/MacOS/OmacVM-VM), so the Dock
# shows one icon and "Keep in Dock" keeps OmacVM.app, not the bare QEMU.
#   src/tests/app-dock-one-app.sh              offline: the rules, no window, no VM
#   src/tests/app-dock-one-app.sh --live APP   APP's VM runs: QEMU has APP's bundle id,
#                                              the launcher left the Dock, one tile for APP
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/app/app/Sources
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

if [[ ${1:-} == --live ]]; then
  APP=$(cd "${2:?--live APP}" && pwd -P)
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
  # A process of APP by its command line (APP may show as /tmp/... for /private/tmp/...).
  of_app() {   # REGEX (after the .app) -> first PID
    local p a
    for p in $(pgrep -f "\.app/Contents/$1"); do
      a=$(ps -o args= -p "$p" | sed -E "s#/Contents/$1.*##")
      [[ $(cd "$a" 2>/dev/null && pwd -P) == "$APP" ]] && { echo "$p"; return; }
    done
  }
  Q=$(of_app '(MacOS/OmacVM-VM|Resources/runtime/bin/OmacVM) ')
  [[ -n $Q ]] || { echo "FAIL no VM of $APP runs"; exit 1; }
  L=$(of_app 'MacOS/OmacVM( |$)')
  info() {   # PID KEY: LaunchServices' value for that process
    local asn; asn=$(lsappinfo find pid="$1" 2>/dev/null | head -1)
    [[ -n $asn ]] && lsappinfo info -only "$2" "$asn" 2>/dev/null | sed -n 's/.*=//p' | head -1 | tr -d '"'
  }
  expect "QEMU ($Q) counts as $ID" "$ID" "$(info "$Q" bundleID)"
  # lsappinfo gives no ApplicationType on macOS 27 ("[ NULL ]"): then skipped.
  type_is() {   # WHAT PID WANT
    local t; t=$(info "$2" ApplicationType)
    if [[ -z $t || $t == "[ NULL ]"* ]]; then echo "SKIP $1: lsappinfo gives no type here"; else expect "$1" "$3" "$t"; fi
  }
  type_is "QEMU is a regular app (menu bar, Cmd-Tab, full screen)" "$Q" Foreground
  [[ -n $L ]] && type_is "the launcher ($L) is out of the Dock" "$L" UIElement
  expect "qemu.log says one app" 1 "$(grep -l 'OmacVM: dock: one app' "$(lsof -p "$Q" -Fn 2>/dev/null | sed -n 's/^n\(.*logs\/qemu.log\)$/\1/p' | head -1)" 2>/dev/null | wc -l | tr -d ' ')"
  # The Dock's tiles, over Accessibility (the shell's grant): System Events
  # gives no AXURL for them on macOS 27, so a small tool reads them.
  T=$(mktemp -d "${TMPDIR:-/tmp}/dock-one-app.XXXXXX"); trap 'rm -rf "$T"' EXIT
  cat > "$T/tiles.swift" <<'EOF2'
import AppKit
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
      let list = kids(AXUIElementCreateApplication(dock.processIdentifier)).first(where: { (attr($0, kAXRoleAttribute) as? String) == "AXList" })
else { print("no Dock list (Accessibility?)"); exit(1) }
for e in kids(list) { if let u = attr(e, kAXURLAttribute) as? URL { print(u.path) } }
EOF2
  if swiftc -module-cache-path "$T/mc" -o "$T/tiles" "$T/tiles.swift" 2>/dev/null && "$T/tiles" > "$T/list" 2>/dev/null; then
    expect "one Dock tile for $(basename "$APP")" 1 "$(grep -c -x -F "$APP" "$T/list")"
    expect "no tile for the bare QEMU" 0 "$(grep -c '/runtime/bin/OmacVM$' "$T/list")"
  else
    echo "SKIP Dock tiles: no Accessibility for this shell"
  fi
  exit $fail
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/dock-one-app.XXXXXX")
trap 'kill $SLEEPER 2>/dev/null; rm -rf "$T"' EXIT
SLEEPER=

# What the Runner starts, compiled on its own: the Contents/MacOS link when
# it points at the app's QEMU.
cat > "$T/main.swift" <<'EOF2'
import Foundation
let a = CommandLine.arguments
var env: [String: String] = [:]
for kv in a.dropFirst(3) { let p = kv.split(separator: "=", maxSplits: 1).map(String.init); env[p[0]] = p.count > 1 ? p[1] : "" }
let l = DockIdentity.launchPath(qemu: a[1], bundle: a[2], env: env)
print(l + "|" + DockIdentity.record(launch: l, qemu: a[1]))
EOF2
swiftc -module-cache-path "$T/mc" -o "$T/dock" "$S/OmacVM/DockIdentity.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL DockIdentity.swift does not compile on its own"; exit 1; }
A=$T/One.app; Q=$A/Contents/Resources/runtime/bin/OmacVM; L=$A/Contents/MacOS/OmacVM-VM
mkdir -p "$(dirname "$Q")" "$A/Contents/MacOS"; : > "$Q"
d() { "$T/dock" "$@" | cut -d'|' -f1; }
expect "no link (older build): QEMU itself" "$Q" "$(d "$Q" "$A")"
ln -s ../Resources/runtime/bin/OmacVM "$L"
expect "the link: QEMU started as the app" "$L" "$(d "$Q" "$A")"
expect "the log line" "dock: one app (QEMU started as $L)" "$("$T/dock" "$Q" "$A" | cut -d'|' -f2)"
expect "OMACVM_DOCK_SEPARATE=1: QEMU on its own" "$Q" "$(d "$Q" "$A" OMACVM_DOCK_SEPARATE=1)"
expect "OMACVM_DOCK_SEPARATE=0: one app" "$L" "$(d "$Q" "$A" OMACVM_DOCK_SEPARATE=0)"
expect "the log line, on its own" "dock: QEMU on its own" "$("$T/dock" "$Q" "$A" OMACVM_DOCK_SEPARATE=1 | cut -d'|' -f2)"
expect "a development QEMU (swift run): itself" "$T/dev/qemu-system-aarch64" "$(d "$T/dev/qemu-system-aarch64" "$A")"
expect "not from an app bundle: QEMU itself" "$Q" "$(d "$Q" "$T/notanapp")"
rm "$L"; ln -s /bin/sleep "$L"
expect "a link to something else: QEMU itself" "$Q" "$(d "$Q" "$A")"
rm "$L"; ln -s ../Resources/runtime/bin/gone "$L"
expect "a dangling link: QEMU itself" "$Q" "$(d "$Q" "$A")"

# The app's build makes the link, relative (survives a move of the app).
grep -q '^ln -s ../Resources/runtime/bin/OmacVM "$C/MacOS/OmacVM-VM"$' "$R/app/scripts/build-app.sh"
expect "build-app.sh makes Contents/MacOS/OmacVM-VM" 0 $?

# Running.isQEMU: by the kernel's path, the app's QEMU only (not its launcher,
# not another app's QEMU).
mkdir -p "$T/isq.src"; cat > "$T/isq.src/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let pid = pid_t(a[1])!
print(Running.isQEMU(pid, of: a.count > 2 ? URL(fileURLWithPath: a[2]) : nil))
EOF
swiftc -module-cache-path "$T/mc" -o "$T/isq" "$S/OmacVMUpdate/Bundles.swift" "$T/isq.src/main.swift" 2>&1 ||
  { echo "FAIL Bundles.swift does not compile on its own"; exit 1; }
mkdir -p "$T/My VM.app/Contents/Resources/runtime/bin" "$T/My VM.app/Contents/MacOS" "$T/Other.app"
# A sleeper of our own: a copy of /bin/sleep (arm64e) is killed at start,
# even signed again ad hoc (macOS 15).
echo '#include <unistd.h>
int main(void) { sleep(30); return 0; }' | xcrun clang -x c -o "$T/My VM.app/Contents/Resources/runtime/bin/OmacVM" - ||
  { echo "FAIL no C compiler for the sleeper"; exit 1; }
cp "$T/My VM.app/Contents/Resources/runtime/bin/OmacVM" "$T/My VM.app/Contents/MacOS/OmacVM"
"$T/My VM.app/Contents/Resources/runtime/bin/OmacVM" & SLEEPER=$!; disown
"$T/My VM.app/Contents/MacOS/OmacVM" & LAUNCHER=$!; disown
sleep 0.3
expect "the app's QEMU is its QEMU" true "$("$T/isq" $SLEEPER "$T/My VM.app")"
expect "the app's QEMU is a QEMU (any app)" true "$("$T/isq" $SLEEPER)"
expect "the launcher is no QEMU" false "$("$T/isq" $LAUNCHER "$T/My VM.app")"
expect "another app's QEMU is not this app's" false "$("$T/isq" $SLEEPER "$T/Other.app")"
expect "a gone process is no QEMU" false "$("$T/isq" 999999)"
kill $LAUNCHER 2>/dev/null
# Started through the link (as the app does): the kernel still reports QEMU's
# own path and name, which Gestures, Omanotch, Bridge and the updater look at.
ln -s ../Resources/runtime/bin/OmacVM "$T/My VM.app/Contents/MacOS/OmacVM-VM"
"$T/My VM.app/Contents/MacOS/OmacVM-VM" & LINKED=$!; disown
sleep 0.3
expect "QEMU started through the link is the app's QEMU" true "$("$T/isq" $LINKED "$T/My VM.app")"
echo '#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int c, char **v) { char n[256] = ""; proc_name(atoi(v[1]), n, sizeof n); puts(n); return 0; }' |
  xcrun clang -x c -o "$T/pname" -
expect "its kernel name (proc_name, Gestures) stays OmacVM" OmacVM "$("$T/pname" $LINKED)"
kill $LINKED 2>/dev/null

# The places that find the VM's process do it by the kernel's path, since
# LaunchServices reports the app's own executable for QEMU now.
grep -q 'Running.isQEMU(\$0.processIdentifier, of: Bundle.main.bundleURL)' "$S/OmacVM/main.swift"
expect "the launcher finds its QEMU by the kernel's path" 0 $?
grep -q '&& !Running.isQEMU(\$0.processIdentifier)' "$S/OmacVM/main.swift"
expect "one launcher at a time: QEMU does not count as one" 0 $?
# The launcher leaves the Dock before QEMU comes up: QEMU starting while the
# launcher held a pinned icon got a second icon (Air, macOS 26.6.2).
a=$(grep -n 'NSApp.setActivationPolicy(.accessory)' "$S/OmacVM/main.swift" | head -1 | cut -d: -f1)
b=$(grep -n 'try r.start()' "$S/OmacVM/main.swift" | head -1 | cut -d: -f1)
expect "the launcher leaves the Dock before it starts QEMU" yes "$([[ -n $a && -n $b ]] && (( a < b )) && echo yes || echo no)"
grep -q 'DockIdentity.launchPath(qemu: Paths.qemu.path' "$S/OmacVM/Runner.swift"
expect "the Runner starts QEMU as this app" 0 $?
grep -q 'let exe = pidPath(app.processIdentifier) ?? app.executableURL' "$R/src/bridge/mac/external-brightness.swift"
expect "Bridge: the kernel's path first" 0 $?
grep -q 'proc_pidpath' "$R/src/omanotch/mac/Sources/OmacVMApp.swift"
expect "Omanotch: the kernel's path" 0 $?
grep -q 'proc_name(pid, name' "$R/src/gestures/mac/omacvm-gestures.c"
expect "Gestures: the kernel's name" 0 $?

exit $fail
