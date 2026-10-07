#!/bin/bash
# OmacVM.app: when the VM's desktop loses its GPU context on the Mac.
# - The app's rules (DesktopRecovery.swift, compiled on its own): Hyprland
#   lost -> the desktop restarts by itself, at most once in 10 minutes, then
#   the app asks; off -> it always asks; the shell (Quickshell) lost -> only
#   the shell restarts, at most once a minute; other apps -> nothing.
# - The VM's omacvm-desktop-recover with stand-ins for systemctl, sudo,
#   hyprctl and notify-send: the note names the apps that closed, the login
#   manager restarts, the new session shows the note once, the shell mode
#   restarts only the shell; a locked session is locked again.
# - GuestAgent.start against a stand-in agent socket: a "return" reply is
#   started, an "error" reply refused, no reply in time (or half a line) no
#   answer, so the app never restarts the desktop a second time.
# No VM, no window.
#   src/tests/app-desktop-recovery.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's rules.
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
switch a[1] {
case "action":   // LOST(comma list) ENABLED LAST_DESKTOP_AGO|- LAST_SHELL_AGO|-
  let now = Date()
  let ago = { (s: String) -> Date? in s == "-" ? nil : now.addingTimeInterval(-Double(s)!) }
  let lost = a[2].isEmpty ? [] : a[2].split(separator: ",").map(String.init)
  switch DesktopRecovery.action(lost: lost, enabled: a[3] == "on", lastDesktop: ago(a[4]), lastShell: ago(a[5]), now: now) {
  case .none: print("none")
  case .restartDesktop: print("restart")
  case .ask(let again): print(again ? "ask-again" : "ask")
  case .restartShell: print("shell")
  }
case "reason":   // PRESSURE REFUSED
  print(DesktopRecovery.reason(pressure: a[2], refused: Int(a[3])!))
case "enabled":  // DOMAIN [set true|false]
  let d = UserDefaults(suiteName: a[2])!
  if a.count > 3 { d.set(a[3] == "true", forKey: DesktopRecovery.key) }
  print(DesktopRecovery.enabled(d) ? "on" : "off")
default: exit(2)
}
SWIFT
if ! swiftc -O -o "$T/rules" "$R/app/app/Sources/OmacVM/DesktopRecovery.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
  cat "$T/swiftc.log"; echo "FAIL DesktopRecovery.swift does not compile on its own"; exit 1
fi
r() { "$T/rules" "$@"; }
expect "Hyprland lost: restarts by itself"                  restart   "$(r action Hyprland on - -)"
expect "Hyprland among others: restarts by itself"          restart   "$(r action chromium,Hyprland,quickshell on - -)"
expect "lost again 5 min after a restart: asks"             ask-again "$(r action Hyprland on 300 -)"
expect "lost again 11 min after a restart: restarts"        restart   "$(r action Hyprland on 660 -)"
expect "switched off: asks"                                 ask       "$(r action Hyprland off - -)"
expect "the shell lost: only the shell restarts"            shell     "$(r action quickshell on - -)"
expect "the shell lost again within a minute: nothing"      none      "$(r action quickshell on - 30)"
expect "the shell lost after two minutes: restarts it"      shell     "$(r action quickshell on - 120)"
expect "the shell lost, switched off: nothing"              none      "$(r action quickshell off - -)"
expect "a browser lost: nothing (it is not the desktop)"    none      "$(r action chromium on - -)"
expect "no names: nothing"                                  none      "$(r action '' on - -)"
expect "normal pressure, nothing refused: graphics"         graphics  "$(r reason normal 0)"
expect "refused: memory"                                    memory    "$(r reason normal 3)"
expect "critical pressure: memory"                          memory    "$(r reason critical 0)"
D=org.omacvm.test.desktoprecovery.$$
expect "on unless switched off"                             on        "$(r enabled "$D")"
expect "defaults write ... desktopAutoRestart -bool false"  off       "$(r enabled "$D" false)"
defaults delete "$D" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$D.plist"

# The VM's side, with stand-ins.
S=$T/bin; mkdir -p "$S"
export CALLS=$T/calls
printf '#!/bin/bash\necho "systemctl $*" >> "$CALLS"\n' > "$S/systemctl"
printf '#!/bin/bash\necho "logger $*" >> "$CALLS"\n' > "$S/logger"
# sudo -u USER env ... bash -c '...' _ CMD...: run CMD (the part after "_").
cat > "$S/sudo" <<'STUB'
#!/bin/bash
# sudo -u USER sh -c SCRIPT _ ARGS: run SCRIPT; sudo -u USER env ... bash -c '...' _ CMD...: run CMD.
shift 2
if [[ $1 == sh && $2 == -c ]]; then exec sh -c "$3" "${@:4}"; fi
while [[ $# -gt 0 && $1 != _ ]]; do shift; done; shift; "$@"
STUB
printf '#!/bin/bash\nshift; "$@"\n' > "$S/timeout"
printf '#!/bin/bash\n[[ $1 == -f ]] && shift; "$@"\n' > "$S/setsid"
printf '#!/bin/bash\necho omarchy-restart-shell >> "$CALLS"\n' > "$S/omarchy-restart-shell"
printf '#!/bin/bash\n[[ -e $LOCKED ]]\n' > "$S/omarchy-hyprland-session-locked"
printf '#!/bin/bash\necho omarchy-system-lock >> "$CALLS"; [[ -e $LOCK_FAILS ]] || touch "$LOCKED"\n' > "$S/omarchy-system-lock"
printf '#!/bin/bash\n[[ $* == "clients -j" ]] && cat "$CLIENTS"\n' > "$S/hyprctl"
printf '#!/bin/bash\n[[ -e $NOTIFY_FAILS ]] && exit 1; printf "%%s|" "notify-send" "$@" >> "$CALLS"; echo >> "$CALLS"\n' > "$S/notify-send"
printf '#!/bin/bash\n[[ $1 == -u ]] && { echo 1000; exit; }; [[ $1 == -gn ]] && { echo staff; exit; }; echo staff\n' > "$S/id"
printf '#!/bin/bash\necho "x:x:1000:1000::$HOME:/bin/bash"\n' > "$S/getent"
printf '#!/bin/bash\n[[ $1 == -d ]] && mkdir -p "${@: -1}"\n' > "$S/install"
printf '#!/bin/bash\n:\n' > "$S/chown"
printf '#!/bin/bash\n:\n' > "$S/sleep"
chmod +x "$S"/*
export PATH="$S:$PATH"
export OMACVM_RECOVER_ENV=$T/env OMACVM_RECOVER_NOTE=$T/run/desktop/restarted CLIENTS=$T/clients NOTIFY_FAILS=$T/notify-fails LOCKED=$T/locked LOCK_FAILS=$T/lock-fails
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=tester\n' > "$T/env"
cat > "$CLIENTS" <<'JSON'
[{"class": "chromium", "title": "a"}, {"class": "Alacritty"}, {"class": "chromium"}, {"class": "", "initialClass": "obsidian"}, {"class": "bad\nwhy=x"}]
JSON
G=$R/src/app/guest/omacvm-desktop-recover
: > "$CALLS"
"$G" desktop memory > /dev/null
expect "desktop: the login manager restarts"     "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
expect "desktop: the note says why"              memory                   "$(sed -n 's/^why=//p' "$T/run/desktop/restarted")"
expect "desktop: the note names the apps once, on one line"   "chromium, Alacritty, obsidian, bad why=x" "$(sed -n 's/^apps=//p' "$T/run/desktop/restarted")"
grep -q "closing: chromium, Alacritty, obsidian, bad why=x" "$CALLS" && expect "desktop: logged to the journal" yes yes \
  || expect "desktop: logged to the journal" yes no
: > "$CALLS"
"$G" notify
cp "$CALLS" "$T/calls.unlocked"
n=$(grep -c '^notify-send' "$CALLS")
expect "notify: shown once"                      1 "$n"
grep -q "These apps were closed: chromium, Alacritty, obsidian, bad why=x. Anything not saved in them is lost." "$CALLS" \
  && expect "notify: says which apps closed and that unsaved work is lost" yes yes \
  || { expect "notify: says which apps closed and that unsaved work is lost" yes no; cat "$CALLS"; }
grep -q "macOS ran short of memory" "$CALLS" && expect "notify: says why (memory)" yes yes || expect "notify: says why (memory)" yes no
expect "notify: the note is gone after"          no "$( [[ -e $T/run/desktop/restarted ]] && echo yes || echo no)"
: > "$CALLS"
"$G" notify
expect "notify: nothing without a note"          "" "$(cat "$CALLS")"
expect "notify: unlocked before, no lock"        0 "$(grep -c '^omarchy-system-lock' "$T/calls.unlocked")"
# Locked when the desktop was lost: the new session locks itself again, first.
touch "$LOCKED"
"$G" desktop memory > /dev/null
expect "desktop while locked: the note says so"  1 "$(sed -n 's/^locked=//p' "$T/run/desktop/restarted")"
rm -f "$LOCKED"; : > "$CALLS"
"$G" notify
expect "notify after a locked session: locks once, then the note" "omarchy-system-lock notify-send" \
  "$(grep -o '^omarchy-system-lock\|^notify-send' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
touch "$LOCK_FAILS" "$LOCKED"; "$G" desktop memory > /dev/null; rm -f "$LOCKED"; : > "$CALLS"
"$G" notify > /dev/null
grep -q "could not lock the new session again" "$CALLS" && expect "notify: a lock that does not hold is logged" yes yes \
  || expect "notify: a lock that does not hold is logged" yes no
rm -f "$LOCK_FAILS"
# No Hyprland answer (hung): still restarts, the note says apps closed.
: > "$CALLS"; echo 'not json' > "$CLIENTS"
"$G" desktop graphics > /dev/null
expect "desktop without an app list: still restarts" "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
"$G" notify
grep -q "Apps that were open were closed; anything not saved in them is lost." "$CALLS" \
  && expect "notify without an app list: says apps closed" yes yes || expect "notify without an app list: says apps closed" yes no
grep -q "graphics on the Mac failed" "$CALLS" && expect "notify: says why (graphics)" yes yes || expect "notify: says why (graphics)" yes no
# A garbage reason counts as graphics; the notification daemon not up: tried, then logged.
: > "$CALLS"
"$G" desktop 'x;rm -rf /' > /dev/null
expect "an unknown reason counts as graphics"    graphics "$(sed -n 's/^why=//p' "$T/run/desktop/restarted")"
touch "$NOTIFY_FAILS"
"$G" notify > /dev/null
grep -q "could not show the note" "$CALLS" && expect "notify without a daemon: logged" yes yes || expect "notify without a daemon: logged" yes no
rm -f "$NOTIFY_FAILS"
# The shell.
: > "$CALLS"
"$G" shell > /dev/null
expect "shell: only the shell restarts"          omarchy-restart-shell "$(grep -v '^logger' "$CALLS")"
# No desktop user known.
printf 'OMACVM_VM_TYPE=app\n' > "$T/env"
: > "$CALLS"
"$G" shell > /dev/null; rc=$?
expect "shell without a user: refused"           1 "$rc"
"$G" desktop graphics > /dev/null
expect "desktop without a user: still restarts"  "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
"$G" bogus 2>/dev/null; rc=$?
expect "unknown mode: usage"                     2 "$rc"

# GuestAgent.start against a stand-in agent: answers, refuses, says nothing.
mkdir -p "$T/agent-src"
cat > "$T/agent-src/main.swift" <<'SWIFT'
import Foundation
switch GuestAgent.start(socketPath: CommandLine.arguments[1], "/usr/local/bin/omacvm-desktop-recover", ["desktop", "memory"]) {
case .started: print("started")
case .refused: print("refused")
case .noAnswer: print("noAnswer")
}
SWIFT
if ! swiftc -O -o "$T/agent" "$R/app/app/Sources/OmacVM/GuestAgent.swift" "$T/agent-src/main.swift" 2>"$T/swiftc.log"; then
  cat "$T/swiftc.log"; echo "FAIL GuestAgent.swift does not compile on its own"; exit 1
fi
cat > "$T/fake-agent.py" <<'PY'
import os, socket, sys, time
path, mode = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
print("up", flush=True)
c, _ = s.accept(); f = c.makefile("rb")
line = f.readline()
assert b"guest-exec" in line, line
if mode == "return": c.sendall(b'{"return": {"pid": 4242}}\n')
elif mode == "error": c.sendall(b'{"error": {"class": "GenericError", "desc": "Failed to execute child process (No such file or directory)"}}\n')
elif mode == "partial": c.sendall(b'{"retu')
time.sleep(3)   # longer than the app waits (2 s)
PY
agent() {   # MODE -> what GuestAgent.start says
  local sock=$T/qga-$1.sock
  python3 "$T/fake-agent.py" "$sock" "$1" > "$T/fake-$1.out" 2>&1 &
  local pid=$!
  for _ in $(seq 50); do [[ -S $sock ]] && break; /bin/sleep 0.1; done
  "$T/agent" "$sock"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
expect "agent: a return reply is started"                 started  "$(agent return)"
expect "agent: an error reply is refused"                 refused  "$(agent error)"
expect "agent: no reply in 2 s is no answer, not refused" noAnswer "$(agent silent)"
expect "agent: half a reply in 2 s is no answer"          noAnswer "$(agent partial)"
expect "agent: no socket is no answer"                    noAnswer "$("$T/agent" "$T/none.sock")"
exit $fail
