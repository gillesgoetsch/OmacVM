#!/bin/bash
# The on-screen release test: what a person sees and clicks in OmacVM.app,
# with real clicks and pointer moves (HID events) and Accessibility on the
# app's own processes, on a test VM. One row per check in summary.tsv, a
# screenshot when a check on screen fails.
#   window          the app's window opens 800 pt wide, at most 800 tall, centred on its display,
#                   and stays 800 wide after a double-click on its title bar (and a second one)
#   update-vm       Update VM in the window (the VM's OmacVM made older first) runs to UPDATED
#   switch-stopped  "WebGPU and GPU compute" switched in the window with the VM stopped; Start in
#                   the window applies it (#445); the second start switches it back
#   vm-size         the VM's window keeps its size after full screen and back, twice (#452)
#   pointer         the Mac's cursor shows nothing over the VM while the guest draws its pointer:
#                   coming in, after a background program shows the cursor (as OmacVM Gestures
#                   did up to 3.1.24), after switching to Finder and back; in the window and in
#                   full screen; with "Graphics without QEMU's lock" off and on (switched in the
#                   window between the two starts)
#   leftovers       nothing of the VM or the app runs on after the VM shut down from inside,
#                   after its window was closed, and after the app quit
# The window's header buttons (Start, Update VM) sit under its toolbar, where a click posted as an event
# does nothing (macOS 15, tried): they get Accessibility's press; switches, the sidebar and the pointer
# get real events.
# On screen only while nobody uses the Mac (no input for 300 s but ours, no
# Jump Desktop or Screen Sharing session, also one left alone, the screen
# unlocked: person.sh). Before each row it looks again: while someone is
# there it hides the app's windows (the VM's too), waits (at most PERSON_WAIT
# s, default 1800) and goes on when the Mac is quiet. Inside a row it only
# looks: someone there ends that row BLOCKED (no wait with a row's window up),
# the next row waits. A visit between two rows gets a "person" row (BLOCKED
# when a row failed meanwhile). Someone who stays: the rest is BLOCKED, and
# update-vm (update-vm.sh, as the window runs it) and leftovers (a start
# without a window) run headless; also with --headless.
# --pause-ci (or OMACVM_E2E_PAUSE_CI=1): this Mac's CI runners stopped for the
# run (ci-runners.sh), started again at the end. A runner still on a job after
# OMACVM_E2E_CI_WAIT s (default 3000) would start its VMs during the rows: the
# rows on screen are BLOCKED then (the headless ones run).
#   src/tests/e2e/onscreen.sh --app "PATH/OmacVM Test.app" --vm NAME [--out DIR]
#       [--only ROW,...] [--headless] [--pause-ci]
# NAME: a stopped test VM in the test app's VMs folder (e2e_vm_guard). The
# caller holds the Mac's VM lock. The app's settings this changes are put back.
# Results: OUT/summary.tsv, OUT/result.json (kind omacvm-e2e-onscreen, pass),
# OUT/shots/, OUT/run.log. Exit 0 passed, 1 a check failed, 2 usage, 5 not
# run in full (BLOCKED rows: someone at the Mac, CI runners on jobs, --headless).
set -uo pipefail
E=$(cd "$(dirname "$0")" && pwd)
source "$E/test-vms.sh"
source "$E/onscreen-lib.sh"
source "$E/person.sh"
ALL="window update-vm switch-stopped vm-size pointer leftovers"
APP=""; VM=""; OUT=""; ONLY=""; HEADLESS=0; PAUSE_CI=${OMACVM_E2E_PAUSE_CI:-0}; CI_WAIT=${OMACVM_E2E_CI_WAIT:-3000}
usage() { sed -n '36,37s/^# \{0,1\}//p' "$0" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --app) APP=${2%/}; shift 2 ;;
    --vm) VM=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --only) ONLY=" ${2//,/ } "; shift 2 ;;
    --headless) HEADLESS=1; shift ;;
    --pause-ci) PAUSE_CI=1; shift ;;
    *) usage ;;
  esac
done
[[ -n $APP && -n $VM ]] || usage
for r in $ONLY; do [[ " $ALL " == *" $r "* ]] || { echo "onscreen: no row $r (rows: $ALL)" >&2; exit 2; }; done
PB=/usr/libexec/PlistBuddy
DOM=$($PB -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
[[ $DOM == org.omacvm.app.test* ]] || { echo "onscreen: $APP is not a test identity build (bundle id '$DOM')" >&2; exit 2; }
VMD=$(e2e_vm_guard "$DOM" "$VM") || exit 2
VER=$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
COMMIT=$($PB -c "Print :OmacVMCommit" "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
OUT=${OUT:-$HOME/omacvm-e2e/onscreen-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/shots" "$OUT/bin" "$OUT/saved" || exit 2
S=$OUT/summary.tsv; : > "$S"
exec > >(tee -a "$OUT/run.log") 2>&1
T=$OUT/bin/onscreen-tool
xcrun swiftc -O "$E/onscreen-tool.swift" -o "$T" >"$OUT/bin/build.log" 2>&1 || { echo "onscreen: the tool did not build ($OUT/bin/build.log)"; exit 2; }
T0=$(date +%s); GONE=""

log() { echo "== $(date +%H:%M:%S) $*"; }
res() { printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$1" "$2" "$3" >> "$S"; printf '%-8s %-22s %s\n' "$2" "$1" "$3"; }
want() { [[ -z $ONLY || $ONLY == *" $1 "* ]]; }

# --- the Mac and its user
hid_idle() { person_hid_idle; }
# Remote sessions (Screen Sharing, port 5900, Jump Desktop; also one left alone) and input that was
# not ours (the watcher's view too): person.sh.
remote() { local r; r=$(person_remote); echo "${r:-none}"; }
locked() { person_locked && echo Yes || echo No; }
away() { [[ $(locked) != Yes && -z $(person_check) ]]; }
who() { echo "HID idle $(hid_idle) s, remote sessions $(remote), screen locked $(locked)"; }
# Our own events, also of a run before (HID idle counts ours as input): person.sh's stamp
# (~/Library/Caches/omacvm-e2e-last-input) says until when the input was ours.
posted() { person_posted 3; }
# A visit between two steps: its row, with the rows that ran meanwhile (summary.tsv: time row result what).
GATE_LINE=0
person_overlap() {   # EVENTS NEXT
  local span r
  span=$(person_span "$S" "$GATE_LINE" 2 3)
  r=$(person_overlap_row "$1" "${span%%$'\t'*}" "${span#*$'\t'}")
  res person "${r%%$'\t'*}" "${r#*$'\t'}"
}
# Between two rows. On screen from here on only while nobody else uses the Mac: someone there -> the
# app's windows hidden and a wait for them to go (at most PERSON_WAIT s); someone who stays -> remembers
# why and says no from then on (the windows stay hidden; the cleanup quits the app).
onscreen_ok() {
  [[ -z $GONE ]] || return 1
  local ev t0; ev=$(_person_new | _person_events); [[ -n $ev ]] && person_overlap "$ev" next
  if ! away; then
    t0=$(date +%s); log "PAUSE on screen: someone uses the Mac ($(who)); waiting up to $(( PERSON_WAIT / 60 )) min"
    hide_ours
    while :; do
      (( $(date +%s) - t0 >= PERSON_WAIT )) && { GONE="someone uses the Mac since $(date -r "$t0" +%H:%M:%S) ($(who))"; log "STOP on screen: $GONE"; return 1; }
      sleep "$PERSON_POLL"; _person_new >/dev/null
      away && { log "RESUME on screen after $(( $(date +%s) - t0 )) s ($(who))"; break; }
    done
    show_ours
  fi
  GATE_LINE=$(wc -l < "$S" | tr -d ' ')
  return 0
}
# Inside a row: a look, no wait (a wait would keep the row's windows, maybe a full-screen VM, in front of
# someone). Someone there -> 1 with MID saying why: the row ends BLOCKED, the next row's onscreen_ok waits.
MID=""
onscreen_mid() {
  [[ -z $GONE ]] || { MID=$GONE; return 1; }
  away && return 0
  MID="someone came to the Mac during the row ($(who))"
  return 1
}
# The app's windows and the VM's out of sight while someone is at the Mac (as Command-H; no input
# events), back when the Mac is quiet again. A hide that does not take is only logged.
HIDDEN=""
hide_ours() {
  local p
  for p in $(launcher_pid) $(qemu_pid); do
    if "$T" hide "$p" >/dev/null 2>&1; then HIDDEN+=" $p"; else log "could not hide pid $p"; fi
  done
  [[ -n $HIDDEN ]] && log "hidden while waiting: pid$HIDDEN"
  return 0
}
show_ours() {
  local p
  for p in $HIDDEN; do kill -0 "$p" 2>/dev/null && { "$T" unhide "$p" >/dev/null 2>&1 || log "could not show pid $p again"; }; done
  HIDDEN=""
  return 0
}
# A picture of the screen, and the words of the app's window (a picture needs Screen Recording for this shell).
CAPTURE=$("$T" can-capture)
shot() {
  [[ $CAPTURE == yes ]] && screencapture -x -C "$OUT/shots/$1.png" 2>/dev/null && sips -Z 1600 "$OUT/shots/$1.png" >/dev/null 2>&1
  [[ -n ${LP:-} ]] && "$T" texts "$LP" > "$OUT/shots/$1.txt" 2>&1
}
spot() {   # NAME X Y: the 240 pt around the pointer, with the cursor
  [[ $CAPTURE == yes ]] && screencapture -x -C -R "$(( $2 - 120 )),$(( $3 - 120 )),240,240" "$OUT/shots/$1.png" 2>/dev/null
}

# --- the app and the VM
psall() { ps -axww -o pid=,args=; }
pid_of() {   # EXECUTABLE [MATCH]: the pid whose command is EXECUTABLE (and has MATCH)
  psall | awk -v x="$1" -v m="${2:-}" '{ p = $1; a = $0; sub(/^ *[0-9]+ +/, "", a)
    if ((a == x || index(a, x " ") == 1) && (m == "" || index(a, m))) { print p; exit } }'
}
launcher_pid() { pid_of "$APP/Contents/MacOS/OmacVM"; }
qemu_pid() { local p; p=$(pid_of "$APP/Contents/MacOS/OmacVM-VM" " -name $VM"); [[ -n $p ]] || p=$(pid_of "$APP/Contents/Resources/runtime/bin/OmacVM" " -name $VM"); echo "$p"; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'\"" | head -1; }
gssh() { ssh -i "$VMD/ssh-key" -i "$HOME/.ssh/omacvm" -p "$(port)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@" </dev/null; }
QLOG=$VMD/logs/qemu.log
# qemu.log of this start only: the test VM's log so far is kept in OUT, then emptied before the start.
qmark() { [[ -s $QLOG ]] && cat "$QLOG" >> "$OUT/qemu-before.log"; : > "$QLOG" 2>/dev/null; }
qnew() { tr -d '\000' < "$QLOG" 2>/dev/null; }
waitfor() {   # SECONDS COMMAND...: until COMMAND succeeds
  local n=$1 i; shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 1; done; "$@"
}
has_qemu() { [[ -n $(qemu_pid) ]]; }
no_qemu() { [[ -z $(qemu_pid) ]]; }
no_launcher() { [[ -z $(launcher_pid) ]]; }
has_launcher() { [[ -n $(launcher_pid) ]]; }
has_window() { [[ -n $(win_of "$LP") ]]; }
updating() { psall | grep -v grep | grep -qF "update-vm.sh $VMD"; }
onoff() { [[ $1 == 1 || $1 == true ]] && echo on || echo off; }
# "Graphics without QEMU's lock" as the app reads it (1 or 0): its key, or without one the app's own
# default (off up to 3.1.25, on after it), from the app's settings dump.
gpu_lock() {
  defaults read "$DOM" gpuOffMainLoop 2>/dev/null && return
  "$APP/Contents/MacOS/OmacVM" --settings-dump > "$OUT/saved/dump.json" 2>/dev/null
  [[ $(plutil -extract app.gpuOffMainLoop raw -o - "$OUT/saved/dump.json" 2>/dev/null) == true ]] && echo 1 || echo 0
}
wid() { awk '{printf "%.0f", $3}' <<<"$1"; }
guest_up() { gssh true 2>/dev/null; }
win_of() { "$T" win "$1" 2>/dev/null | cut -d' ' -f1-4; }
is_full() { [[ $("$T" win "$1" 2>/dev/null) == *full=$2 ]]; }
# What is left of this run besides PID (the launcher, when it stays)
leftovers() { psall | os_leftovers "$APP" "$VMD" "$VM" | awk -v k="${1:-x}" '$1 != k' | cut -c1-200; }
feature() { tr ' ' '\n' < "$VMD/features" 2>/dev/null | grep "^$1=" | tail -1 | cut -d= -f2; }
pending() { cat "$VMD/$1-pending" 2>/dev/null | tr -d '\n'; }

# --- settings this run changes: saved, put back at the end
KEYS="startFullScreen gpuOffMainLoop closeAction skipInstallPaths"
helpers() { psall | awk -v h="$APP/Contents/Helpers/" '{ p = $1; a = $0; sub(/^ *[0-9]+ +/, "", a); if (index(a, h) == 1) print p }'; }
cleanup() {
  # Nothing stops the cleanup half way (a second Ctrl-C, a hangup, a lost stdout after an ssh drop):
  # the CI runners come back at its end.
  trap '' INT TERM HUP PIPE
  local p
  # Helpers of this copy the run started (the app starts its Bridge): stopped, as the copy goes away.
  for p in $(helpers); do [[ " $HELPERS0 " == *" $p "* ]] || kill "$p" 2>/dev/null; done
  p=$(qemu_pid); [[ -n $p ]] && { gssh systemctl poweroff >/dev/null 2>&1; waitfor 90 no_qemu >/dev/null || log "the VM did not shut down"; }
  p=$(launcher_pid); [[ -n $p ]] && { "$T" quit "$p" >/dev/null 2>&1; waitfor 20 no_launcher >/dev/null || kill "$p" 2>/dev/null; }
  # shellcheck disable=SC2086
  e2e_settings_restore "$DOM" "$OUT/saved" $KEYS || log "settings: not all put back"
  [[ -f $OUT/saved/omacvm-version ]] && ! grep -q "^$VER\$" "$VMD/omacvm-version" 2>/dev/null && cp "$OUT/saved/omacvm-version" "$VMD/omacvm-version"
  local ev; ev=$(_person_new | _person_events); [[ -n $ev ]] && person_overlap "$ev" end
  person_watch_stop
  (( ${CI_PAUSED:-0} )) && "$E/ci-runners.sh" resume --holder $$ >> "$OUT/ci-runners.log" 2>&1
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log "onscreen: $APP ($VER, $COMMIT, $DOM), VM $VMD, macOS $(sw_vers -productVersion), $(who), pictures: $([[ $CAPTURE == yes ]] && echo yes || echo "no (no Screen Recording for this shell: the window's words only)")"
[[ -z $(qemu_pid) ]] || { echo "onscreen: $VM runs: shut it down first"; exit 2; }
[[ -z $(launcher_pid) ]] || { echo "onscreen: $APP runs: quit it first"; exit 2; }
# shellcheck disable=SC2086
e2e_settings_save "$DOM" "$OUT/saved" $KEYS || exit 2
defaults write "$DOM" startFullScreen -bool false
defaults write "$DOM" closeAction shutdown
GPU0=$(gpu_lock)
HELPERS0=$(helpers | tr '\n' ' ')
GC0=$(feature gpu-compute); cp "$VMD/omacvm-version" "$OUT/saved/omacvm-version" 2>/dev/null

# --- rows

row_window() {   # the launcher's window (VM stopped)
  local p f s pr f2 f3 x y w h
  p=$LP; f=$(win_of "$p"); [[ -n $f ]] || { res window FAIL "no window"; shot window; return; }
  read -r x y w h <<<"$f"
  s=$("$T" screen $(( x + w / 2 )) $(( y + h / 2 )))
  pr=$(os_window_problems "$f" "$s" | tr '\n' ';')
  [[ -z $pr ]] && res window ok "frame $f on the display's visible $s" || { res window FAIL "frame $f on the display's visible $s: $pr"; shot window-open; }
  # The green button: the window has no full screen, so it zooms, as a title-bar double-click does when
  # set to Zoom. (A double-click posted as HID events does not reach the title bar on macOS 15: tried.)
  onscreen_mid || { res window-zoom BLOCKED "$MID"; return; }
  [[ $("$T" front "$p") == front ]] || { res window-zoom FAIL "the window did not come to the front"; return; }
  posted; "$T" zoom "$p" >/dev/null || { res window-zoom FAIL "no zoom button"; return; }
  sleep 2; f2=$(win_of "$p")
  posted; "$T" zoom "$p" >/dev/null; sleep 2; f3=$(win_of "$p")
  if (( $(wid "$f2") >= 799 && $(wid "$f2") <= 801 && $(wid "$f3") >= 799 && $(wid "$f3") <= 801 )); then
    res window-zoom ok "$f -> $f2 -> $f3"
  else res window-zoom FAIL "$f -> $f2 -> $f3 (not 800 wide)"; shot window-zoom; fi
}

row_update_vm() {   # Update VM in the window: the VM's OmacVM made older first (before the window opened)
  local p=$LP t0 i asked="" held="" r
  if ! r=$("$T" find "$p" AXButton "Update VM" 2>&1); then res update-vm FAIL "no Update VM button (VM's OmacVM $(cat "$VMD/omacvm-version"))"; shot update-vm; return; fi
  [[ $r == enabled=1* ]] || { res update-vm FAIL "Update VM is disabled: $r"; return; }
  : > "$VMD/update.log" 2>/dev/null
  "$T" front "$p" >/dev/null; posted; r=$("$T" press "$p" AXButton "Update VM")
  t0=$(date +%s)
  for ((i = 0; i < 300; i++)); do   # 15 min
    grep -q '^UPDATED ' "$VMD/update.log" 2>/dev/null && break
    grep -q '^ERROR' "$VMD/update.log" 2>/dev/null && break
    (( i > 20 )) && ! updating && no_qemu && break   # ended without a word
    # The kernel question: Later, but only while nobody is at the Mac (asked again 3 s later).
    if [[ -z $asked ]] && "$T" find "$p" AXButton Later >/dev/null 2>&1; then
      if onscreen_mid; then asked="kernel question answered Later"; posted; "$T" press "$p" AXButton Later >/dev/null
      else held=$MID; fi
    fi
    sleep 3
  done
  waitfor 60 no_qemu >/dev/null
  if grep -q '^UPDATED ' "$VMD/update.log" 2>/dev/null && [[ $(tr -d '\n' < "$VMD/omacvm-version") == "$VER" ]]; then
    res update-vm ok "$r; UPDATED in $(( $(date +%s) - t0 )) s, the VM's OmacVM $VER${asked:+, $asked}"
  elif [[ -z $asked && -n $held ]]; then
    res update-vm BLOCKED "$r; the kernel question stayed open: $held"
  else
    res update-vm FAIL "$r; after $(( $(date +%s) - t0 )) s: $(grep -v '^ *$' "$VMD/update.log" 2>/dev/null | tail -3 | tr '\n' '|' | cut -c1-300)"
    shot update-vm; cp "$VMD/update.log" "$VMD/logs/omacvm-update.log" "$OUT/" 2>/dev/null
  fi
}

update_vm_headless() {
  local t0 rc
  t0=$(date +%s)
  OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=$DOM OMACVM_PROGRESS=1 perl -e 'alarm 900; exec @ARGV' /bin/bash "$APP/Contents/Resources/scripts/update-vm.sh" "$VMD" > "$OUT/update-vm.log" 2>&1 < /dev/null; rc=$?
  if (( rc == 0 )) && grep -q '^UPDATED ' "$OUT/update-vm.log" && [[ $(tr -d '\n' < "$VMD/omacvm-version") == "$VER" ]]; then
    res update-vm ok "headless (update-vm.sh, the window's path without the click): UPDATED in $(( $(date +%s) - t0 )) s, the VM's OmacVM $VER"
  else res update-vm FAIL "headless: rc $rc after $(( $(date +%s) - t0 )) s: $(tail -3 "$OUT/update-vm.log" | tr '\n' '|' | cut -c1-300)"; fi
}

switch_stopped() {   # N: "WebGPU and GPU compute" flipped with the VM stopped
  local n=$1 p=$LP r before want
  before=$(feature gpu-compute); [[ $before == on ]] && want=off || want=on
  "$T" front "$p" >/dev/null; posted; "$T" click "$p" AXButton General >/dev/null 2>&1; sleep 1
  r=$("$T" find "$p" AXCheckBox "WebGPU and GPU compute" 2>&1)
  [[ $r == enabled=1* ]] || { res "switch-stopped-$n" FAIL "the switch cannot be used with the VM stopped: $r"; shot "switch-stopped-$n"; return 1; }
  onscreen_mid || { res "switch-stopped-$n" BLOCKED "$MID"; return 1; }
  posted; r=$("$T" click "$p" AXCheckBox "WebGPU and GPU compute")
  waitfor 10 test_eq_feature "$want" >/dev/null
  if [[ $(feature gpu-compute) == "$want" && $(pending gpu-compute) == "$want" ]]; then
    res "switch-stopped-$n" ok "$r; record $before -> $want, applies at the next start"; SW_WANT=$want
  elif [[ $(feature gpu-compute) == "$want" && -z $(pending gpu-compute) ]]; then
    res "switch-stopped-$n" ok "$r; record $before -> $want: what the VM has, nothing to apply"
  else res "switch-stopped-$n" FAIL "$r; record $(feature gpu-compute) (want $want), pending '$(pending gpu-compute)'"; shot "switch-stopped-$n"; return 1; fi
}
test_eq_feature() { [[ $(feature gpu-compute) == "$1" ]]; }

start_in_window() {   # N: Start clicked in the window; the VM's window up, the guest's pointer drawn
  local n=$1 r
  qmark; "$T" front "$LP" >/dev/null; posted; r=$("$T" press "$LP" AXButton Start)
  waitfor 60 has_qemu >/dev/null || { res "start-$n" FAIL "$r; no QEMU after 60 s"; shot "start-$n"; return 1; }
  QP=$(qemu_pid)
  waitfor 30 is_full "$QP" 0 >/dev/null
  waitfor 240 guest_up >/dev/null || { res "start-$n" FAIL "$r; the guest did not come up in 4 min"; shot "start-$n"; return 1; }
  sleep 12   # the desktop and its pointer
  res "start-$n" ok "QEMU $QP, window $(win_of "$QP"), Graphics without QEMU's lock $(onoff "$(gpu_lock)")"
}

switch_applied() {   # N: the start applied the switch
  local n=$1 line i
  for ((i = 0; i < 120; i++)); do
    line=$(qnew | grep -a -E "WebGPU and GPU compute $SW_WANT \(switched while the VM was stopped\): (set up in the VM|not set up)" | tail -1)
    [[ -n $line ]] && break; sleep 2
  done
  if [[ $line == *"set up in the VM"* && -z $(pending gpu-compute) ]]; then res "switch-applied-$n" ok "${line##*OmacVM: }"
  else res "switch-applied-$n" FAIL "qemu.log: ${line:-no line in 4 min}; pending '$(pending gpu-compute)'"; fi
}

row_vm_size() {
  local f0 f i bad=""
  f0=$(win_of "$QP"); [[ -n $f0 ]] || { res vm-size FAIL "no VM window"; return; }
  for i in 1 2; do
    onscreen_mid || { res vm-size BLOCKED "$MID${bad:+; before it: $bad}"; return; }
    "$T" full "$QP" on >/dev/null; waitfor 15 is_full "$QP" 1 >/dev/null || bad+="no full screen ($i); "; sleep 2
    "$T" full "$QP" off >/dev/null; waitfor 15 is_full "$QP" 0 >/dev/null || bad+="did not leave full screen ($i); "; sleep 2
    f=$(win_of "$QP"); os_same_size "$f0" "$f" || bad+="after full screen $i: $f; "
  done
  [[ -z $bad ]] && res vm-size ok "$f0 kept over 2 full screens" || { res vm-size FAIL "before $f0: $bad"; shot vm-size; }
}

# A point in PID's window with nothing else over it (a system prompt can sit over the middle), with room
# around it for the moves: sets x y w h (the window) and cx cy.
spot_in() {
  local fx fy
  read -r x y w h <<<"$(win_of "$1")"
  for fx in 50 30 70 25 75; do for fy in 50 70 30 80; do
    cx=$(( x + w * fx / 100 )); cy=$(( y + h * fy / 100 ))
    "$T" ours "$1" "$cx" "$cy" >/dev/null && "$T" ours "$1" $(( cx + 30 )) $(( cy + 20 )) >/dev/null &&
      "$T" ours "$1" $(( cx - 40 )) "$cy" >/dev/null && return 0
  done; done
  return 1
}
# What is in front, and the words of a system prompt (UserNotificationCenter) if one is up.
cover() {
  local u; u=$(pgrep -x UserNotificationCenter | head -1)
  echo "front pid $("$T" frontpid)${u:+; system prompt: $("$T" texts "$u" 2>/dev/null | head -2 | tr '\n' ' ')}"
}
PT_BAD=""
look() {   # STEP: the Mac shows no cursor over the VM now
  local s; s=$("$T" cursor)
  if os_cursor_hidden "$s"; then PT_OK+="$1; "
  else PT_BAD+="$1: $s; "; local x y; x=${s##* at }; y=${x#*,}; x=${x%,*}; spot "pointer-$PT_N-$(echo "$1" | tr -c 'a-z0-9' '-')" "$x" "$y"; fi
}
in_vm() {   # X Y X2 Y2: a pointer move inside our VM's window
  posted; "$T" move "$1" "$2" "$3" "$4" 12 12 >/dev/null; sleep 1.2
}
row_pointer() {   # N
  PT_N=$1; PT_OK=""; PT_BAD=""
  local f x y w h cx cy finder mode
  mode="Graphics without QEMU's lock $(onoff "$(gpu_lock)")"
  finder=$(pgrep -x Finder | head -1)
  [[ $("$T" front "$QP") == front ]] || { res "pointer-$1" FAIL "the VM did not come to the front"; return; }
  spot_in "$QP" || { res "pointer-$1" BLOCKED "another window covers the VM's window ($(cover))"; return; }
  posted; "$T" move $(( x - 12 )) "$cy" "$cx" "$cy" 20 10 >/dev/null; sleep 1.5; look "window: in"
  "$T" bg-show >/dev/null; in_vm "$cx" "$cy" $(( cx + 30 )) $(( cy + 20 )); look "window: a background program showed it"
  onscreen_mid || { pointer_blocked "$1"; return; }
  [[ -n $finder ]] && { "$T" front "$finder" >/dev/null; sleep 1.5; }
  "$T" front "$QP" >/dev/null; sleep 1; in_vm $(( cx + 30 )) $(( cy + 20 )) "$cx" "$cy"; look "window: Finder and back"
  onscreen_mid || { pointer_blocked "$1"; return; }
  "$T" full "$QP" on >/dev/null; waitfor 15 is_full "$QP" 1 >/dev/null; sleep 2
  spot_in "$QP" || { res "pointer-$1" BLOCKED "another window covers the VM in full screen ($(cover))"; "$T" full "$QP" off >/dev/null; return; }
  in_vm $(( cx - 40 )) "$cy" "$cx" "$cy"; look "full screen: in"
  "$T" bg-show >/dev/null; in_vm "$cx" "$cy" $(( cx + 30 )) $(( cy + 20 )); look "full screen: a background program showed it"
  # Out of full screen first: the next row's wait hides a window, not a Space.
  onscreen_mid || { "$T" full "$QP" off >/dev/null; waitfor 15 is_full "$QP" 0 >/dev/null; pointer_blocked "$1"; return; }
  [[ -n $finder ]] && { "$T" front "$finder" >/dev/null; sleep 2; }
  "$T" front "$QP" >/dev/null; sleep 2; in_vm $(( cx + 30 )) $(( cy + 20 )) "$cx" "$cy"; look "full screen: Finder and back"
  "$T" full "$QP" off >/dev/null; waitfor 15 is_full "$QP" 0 >/dev/null; sleep 2
  if [[ -z $PT_BAD ]]; then res "pointer-$1" ok "$mode: no Mac cursor over the VM at $(echo "$PT_OK" | tr -cd ';' | wc -c | tr -d ' ') checks"
  else res "pointer-$1" FAIL "$mode: the Mac's cursor shows over the VM: $PT_BAD"; fi
}

pointer_blocked() {   # N: the checks so far; the rest not done (a cursor seen already stays a FAIL)
  if [[ -n $PT_BAD ]]; then res "pointer-$1" FAIL "$mode: the Mac's cursor shows over the VM: $PT_BAD (then: $MID)"
  else res "pointer-$1" BLOCKED "$mode: $MID; no Mac cursor at the $(echo "$PT_OK" | tr -cd ';' | wc -c | tr -d ' ') checks before"; fi
}

stopped_left() {   # ROW HOW: after the VM stopped (HOW), nothing of it runs on
  local l
  waitfor 120 no_qemu >/dev/null || { res "$1" FAIL "$2: QEMU still runs after 2 min"; return 1; }
  sleep 5; l=$(leftovers "$(launcher_pid)")
  [[ -z $l ]] && res "$1" ok "$2: QEMU gone, nothing of the VM left" || res "$1" FAIL "$2: still running: $(echo "$l" | tr '\n' '|')"
}
quit_left() {   # ROW: the app quit (as Command-Q), nothing of it runs on
  local p l; p=$(launcher_pid)
  [[ -n $p ]] && { "$T" quit "$p" >/dev/null; waitfor 20 no_launcher >/dev/null || { res "$1" FAIL "the app did not quit in 20 s"; return 1; }; }
  sleep 3; l=$(leftovers)
  [[ -z $l ]] && res "$1" ok "app quit: nothing of it or the VM left" || res "$1" FAIL "after quitting: still running: $(echo "$l" | tr '\n' '|')"
}

gpu_lock_switch() {   # "Graphics without QEMU's lock" switched in the window (VM stopped)
  local r before after
  before=$(gpu_lock)
  "$T" front "$LP" >/dev/null; posted; r=$("$T" click "$LP" AXCheckBox "Graphics without QEMU's lock" 2>&1); sleep 1.5
  after=$(gpu_lock)
  [[ $after != "$before" ]] && res gpu-lock-switch ok "$r; gpuOffMainLoop $before -> $after" || res gpu-lock-switch FAIL "$r; gpuOffMainLoop stays $before"
}

open_window() {
  # The question about this Mac's helpers (the test helpers may not run) never blocks the rows.
  open -n --env OMACVM_POINTER_DEBUG=1 --env OMACVM_TEST_HELPERS_ANSWER=later "$APP" --args --vm "$VM"
  waitfor 30 has_launcher >/dev/null || return 1
  LP=$(launcher_pid)
  waitfor 30 has_window >/dev/null || return 1
  sleep 2
  # A copy outside the Applications folders asks to be installed first; never Install here (it
  # would replace the test app there).
  if "$T" find "$LP" AXButton "Run Without Installing" >/dev/null 2>&1; then
    "$T" front "$LP" >/dev/null; posted; log "install question: $("$T" press "$LP" AXButton "Run Without Installing")"
  fi
  waitfor 20 has_start
}
has_start() { "$T" find "$LP" AXButton Start >/dev/null 2>&1; }

headless_leftovers() {
  qmark
  open -n -g --env OMACVM_COCOA_HIDDEN=1 --env OMACVM_BACKGROUND=1 "$APP" --args --start --vm "$VM"
  waitfor 60 has_qemu >/dev/null || { res leftovers FAIL "headless: no QEMU after 60 s"; return; }
  waitfor 240 gssh true >/dev/null 2>&1 || { res leftovers FAIL "headless: no SSH in 4 min"; return; }
  gssh systemctl poweroff >/dev/null 2>&1
  stopped_left leftovers-stop "headless start, shut down from inside" && quit_left leftovers-quit
}

# --- the run
CI_PAUSED=0
if (( HEADLESS )); then GONE="--headless"
else
  # The CI runners first (their jobs start VMs and load the Mac; one still on a job after the wait: no
  # rows on screen), then someone coming between two steps is written down with the time (person.log).
  if (( PAUSE_CI )); then
    CI_PAUSED=1; log "CI runners: each stopped once its job ends (<= $CI_WAIT s)"
    "$E/ci-runners.sh" pause --wait "$CI_WAIT" --holder $$ ||
      { GONE="this Mac's CI runners still run jobs after $CI_WAIT s"; log "STOP on screen: $GONE"; }
  fi
  if [[ -z $GONE ]]; then PERSON_KEEP_LOG=$OUT/person.log; person_watch_start; onscreen_ok; fi
fi
if [[ -z $GONE ]]; then
  log "on screen: nobody uses the Mac ($(who))"
  want update-vm && echo 3.0.0 > "$VMD/omacvm-version"   # older than the app: the window offers Update VM
  if open_window; then
    # Each row starts after onscreen_ok (between rows: it may wait, the windows hidden); inside a row
    # onscreen_mid only looks.
    want window && onscreen_ok && row_window
    want update-vm && onscreen_ok && row_update_vm
    for n in 1 2; do
      onscreen_ok || break
      SW_WANT=""
      want switch-stopped && { switch_stopped "$n" || true; }
      onscreen_ok || break
      start_in_window "$n" || break
      [[ -n $SW_WANT ]] && switch_applied "$n"
      (( n == 1 )) && want vm-size && onscreen_ok && row_vm_size
      want pointer && onscreen_ok && row_pointer "$n"
      onscreen_ok || break
      if (( n == 1 )); then
        gssh systemctl poweroff >/dev/null 2>&1
        stopped_left leftovers-stop "shut down from inside"
        # The window back as a person gets it: the app quits with its VM (3.1.24), so it is opened
        # again; one that stays is brought to the front (as from the Dock).
        waitfor 10 no_launcher >/dev/null
        if has_launcher; then LP=$(launcher_pid); waitfor 5 has_start >/dev/null || { open "$APP"; waitfor 20 has_start >/dev/null; }
        else open_window || { res reopen FAIL "the app's window did not open again after the VM stopped"; break; }; fi
        sleep 2
        want pointer && onscreen_ok && gpu_lock_switch
      else
        posted; "$T" close "$QP" >/dev/null
        stopped_left leftovers-close "the VM's window closed (closeAction shutdown)"
      fi
    done
    [[ -z $GONE ]] && quit_left leftovers-quit
  else res window FAIL "the app's window did not open"; shot window-none; fi
else
  log "on-screen rows not run: $GONE"
  want update-vm && update_vm_headless
  want leftovers && headless_leftovers
fi
# Rows that did not get to run on screen.
[[ -n $GONE && $GONE != --headless && -n ${LP:-} ]] && res onscreen BLOCKED "stopped part way: $GONE"
for r in $ALL; do
  want "$r" || continue
  cut -f2 "$S" | grep -q -E "^$r(-[a-z0-9-]+)?\$" || res "$r" BLOCKED "not run on screen: ${GONE:-an earlier step failed}"
done
cleanup; trap - EXIT
if [[ $(feature gpu-compute) != "$GC0" ]]; then
  if [[ -n $GONE ]]; then res switch-stopped-back skip "WebGPU and GPU compute left $(feature gpu-compute) (was $GC0): the run stopped part way"
  else res switch-stopped-back FAIL "WebGPU and GPU compute is $(feature gpu-compute), was $GC0"; fi
fi
os_result_json "$S" omacvm-e2e-onscreen "$OUT/result.json" app="$APP" version="$VER" commit="$COMMIT" vm="$VM" \
  macos="$(sw_vers -productVersion)" mac="$(sysctl -n hw.model)" seconds=$(( $(date +%s) - T0 )) only="${ONLY:-all}" \
  onscreen="$([[ -z $GONE ]] && echo yes || echo "no: $GONE")" gpuOffMainLoop0="$GPU0"
cut -f3 "$S" | grep -qx FAIL && exit 1
cut -f3 "$S" | grep -qx BLOCKED && exit 5
exit 0
