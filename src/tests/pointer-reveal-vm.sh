#!/bin/bash
# The Mac's cursor stays hidden over an OmacVM.app VM when something else shows
# it again (omacvm-cocoa-cursor-stays-hidden.patch), with the real cursor, in the
# test app: the VM takes the pointer and QEMU hides the Mac's cursor; then
#   B3  a background process shows it, as OmacVM Gestures did over full-screen
#       VMs (SetsCursorInBackground), and the pointer moves over the VM;
#   B5  it hides it, Finder comes to the front and the VM back, then it shows it.
# Pass: the Mac shows no cursor over the VM (hidden, or an empty image) at rest
# (after B5 within 1 s: QEMU looks every 0.5 s while it has the cursor hidden;
# its image set while another process hid the cursor had not reached the
# screen), 0.1 s after the first move and after moves. 3.1.24 showed its arrow
# in all; the first fix (#460) after B5 at rest until the first move.
# Also, nothing else changed: the boot (before the guest draws its pointer),
# Ctrl+Option+G, the pointer leaving the window, Finder in front and coming back
# show the arrow where they did. --gestures also runs the test app's own OmacVM
# Gestures (it needs Accessibility and Input Monitoring) and, in full screen,
# takes the VM's display out and back with the escape combo (Ctrl+Option+Esc).
#   src/tests/pointer-reveal-vm.sh --vm NAME [--app PATH] [--mode window|full]
#       [--gpu-off-main-loop 0|1] [--gestures [TRIPS]] [--tool PATH] [--out DIR]
# NAME: a stopped test VM of the test app (OmacVM Test.app), in its VMs folder.
# Moves the pointer, clicks and types only over the test VM's window, only on a
# Mac nobody uses (HID idle over 60 s, no Jump Desktop), and stops when someone
# else does. Exit 0 passed, 1 a check failed, 2 usage, 3 not run.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
APP="$HOME/Applications/OmacVM Test.app"; VM=""; MODE=window; GPU=0; TRIPS=0; TOOL=""; OUT=""
usage() { sed -n '17,18s/^# \{0,1\}//p' "$0" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --gpu-off-main-loop) GPU=$2; shift 2 ;;
    --gestures) if [[ ${2:-} =~ ^[0-9]+$ ]]; then TRIPS=$2; shift 2; else TRIPS=5; shift; fi ;;
    --tool) TOOL=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $VM && $MODE =~ ^(window|full)$ && $GPU =~ ^[01]$ ]] || usage
source "$R/src/tests/e2e/test-vms.sh"
PB=/usr/libexec/PlistBuddy
DOM=$($PB -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
[[ $DOM == org.omacvm.app.test ]] || { echo "pointer-reveal: $APP is not the test app (org.omacvm.app.test)" >&2; exit 3; }
VMD=$(e2e_vm_guard "$DOM" "$VM") || exit 3
PAT="(runtime/bin/OmacVM|MacOS/OmacVM-VM|qemu-system-aarch64) -name $VM( |$)"
pgrep -f -- "$PAT" >/dev/null && { echo "pointer-reveal: $VM runs already" >&2; exit 3; }
W=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-reveal.XXXXXX")
OUT=${OUT:-$W}; mkdir -p "$OUT"
if [[ -z $TOOL ]]; then
  TOOL=$W/cursor-tool
  clang -fobjc-arc -framework AppKit -framework ApplicationServices "$R/src/tests/pointer-reveal/cursor-tool.m" -o "$TOOL" || exit 3
fi
T=$TOOL
hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
jump() { pgrep -if 'Jump Desktop' | wc -l | tr -d ' '; }
# When this test last moved the pointer (a run before this one counts as nobody).
STAMP=${TMPDIR:-/tmp}/omacvm-pointer-reveal-input
ours=$(cat "$STAMP" 2>/dev/null); [[ $ours =~ ^[0-9]+$ ]] || ours=0
idle0=$(hid_idle)
(( idle0 > 60 || idle0 + 2 >= $(date +%s) - ours )) && [[ $(jump) == 0 ]] || { echo "pointer-reveal: someone uses this Mac (HID idle $idle0 s, Jump $(jump)): not run" >&2; exit 3; }

KEYS=(gpuOffMainLoop startFullScreen)
e2e_settings_save "$DOM" "$W/saved" "${KEYS[@]}" || exit 3
QPID=""; GPID=""
in_app() { ps -axo pid=,comm= | awk -v a="$APP/" 'index($0, a) {print $1}'; }
stop_vm() {
  local port i
  QPID=$(pgrep -f -- "$PAT" | head -1)
  if [[ -n $QPID ]]; then
    port=$(sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'")
    ssh -i "$HOME/.ssh/omacvm" -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "systemctl poweroff" >/dev/null 2>&1 </dev/null
    for ((i = 0; i < 90; i++)); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
    kill "$QPID" 2>/dev/null
  fi
  sleep 2
  for i in $(in_app); do kill "$i" 2>/dev/null; done
}
cleanup() {
  [[ -n $GPID ]] && kill "$GPID" 2>/dev/null
  stop_vm
  e2e_settings_restore "$DOM" "$W/saved" "${KEYS[@]}" >/dev/null
  [[ $OUT == "$W" ]] && cp "$OUT/log.txt" "${TMPDIR:-/tmp}/pointer-reveal-last.txt" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail=0
say() { echo "$*" | tee -a "$OUT/log.txt"; }
ok()  { say "ok   $*"; }
bad() { say "FAIL $*"; fail=1; }
# Our own input: nobody else may have touched the Mac since (HID idle >= time since our last event).
LAST=$(( $(date +%s) - $(hid_idle) ))
guard() {
  local idle; idle=$(hid_idle)
  [[ $(jump) == 0 ]] || { say "STOP: Jump Desktop runs"; exit 3; }
  (( idle + 2 >= $(date +%s) - LAST )) || { say "STOP: someone used the Mac (HID idle $idle s)"; exit 3; }
}
post() { guard; LAST=$(date +%s); echo "$LAST" > "$STAMP"; "$T" "$@"; }
state() { "$T" state; }
check_none() { local s; s=$(state); if [[ $s == visible=0* || $s == *" empty=1 "* ]]; then ok "$1 ($s)"; else bad "$1: the Mac's cursor shows over the VM ($s)"; fi; }
check_arrow() { local s; s=$(state); if [[ $s == visible=1* && $s == *" empty=0 "* ]]; then ok "$1 ($s)"; else bad "$1: no arrow ($s)"; fi; }
# The app empties qemu.log at each start; emptied here too, so it is this start's.
LOG=$VMD/logs/qemu.log; mkdir -p "$VMD/logs"; : > "$LOG"
newlog() { cat "$LOG" 2>/dev/null; }
# QEMU's last word on the Mac's cursor: hidden or shown (OMACVM_POINTER_DEBUG).
qemu_hid() { [[ $(newlog | grep -E 'omacvm-pointer: Mac cursor (hidden|shown)' | tail -1) == *hidden ]]; }

say "pointer-reveal: $VM, $MODE, gpuOffMainLoop $GPU, app $($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($($PB -c 'Print :OmacVMCommit' "$APP/Contents/Info.plist" 2>/dev/null | cut -c1-8)), macOS $(sw_vers -productVersion)"
defaults write "$DOM" gpuOffMainLoop -bool $([[ $GPU == 1 ]] && echo true || echo false)
defaults write "$DOM" startFullScreen -bool $([[ $MODE == full ]] && echo true || echo false)
if (( TRIPS )); then
  for h in "$APP"/Contents/Helpers/*.app; do
    [[ $($PB -c "Print :CFBundleIdentifier" "$h/Contents/Info.plist" 2>/dev/null) == org.omacvm.test.gestures ]] && G=$h
  done
  [[ -n ${G:-} ]] && open -g -n "$G" && sleep 3
  GPID=$(pgrep -f "$G/Contents/MacOS/" | head -1)
  [[ -n $GPID ]] || { say "no test Gestures in $APP: not run"; exit 3; }
fi
# The pointer in the middle of the main display: the window opens around it.
read -r SW SH < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; Math.round(f.size.width) + " " + Math.round(f.size.height)')
post path $(( SW / 2 )) $(( SH / 2 )) $(( SW / 2 )) $(( SH / 2 )) 0 10
rm -f "$VMD/running"
open -n --env OMACVM_POINTER_DEBUG=1 --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.pointer-reveal --env OMACVM_TEST_HELPERS_ANSWER=later "$APP" --args --start --vm "$VM"

# The boot: before the guest draws its pointer the Mac's cursor is the arrow when
# it moves (macOS may hide a resting one around the window's start). Every 2 s a
# small move, then a look; a look after QEMU's hide does not count.
boot_bad=0; boot_n=0
for ((i = 0; i < 240; i++)); do
  newlog | grep -q 'the guest draws its own pointer now' && break
  QPID=$(pgrep -f -- "$PAT" | head -1)
  if [[ -n $QPID ]] && (( i % 4 == 3 )); then
    post path $(( SW / 2 )) $(( SH / 2 )) $(( SW / 2 + 3 )) $(( SH / 2 + 2 )) 2 10
    post path $(( SW / 2 + 3 )) $(( SH / 2 + 2 )) $(( SW / 2 )) $(( SH / 2 )) 2 10
    sleep 0.15
    s=$(state)
    if ! newlog | grep -q 'omacvm-pointer: Mac cursor hidden'; then
      boot_n=$((boot_n + 1))
      [[ $s == visible=1* && $s == *" empty=0 "* ]] || { boot_bad=$((boot_bad + 1)); say "     boot: $s"; }
    fi
  fi
  sleep 0.5
done
newlog | grep -q 'the guest draws its own pointer now' || { bad "the guest did not draw its pointer within 120 s"; exit 1; }
(( boot_bad == 0 )) && ok "boot: the arrow before the guest draws its pointer ($boot_n looks)" || bad "boot: $boot_bad of $boot_n looks without the arrow"
sleep 3
QPID=$(pgrep -f -- "$PAT" | head -1)
read -r WX WY WW WH < <("$T" win "$QPID")
[[ -n ${WH:-} ]] || { bad "no window of QEMU ($QPID)"; exit 1; }
CX=$(( WX + WW / 2 )); CY=$(( WY + WH / 2 ))
say "     window $WX $WY $WW $WH"
if [[ $MODE == window ]]; then SX=$(( WX - 12 )); else SX=$(( WX + 30 )); fi
take() {   # WHAT: the pointer onto the VM from its edge; QEMU must hide the Mac's cursor
  local k
  post path "$SX" "$CY" "$CX" "$CY" 20 10
  sleep 0.3
  for ((k = 0; k < 12; k++)); do qemu_hid && break; sleep 0.25; done
  if qemu_hid; then sleep 0.3; check_none "$1"
  else bad "$1: QEMU did not hide the Mac's cursor"; fi
}
moves() { post path "$CX" "$CY" $(( CX + 60 )) $(( CY + 30 )) 10 15; post path $(( CX + 60 )) $(( CY + 30 )) "$CX" "$CY" 10 15; }
first_move() { post path "$CX" "$CY" $(( CX + 4 )) $(( CY + 2 )) 0 1; sleep 0.1; }

take "taken: no Mac cursor over the VM"
# B3: a background show.
"$T" bg s >> "$OUT/bg.txt"
check_none "B3 a background show, at rest"
first_move; check_none "B3 ... 0.1 s after the first move"
moves; sleep 0.2; check_none "B3 ... after moves"
# B5: a background hide, Finder and back, a background show.
( "$T" bg h 6 s >> "$OUT/bg.txt" ) & bp=$!
sleep 1.2; open -a Finder; sleep 2.5; "$T" front "$QPID" >/dev/null; wait $bp
sleep 1; check_none "B5 a background hide, Finder, back, a background show: at rest within 1 s"
first_move; check_none "B5 ... 0.1 s after the first move"
moves; sleep 0.2; check_none "B5 ... after moves"

# Nothing else changed: the arrow where the user needs it, none over the VM after.
post key-ctrl-opt-g; sleep 0.5
check_arrow "Ctrl+Option+G: the arrow"
moves; sleep 0.2; check_arrow "... and while it moves over the VM"
if [[ $MODE == window ]]; then
  post path "$CX" "$CY" "$SX" "$CY" 15 10; sleep 0.5; post path "$SX" "$CY" $(( SX - 40 )) "$CY" 4 10
  take "left the window and came back: taken, no Mac cursor"
  post path "$CX" "$CY" "$SX" "$CY" 15 10; sleep 0.5
  check_arrow "the pointer left the window: the arrow"
  take "back over the VM: no Mac cursor"
  open -a Finder; sleep 2
  moves; sleep 0.3; check_arrow "Finder in front, the pointer over the VM: the arrow"
else
  post click "$CX" "$CY"; sleep 0.8
  check_none "a click into the VM takes it again: no Mac cursor"
  open -a Finder; sleep 2.5
  check_arrow "Finder in front: the arrow"
fi
"$T" front "$QPID" >/dev/null; sleep 2; moves; sleep 0.3
check_none "the VM in front again (as Command-Tab): no Mac cursor"
"$T" bg s >> "$OUT/bg.txt"; moves; sleep 0.2
check_none "... and a background show after it"

# With the test app's own Gestures: the escape combo out of the VM's Space and back.
if (( TRIPS )) && [[ $MODE == full ]]; then
  for ((k = 1; k <= TRIPS; k++)); do
    post key-ctrl-opt-esc; sleep 2.5
    check_arrow "escape combo out ($k): the arrow on the other Space"
    post key-ctrl-opt-esc; sleep 2.5
    moves; sleep 0.3
    check_none "escape combo back in ($k): no Mac cursor over the VM"
  done
fi

newlog | grep -E 'cocoa: (pointer|the hidden Mac cursor)|omacvm-pointer: (taken|Mac cursor)' > "$OUT/qemu-pointer.txt"
say "     QEMU: $(grep -c 'Mac cursor hidden' "$OUT/qemu-pointer.txt") hides, $(grep -c 'Mac cursor shown' "$OUT/qemu-pointer.txt") shows, $(grep -c 'the hidden Mac cursor showed' "$OUT/qemu-pointer.txt") times shown by someone else"
(( fail )) && say "pointer-reveal: FAILED" || say "pointer-reveal: all passed"
exit $fail
