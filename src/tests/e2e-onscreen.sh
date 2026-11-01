#!/bin/bash
# The on-screen release test's parts that need no screen, VM or app
# (src/tests/e2e/onscreen.sh): its checks with made-up values, its tool
# compiles, and the harness refuses what is not a test build or a test VM.
# The same for the locked present row (src/tests/e2e/present-locked.sh): its
# verdict on saved qemu.log lines (src/tests/e2e/present-logs), the hidden-start
# guard, and the display tool's --while-locked run without a display (--dry-run).
#   src/tests/e2e-onscreen.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/tests/e2e/onscreen-lib.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
is() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
isnt() { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }
same() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }

# The app's window on a 2560x1364 visible frame below a 31 pt menu bar.
V="0 31 2560 1364"
same "window: 800x800 centred" "" "$(os_window_problems "880 313 800 800" "$V")"
same "window: fractions are whole points" "" "$(os_window_problems "880.4 313.2 800.3 799.6" "$V")"
# 3.1.24 opened as tall as the display (#458), and macOS's Fill made it as wide (#452).
p=$(os_window_problems "880 47 800 1332" "$V"); [[ $p == *"1332 pt tall"* ]] && ok "window: too tall ($p)" || bad "window: too tall: '$p'"
p=$(os_window_problems "0 31 2560 1364" "$V"); [[ $p == *"2560 pt wide"* ]] && ok "window: too wide ($p)" || bad "window: too wide: '$p'"
p=$(os_window_problems "100 313 800 800" "$V"); [[ $p == *"not centred across"* ]] && ok "window: off centre" || bad "window: off centre: '$p'"
p=$(os_window_problems "880 600 800 800" "$V"); [[ $p == *"up and down"* && $p == *"visible frame"* ]] && ok "window: low, partly off the display" || bad "window: low: '$p'"
p=$(os_window_problems "880 313 800 460" "$V"); [[ $p == *"less than 500"* ]] && ok "window: too short" || bad "window: too short: '$p'"

is "same size: within 1 pt" os_same_size "10 20 1140 672" "12 40 1140.6 671.5"
isnt "same size: 20 pt smaller (#452)" os_same_size "10 20 1140 672" "10 20 1140 652"

is "cursor: hidden" os_cursor_hidden "visible=0 empty=0 at 10,10"
is "cursor: an empty image" os_cursor_hidden "visible=1 empty=1 at 10,10"
isnt "cursor: the arrow" os_cursor_hidden "visible=1 empty=0 at 10,10"
isnt "cursor: shown, image unknown" os_cursor_hidden "visible=1 empty=? at 10,10"

# The USB question's first second (the tool's ask-keys line, its exit code, the Space before and after).
G="found=0.04 alert=1@layer3 vm=1 space=4 early=stays front=501 late=answered@0.71 sent=Return@0.15,Escape@0.30,Return@0.65 "
same "usb: the question as it should be" "" "$(os_usb_ask_problems "$G" 0 4 4)"
p=$(os_usb_ask_problems "found=0.04 alert=1@layer3 vm=1 space=4 early=answered@0.16 front=501 late=stays sent=Return@0.15 " 1 4 4)
[[ $p == *"within 0.5 s"* && $p == *"did not answer"* ]] && ok "usb: answered by the early Return" || bad "usb: early Return: '$p'"
p=$(os_usb_ask_problems "found=0.05 front=600 sent= " 3 4 4); [[ $p == *"not in front"* ]] && ok "usb: question not in front" || bad "usb: not in front: '$p'"
p=$(os_usb_ask_problems "found=0.04 alert=1@layer0 vm=1 space=4 early=stays front=501 late=answered@0.7 sent= " 0 4 4)
[[ $p == *"no floating"* ]] && ok "usb: question not floating" || bad "usb: layer 0: '$p'"
p=$(os_usb_ask_problems "found=0.04 alert=1@layer3 vm=0 space=9 early=stays front=501 late=answered@0.7 sent= " 0 4 9)
[[ $p == *"VM's window"* && $p == *"Space changed"* ]] && ok "usb: question on another Space" || bad "usb: other Space: '$p'"
same "usb: no question" "no question in 5 s" "$(os_usb_ask_problems "question=none " 1 4 4)"
same "usb: usb.json, the test device kept on the Mac" "1 1 1209:0001 mac OmacVM Test Device 2026-10-31" "$(os_usb_keep_json 2026-10-31 |
  /usr/bin/python3 -c 'import json,sys; o=json.load(sys.stdin); d=o["devices"][0]; print(o["version"], len(o["devices"]), d["vendor"]+":"+d["product"], d["choice"], d["name"], d["since"], *(k for k in ("serial","maker") if k not in d))')"

# What runs on after the run: QEMU of the VM, the app (not its helpers), anything on the VM's folder
# (not another VM's with a longer name).
A="/x/OmacVM Test.app"; D="/v/OmacVM M-e2e"
got=$(os_leftovers "$A" "$D" "OmacVM M-e2e" <<EOF
  101 $A/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e -machine virt
  102 /y/Other.app/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e2 -machine virt
  108 /y/Other.app/Contents/MacOS/OmacVM-VM -name OmacVM M-e2e
  109 /bin/ls /v/OmacVM M-e2e2/logs
  103 $A/Contents/MacOS/OmacVM --vm OmacVM M-e2e
  104 $A/Contents/Helpers/OmacVM Test Bridge.app/Contents/MacOS/omacvm-bridge
  105 /usr/bin/ssh -p 2222 root@127.0.0.1 -o UserKnownHostsFile=$D/known_hosts
  106 /Applications/OmacVM.app/Contents/MacOS/OmacVM-VM -name Omarchy
  107 /bin/bash $A/Contents/Resources/scripts/update-vm.sh $D
EOF
)
same "leftovers: QEMU, the app, a tool on the VM's folder" "101 108 103 105 107" "$(echo "$got" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"

# result.json: pass needs an ok and no FAIL or BLOCKED.
printf '10:00:00\twindow\tok\tframe\n10:00:01\tpointer-1\tFAIL\tarrow\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" version=3.1.24 seconds=12 >/dev/null
same "result: a FAIL does not pass" "False 1 12 3.1.24" "$(/usr/bin/python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); print(o["pass"], o["counts"]["FAIL"], o["seconds"], o["version"])' "$T/r.json")"
printf '10:00:00\twindow\tok\tframe\n10:00:01\tpointer\tBLOCKED\tsomeone\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" >/dev/null
same "result: BLOCKED does not pass" False "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pass"])' "$T/r.json")"
printf '10:00:00\twindow\tok\tframe\n10:00:01\twindow-zoom\tskip\tnone\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-onscreen "$T/r.json" >/dev/null
same "result: ok and skip pass" True "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pass"])' "$T/r.json")"

# The tool compiles (it runs only on a test Mac).
if xcrun swiftc -O "$R/src/tests/e2e/onscreen-tool.swift" -o "$T/onscreen-tool" 2>"$T/swiftc.log"; then
  out=$("$T/onscreen-tool" nonsense 2>&1); [[ $? == 2 && $out == usage* ]] && ok "tool: builds, usage on a wrong command" || bad "tool: '$out'"
  # The USB row's readings (no window, no input): a Space id, no windows of a process without any.
  out=$("$T/onscreen-tool" space 2>&1); [[ $out =~ ^[0-9]+$ ]] && ok "tool: space ($out)" || bad "tool: space: '$out'"
  out=$("$T/onscreen-tool" onscreen $$ 2>&1); [[ $out == 0 ]] && ok "tool: onscreen of a shell: 0" || bad "tool: onscreen: '$out'"
else bad "tool does not build: $(head -5 "$T/swiftc.log")"; fi

# The harness refuses a release build and a VM outside the test app's VMs folder (exit 2, nothing started).
H=$R/src/tests/e2e/onscreen.sh
mkdir -p "$T/Rel.app/Contents" "$T/Test.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app" "$T/Rel.app/Contents/Info.plist" >/dev/null
DOM=org.omacvm.app.test.e2e-onscreen.$$
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $DOM" "$T/Test.app/Contents/Info.plist" >/dev/null
trap 'defaults delete "$DOM" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$DOM.plist"' EXIT
out=$("$H" --app "$T/Rel.app" --vm "OmacVM M-e2e" --out "$T/o1" 2>&1); rc=$?
[[ $rc == 2 && $out == *"not a test identity build"* ]] && ok "harness: refuses a release build" || bad "harness: release build: rc $rc '$out'"
defaults write "$DOM" vmsRoot "$T/vms"; mkdir -p "$T/vms"
out=$("$H" --app "$T/Test.app" --vm "OmacVM M-none" --out "$T/o2" 2>&1); rc=$?
[[ $rc == 2 && $out == *"no test VM"* ]] && ok "harness: refuses a VM not in the test VMs folder" || bad "harness: missing VM: rc $rc '$out'"
out=$("$H" --app "$T/Test.app" --vm x --only pointer,nonsense 2>&1); rc=$?
[[ $rc == 2 && $out == *"no row nonsense"* ]] && ok "harness: refuses an unknown row" || bad "harness: unknown row: rc $rc '$out'"

# --- present-locked.sh: the verdict on qemu.log lines of real runs (M1 Max, 2026-10-31).
L=$R/src/tests/e2e/present-logs
pv() { present_verdict "$@" 2>/dev/null; }
F=(size=5120x2880 guest=5120x2880 locked=1 awake=1 damage=1)
v=$(pv "$L/3215-locked-m1.log" "${F[@]}")
[[ $v == ok$'\t'"0 of 132 checks differed"*"2652 frames in tiles, 429 whole"* ]] && ok "present: 3.2.15 locked, 0 of 132: ok" || bad "present: 3.2.15: '$v'"
v=$(pv "$L/3214-locked-m1.log" "${F[@]}")
[[ $v == FAIL$'\t'"88 of 176 checks differed (first: tiles check 2: 1 tiles, 52825 pixels differ"* ]] && ok "present: 3.2.14 locked, 88 of 176: FAIL" || bad "present: 3.2.14: '$v'"
# 3.2.15's gate row s1-tiles (a hidden start) said ok here: the check was on, no frame went in tiles.
v=$(pv "$L/3215-gate-hidden.log" "${F[@]}")
[[ $v == VOID$'\t'"no frame went in tiles" ]] && ok "present: 3.2.15's hidden gate row: VOID" || bad "present: hidden gate row: '$v'"
ON='OmacVM-VM: info: cocoa: tiled present: on, checked against whole frames (OMACVM_GL_PRESENT_TILES=check)'
FIRST='OmacVM-VM: info: cocoa: tiled present: first frame in tiles (1 of 240, box 8x16)'
printf '%s\n%s\n%s\n' "$ON" "$FIRST" 'OmacVM-VM: info: cocoa: tiles check, so far: 0 of 0 checks differed' > "$T/p00.log"
same "present: 0 of 0: VOID" "VOID	0 checks ran" "$(pv "$T/p00.log" "${F[@]}")"
printf '%s\n%s\n%s\n' "$ON" "$FIRST" 'OmacVM-VM: info: cocoa: tiles check, so far: 0 of 19 checks differed' > "$T/p19.log"
same "present: 19 checks: VOID" "VOID	only 19 checks ran (want at least 20)" "$(pv "$T/p19.log" "${F[@]}")"
printf '%s\n%s\n%s\n' "$ON" "$FIRST" 'OmacVM-VM: info: cocoa: tiles check, so far: 3 of 40 checks differed' > "$T/p3.log"
v=$(pv "$T/p3.log" "${F[@]}"); [[ $v == FAIL$'\t'"3 of 40 checks differed"* ]] && ok "present: a so-far line alone with 3 differed: FAIL" || bad "present: so-far 3: '$v'"
# A check with pixels that differ fails even when a later minute line says 0 (any line counts).
printf '%s\n%s\n%s\n%s\n' "$ON" "$FIRST" 'OmacVM-VM: info: cocoa: tiles check 7: 2 tiles, 12 pixels differ (1 of 7 checks differed)' \
  'OmacVM-VM: info: cocoa: tiles check, so far: 0 of 60 checks differed' > "$T/px.log"
v=$(pv "$T/px.log" "${F[@]}"); [[ $v == FAIL$'\t'*"tiles check 7: 2 tiles, 12 pixels differ"* ]] && ok "present: one differing check line: FAIL" || bad "present: one line: '$v'"
v=$(pv "$L/3215-locked-m1.log" size=6016x3384 guest=5120x2880 locked=1 awake=1 damage=1)
same "present: guest not at the size asked: VOID" "VOID	the guest ran at 5120x2880, not at the size asked, 6016x3384" "$v"
same "present: the lock ended mid-row: VOID" "VOID	the row did not run locked to its end" "$(pv "$L/3215-locked-m1.log" size=5120x2880 guest=5120x2880 locked=0 awake=1 damage=1)"
# No frame in tiles from a VM whose damage does not reach QEMU (an old guest, a new app): named.
printf '%s\n%s\n' "$ON" 'OmacVM-VM: info: cocoa: tiled present, last minute: 0 frames in tiles, 3540 whole, 0 not presented (nothing changed)' > "$T/pw.log"
v=$(pv "$T/pw.log" size=5120x2880 guest=5120x2880 locked=1 awake=1 damage=0)
same "present: no damage driver in the VM: VOID" "VOID	no frame went in tiles (3540 whole frames in the minute lines): the VM sends no damage (without OmacVM's damage driver every frame is whole)" "$v"
same "present: the display asleep at the end: VOID" "VOID	the virtual display was not awake at the end" "$(pv "$L/3215-locked-m1.log" size=5120x2880 guest=5120x2880 locked=1 awake=0 damage=1)"
v=$(pv "$L/3215-locked-m1.log" size=5120x2880 guest=5120x2880)
[[ $v == VOID* ]] && ok "present: facts not recorded: VOID ($v)" || bad "present: facts missing: '$v'"
v=$(pv "$T/none.log" "${F[@]}"); [[ $v == VOID$'\t'"the tiles check was not on"* ]] && ok "present: no log: VOID" || bad "present: no log: '$v'"
# VOID does not pass in result.json.
printf '10:00:00\tdisplay\tok\tvirtual display\n10:00:01\tpresent\tVOID\tno frame went in tiles\n' > "$T/s.tsv"
os_result_json "$T/s.tsv" omacvm-e2e-present-locked "$T/r.json" >/dev/null
same "result: VOID does not pass" False "$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pass"])' "$T/r.json")"
# The guard: a hidden start with the tiles check refuses (exit 2); either alone is fine.
(export OMACVM_COCOA_HIDDEN=1 OMACVM_GL_PRESENT_TILES=check; e2e_present_guard 2>/dev/null); rc=$?
same "guard: hidden start + tiles check: exit 2" 2 "$rc"
(export OMACVM_COCOA_HIDDEN=1; unset OMACVM_GL_PRESENT_TILES; e2e_present_guard 2>/dev/null); same "guard: hidden alone passes" 0 "$?"
(unset OMACVM_COCOA_HIDDEN; export OMACVM_GL_PRESENT_TILES=check; e2e_present_guard 2>/dev/null); same "guard: tiles check alone passes" 0 "$?"
(export OMACVM_COCOA_HIDDEN=0 OMACVM_GL_PRESENT_TILES=check; e2e_present_guard 2>/dev/null); same "guard: OMACVM_COCOA_HIDDEN=0 passes" 0 "$?"
# person.sh's lock read (made-up IORegistry lines).
(source "$R/src/tests/e2e/person.sh"
 _person_lock_raw() { echo '  | "IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"CGSSessionScreenIsLocked"=Yes,"kCGSSessionUserNameKey"="u"})'; }
 person_locked) && ok "person_locked: locked" || bad "person_locked: locked console not seen"
(source "$R/src/tests/e2e/person.sh"
 _person_lock_raw() { echo '  | "IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserNameKey"="u"})'; }
 person_locked) && bad "person_locked: an unlocked console taken as locked" || ok "person_locked: unlocked"

# The display tool: --while-locked, never with a display here (--dry-run, or refused before one).
VD=$T/virtual-display
now() { /usr/bin/python3 -c 'import time; print(int(time.time() * 1000))'; }
waitgone() { local i; for ((i = 0; i < ${2:-40}; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done; return 1; }
if clang -fobjc-arc -framework Foundation -framework CoreGraphics "$R/app/scripts/dev/virtual-display.m" -o "$VD" 2>"$T/vd-build.log"; then
  out=$(OMACVM_TEST_LOCKED=0 "$VD" 2560x1440 --hidpi --while-locked --dry-run 2>&1); rc=$?
  [[ $rc == 3 && $out == *"not locked"* && $out != *id=* ]] && ok "display tool: refuses while not locked (exit 3)" || bad "display tool: not locked: rc $rc '$out'"
  out=$(OMACVM_TEST_LOCKED=1 "$VD" 2560x1440 --hidpi --while-locked 2>&1); rc=$?
  [[ $rc == 2 && $out == *"only with --dry-run"* ]] && ok "display tool: OMACVM_TEST_LOCKED only with --dry-run" || bad "display tool: test lock without --dry-run: rc $rc '$out'"
  out=$("$VD" 100x100 --dry-run 2>&1); rc=$?
  [[ $rc == 2 && $out == *"go with --while-locked"* ]] && ok "display tool: --dry-run only with --while-locked" || bad "display tool: dry run alone: rc $rc '$out'"
  out=$("$VD" --post-note com.apple.screenIsUnlocked 2>&1); rc=$?
  [[ $rc == 2 && $out == *"only test notices"* ]] && ok "display tool: never posts macOS's unlock notice" || bad "display tool: posted macOS's notice? rc $rc '$out'"
  # The private unlock notice ends it within 1 s, the test app's processes killed first.
  mkdir -p "$T/Fake.app/Contents/MacOS"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app.test" "$T/Fake.app/Contents/Info.plist" >/dev/null
  printf '#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n' > "$T/sl.c"
  clang "$T/sl.c" -o "$T/Fake.app/Contents/MacOS/sleeper" 2>/dev/null
  "$T/Fake.app/Contents/MacOS/sleeper" & SP=$!; disown "$SP"
  N=org.omacvm.test.unlock.e2e.$$
  OMACVM_TEST_LOCKED=1 "$VD" 2560x1440 --hidpi --while-locked --dry-run --unlock-note "$N" --kill-app "$T/Fake.app" > "$T/vd1.out" 2>&1 & P=$!
  for ((i = 0; i < 60; i++)); do [[ $(cat "$T/vd1.out") == *id=* ]] && break; sleep 0.05; done
  t0=$(now); "$VD" --post-note "$N"; waitgone "$P" 40; gone=$?; t1=$(now); wait "$P" 2>/dev/null; rc=$?
  out=$(tr '\n' ' ' < "$T/vd1.out")
  if [[ $gone == 0 && $rc == 4 && $out == *"killed=1 quit=unlocked how=notice"* ]] && (( t1 - t0 < 1000 )) && ! kill -0 "$SP" 2>/dev/null; then
    ok "display tool: the private unlock notice: app killed, then out in $((t1 - t0)) ms (exit 4)"
  else bad "display tool: unlock notice: gone $gone rc $rc in $((t1 - t0)) ms, '$out', app process $(kill -0 "$SP" 2>/dev/null && echo "still there" || echo gone)"; fi
  kill -KILL "$SP" 2>/dev/null
  # The lock read every 0.5 s (a missed notice): "unlocked" in the test file ends it.
  echo 1 > "$T/locked"
  OMACVM_TEST_LOCKED=file:$T/locked "$VD" 100x100 --while-locked --dry-run > "$T/vd2.out" 2>&1 & P=$!
  for ((i = 0; i < 60; i++)); do [[ $(cat "$T/vd2.out") == *id=* ]] && break; sleep 0.05; done
  t0=$(now); echo 0 > "$T/locked"; waitgone "$P" 40; gone=$?; t1=$(now); wait "$P" 2>/dev/null; rc=$?
  [[ $gone == 0 && $rc == 4 && $(cat "$T/vd2.out") == *"quit=unlocked how=poll"* ]] && ok "display tool: the lock read ends it in $((t1 - t0)) ms (exit 4)" ||
    bad "display tool: lock read: gone $gone rc $rc in $((t1 - t0)) ms '$(tr '\n' ' ' < "$T/vd2.out")'"
  # It ends with the process that started it.
  ( OMACVM_TEST_LOCKED=1 "$VD" 100x100 --while-locked --dry-run > "$T/vd3.out" 2>&1 & echo $! > "$T/vd3.pid"; wait ) & PP=$!; disown "$PP"
  for ((i = 0; i < 60; i++)); do [[ $(cat "$T/vd3.out" 2>/dev/null) == *id=* ]] && break; sleep 0.05; done
  P=$(cat "$T/vd3.pid"); kill -KILL "$PP"; waitgone "$P" 30; gone=$?
  [[ $gone == 0 && $(cat "$T/vd3.out") == *"quit=parent gone"* ]] && ok "display tool: ends with its parent" || { bad "display tool: parent gone: '$(tr '\n' ' ' < "$T/vd3.out")'"; kill "$P" 2>/dev/null; }
  # The lifetime limit.
  out=$(OMACVM_TEST_LOCKED=1 "$VD" 100x100 --while-locked --dry-run --max-seconds 1 2>&1); rc=$?
  [[ $rc == 6 && $out == *"quit=lifetime"* ]] && ok "display tool: lifetime limit (exit 6)" || bad "display tool: lifetime: rc $rc '$out'"
  # --kill-app takes only the test app.
  out=$(OMACVM_TEST_LOCKED=1 "$VD" 100x100 --while-locked --dry-run --kill-app "$T/Rel.app" 2>&1); rc=$?
  [[ $rc == 2 && $out == *"only the test app"* ]] && ok "display tool: --kill-app refuses the release app" || bad "display tool: kill-app release: rc $rc '$out'"
else bad "display tool does not build: $(head -5 "$T/vd-build.log")"; fi

# The harness refuses before anything runs (exit 2): a hidden start, a wrong size, the release app, no test VM.
P=$R/src/tests/e2e/present-locked.sh
out=$(OMACVM_COCOA_HIDDEN=1 "$P" --vm x --app "$T/Test.app" 2>&1); rc=$?
[[ $rc == 2 && $out == *"hidden window stops presenting"* ]] && ok "present-locked: refuses an inherited hidden start" || bad "present-locked: hidden: rc $rc '$out'"
out=$("$P" --vm x --size 5121x2880 2>&1); rc=$?
[[ $rc == 2 && $out == *"--size"* ]] && ok "present-locked: refuses an odd size" || bad "present-locked: size: rc $rc '$out'"
out=$("$P" --vm x --seconds 120 --drill-unlock 200 2>&1); rc=$?
[[ $rc == 2 && $out == *"--drill-unlock"* ]] && ok "present-locked: a drill after the pointer is refused" || bad "present-locked: drill: rc $rc '$out'"
out=$("$P" --vm x --app "$T/Rel.app" --out "$T/p1" 2>&1); rc=$?
[[ $rc == 2 && $out == *"not the test app"* ]] && ok "present-locked: refuses the release app" || bad "present-locked: release app: rc $rc '$out'"
out=$("$P" --vm "OmacVM M-none" --app "$T/Test.app" --out "$T/p2" 2>&1); rc=$?
[[ $rc == 2 && $out == *"not the test app"* ]] && ok "present-locked: refuses a lane id (org.omacvm.app.test.*)" || bad "present-locked: lane id: rc $rc '$out'"

exit $fail
