#!/bin/bash
# The real present on a locked test Mac, with nobody there: QEMU draws a 5K or
# 6K guest picture through the path a person's full-screen VM uses, with "Draw
# only what changed" in check mode (OMACVM_GL_PRESENT_TILES=check: every 30th
# tile frame is compared with the whole frame), while a guest pointer moves at
# the top right, where 3.2.14 squeezed the tiles (#637).
# A hidden start (OMACVM_COCOA_HIDDEN) stops presenting after its first frames,
# so it tests none of this. Here the test app's window is ordered in on a macOS
# virtual display made for this run (app/scripts/dev/virtual-display.m
# --while-locked): under the lock nothing of it can be seen, and it gets its
# display's frame clock like a window a person looks at.
#   1. Refuses (exit 3, nothing made) unless the session is locked (person.sh),
#      while another VM runs (the person's VM would get a window on the new
#      display), while ~/.omacvm-bench.lock exists, below memory level 40, with
#      memory pressure up or a VM over 4 GB.
#   2. Every real display's mode read (STANDARDS 32), then one virtual display
#      (--size pixels, HiDPI, 60 Hz; a new random serial and its own name) that
#      goes by itself when the session unlocks (the test app killed first), when
#      this script ends, or after 45 minutes. The real displays' modes again: if
#      one changed, the run stops (exit 5): it is not set back, a person looks.
#   3. The test app's settings saved and set (e2e_settings_save, under
#      ~/.omacvm-test-identity.lock): presentTiles, startFullScreen on;
#      pauseWhileHidden, hdr, extraBrightness, mediaControls, vsyncLock,
#      pointerPlane, gpuSafeMode off (GPU safe mode turns tiles off, the pointer
#      layer takes the pointer out of the frame); skipInstallPaths this app.
#   4. The VM started in test mode with its window on the virtual display only
#      (OMACVM_TEST_SKIP_DISPLAYS = the real ones, OMACVM_TEST_MAIN_DISPLAY = ours,
#      OMACVM_PRESENT_HIDDEN=1, OMACVM_GUEST_PAUSE=0, the clipboard apart).
#      Every window of QEMU must lie inside the virtual display, else the app
#      is killed and the row is VOID (the launcher's windows are noted).
#   5. In the VM: the Mac links off (STANDARDS 18a), the guest's mode and
#      whether its damage reaches QEMU read, a uinput pointer moved at the top
#      right for --seconds (default 120), then on until QEMU's next minute line.
#   6. present_verdict (onscreen-lib.sh) on this run's qemu.log lines: ok, FAIL
#      (a check differed) or VOID (it proves nothing: the reason is written).
#   7. The VM stopped, the display gone, the settings and the VM's links put
#      back; the displays' modes, tccd "Notifying for access", UserNotificationCenter
#      windows, WindowServer "setting mode" and nehelper's Local Network lines.
#   src/tests/e2e/present-locked.sh --vm NAME [--size WxH] [--seconds S] [--app PATH] [--out DIR]
#       [--drill-unlock S]
# NAME: a stopped test VM in the test app's VMs folder (e2e_vm_guard). One size
# per run (5120x2880 by default; 6016x3384 is a second run, with a new display).
# --drill-unlock S: S seconds into the pointer, the display tool gets a private
# unlock notice (never macOS's own): the app must be gone before the display,
# and the row is VOID. The caller holds the Mac's VM lock and copies new builds
# over one test app folder (macOS asks for Local Network again for a new
# folder). Results: OUT/summary.tsv, OUT/result.json (kind
# omacvm-e2e-present-locked; VOID does not pass), OUT/qemu.log, OUT/run.log.
# Exit 0 ok, 1 FAIL, 2 usage, 3 not run (see 1), 4 VOID, 5 a real display's
# mode changed (needs a person: OUT/needs-user.txt).
set -uo pipefail
E=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$E/../../.." && pwd)
source "$E/test-vms.sh"
source "$E/onscreen-lib.sh"
source "$E/person.sh"
VM=""; SIZE=5120x2880; SECS=120; OUT=""; DRILL=0
APP=${OMACVM_E2E_APP:-"$HOME/Applications/OmacVM Test.app"}
usage() { sed -n '39,40s/^# \{0,1\}//p' "$0" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    --seconds) SECS=$2; shift 2 ;;
    --app) APP=${2%/}; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --drill-unlock) DRILL=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $VM ]] || usage
[[ $SIZE =~ ^([0-9]+)x([0-9]+)$ ]] && (( ${BASH_REMATCH[1]} % 2 == 0 && ${BASH_REMATCH[2]} % 2 == 0 )) &&
  (( ${BASH_REMATCH[1]} >= 1024 && ${BASH_REMATCH[1]} <= 8192 && ${BASH_REMATCH[2]} >= 640 && ${BASH_REMATCH[2]} <= 8192 )) ||
  { echo "present-locked: --size WxH in pixels, even, 1024-8192 wide (5120x2880, 6016x3384)" >&2; exit 2; }
PW=${SIZE%x*}; PH=${SIZE#*x}
[[ $SECS =~ ^[0-9]+$ ]] && (( SECS >= 60 && SECS <= 900 )) || { echo "present-locked: --seconds 60-900" >&2; exit 2; }
[[ $DRILL =~ ^[0-9]+$ ]] && (( DRILL < SECS )) || { echo "present-locked: --drill-unlock S, less than --seconds" >&2; exit 2; }
export OMACVM_GL_PRESENT_TILES=check
e2e_present_guard || exit 2
unset OMACVM_TEST_LOCKED   # the display tool's test switch: never in a real run
PB=/usr/libexec/PlistBuddy
DOM=$($PB -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
[[ $DOM == org.omacvm.app.test ]] || { echo "present-locked: $APP is not the test app (bundle id '$DOM', want org.omacvm.app.test)" >&2; exit 2; }
APP=$(cd "$APP" && pwd -P)
VMD=$(e2e_vm_guard "$DOM" "$VM") || exit 2
VER=$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
COMMIT=$($PB -c "Print :OmacVMCommit" "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
OUT=${OUT:-$HOME/omacvm-e2e/present-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/bin" || exit 2
OUT=$(cd "$OUT" && pwd)
S=$OUT/summary.tsv; : > "$S"
exec > >(tee -a "$OUT/run.log") 2>&1
START=$(date '+%Y-%m-%d %H:%M:%S'); T0=$(date +%s)

log() { echo "== $(date +%H:%M:%S) $*"; }
res() { printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$1" "$2" "$3" >> "$S"; printf '%-8s %-14s %s\n' "$2" "$1" "$3"; }
with_timeout() {   # SECONDS CMD...: CMD, TERM after SECONDS, KILL 3 s later; its exit code
  local s=$1 p w rc; shift
  "$@" & p=$!
  ( sleep "$s"; kill -TERM "$p" 2>/dev/null; sleep 3; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}
QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
qemu_pid() { LC_ALL=C pgrep -f "$QPAT $VM( |,|$)" | head -1; }
# Every QEMU on this Mac but this VM's (the person's VM above all).
others() { LC_ALL=C pgrep -fl "qemu-system-aarch64|runtime/bin/OmacVM -name|MacOS/OmacVM-VM -name" | LC_ALL=C grep -v -E "$QPAT $VM( |,|$)"; }
# Processes run from inside the test app (the launcher, QEMU, helpers).
inside_app() { ps -axww -o pid=,args= | LC_ALL=C awk -v a="$APP/" '{ p = $1; sub(/^ *[0-9]+ +/, ""); if (index($0, a) == 1) print p }'; }
kill_app() { local p; for p in $(inside_app); do kill -KILL "$p" 2>/dev/null; done; }
lvl() { sysctl -n kern.memorystatus_level 2>/dev/null || echo 0; }
press() { sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'\"" | head -1; }
KEY=$VMD/ssh-key; [[ -f $KEY ]] || KEY=$HOME/.ssh/omacvm
SSHO=(-o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
gssh() { ssh -i "$KEY" -p "$(port)" "${SSHO[@]}" root@127.0.0.1 "$@" < /dev/null; }
G=/root/omacvm-present

# --- 1. may it run here?
locked_now() { person_locked && echo yes || echo no; }
[[ $(locked_now) == yes ]] || { echo "present-locked: the session is not locked: this run puts a window on a display of its own, only on a locked Mac" >&2; exit 3; }
[[ -z $(others) ]] || { echo "present-locked: another VM runs (it would get a window on the new display): $(others | head -1 | cut -c1-120)" >&2; exit 3; }
[[ -z $(qemu_pid) ]] || { echo "present-locked: $VM runs: stop it first" >&2; exit 3; }
[[ -z $(inside_app) ]] || { echo "present-locked: something runs from $APP" >&2; exit 3; }
[[ -e $HOME/.omacvm-bench.lock ]] && { echo "present-locked: a measurement holds ~/.omacvm-bench.lock: $(head -1 "$HOME/.omacvm-bench.lock/owner" 2>/dev/null)" >&2; exit 3; }
MEM=$(sed -n "s/^MEM_MB=//p" "$VMD/vm.env" | tr -d "'\"" | head -1)
[[ $MEM =~ ^[0-9]+$ ]] && (( MEM <= 4096 )) || { echo "present-locked: $VM has ${MEM:-?} MB; at most 4096 here" >&2; exit 3; }
(( $(lvl) >= 40 )) && [[ $(press) == 1 ]] || { echo "present-locked: memory level $(lvl), pressure $(press): not now (want >= 40, 1)" >&2; exit 3; }
TLOCK=$HOME/.omacvm-test-identity.lock; TLOCK_MINE=0
if mkdir "$TLOCK" 2>/dev/null; then
  echo "present-locked $$ $(date +%H:%M) settings of $DOM ($OUT/settings)" > "$TLOCK/owner"; TLOCK_MINE=1
elif [[ $(head -1 "$TLOCK/owner" 2>/dev/null) != "${OMACVM_E2E_TID_OWNER:-present-locked $$} "* ]]; then
  echo "present-locked: the test identity's settings are someone else's now: $(head -1 "$TLOCK/owner" 2>/dev/null)" >&2; exit 3
fi
log "present-locked $SIZE: $VM, $VER ($COMMIT), out $OUT"

# --- tools, built here
VD=$OUT/bin/virtual-display; CENSUS=$OUT/bin/window-census
clang -fobjc-arc -framework Foundation -framework CoreGraphics "$R/app/scripts/dev/virtual-display.m" -o "$VD" > "$OUT/bin/build.log" 2>&1 &&
clang -fobjc-arc -framework Foundation -framework CoreGraphics -F/System/Library/PrivateFrameworks -framework SkyLight \
  "$R/app/scripts/dev/window-census.m" -o "$CENSUS" >> "$OUT/bin/build.log" 2>&1 ||
  { echo "present-locked: the display tools did not build ($OUT/bin/build.log)"; [[ $TLOCK_MINE == 1 ]] && rm -rf "$TLOCK"; exit 3; }


# --- the end of every run that got this far, also on Ctrl-C or a failed step (trap wrapup)
KEYS="presentTiles startFullScreen pauseWhileHidden skipInstallPaths hdr extraBrightness mediaControls vsyncLock pointerPlane gpuSafeMode"
VD_PID=""; VD_ID=""; WATCH=""; SAMPLER=""; SAVED=0; LINKS=0; RC=""; L0=""; QL=$VMD/logs/qemu.log
vd_quit() { sed -n 's/^quit=//p' "$OUT/vd.out" 2>/dev/null | tail -1; }
vd_alive() { [[ -n $VD_PID ]] && kill -0 "$VD_PID" 2>/dev/null; }
listed() { "$VD" --list 2>/dev/null; }
stop_here() { RC=$1; exit "$1"; }
vm_stop() {
  local p i; p=$(qemu_pid)
  if [[ -n $p ]]; then
    with_timeout 20 gssh systemctl poweroff >/dev/null 2>&1
    for ((i = 0; i < 120; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    kill -0 "$p" 2>/dev/null && { kill "$p" 2>/dev/null; sleep 5; kill -KILL "$p" 2>/dev/null; }
  fi
  sleep 2; kill_app; sleep 1
  [[ -z $(qemu_pid) && -z $(inside_app) ]]
}
# Each real display's mode in a --list FILE: "ID px=WxH hz=R", or "ID gone".
mode_of() { awk -v id="$2" '$1 == "display" && $2 == id { m = ""; for (i = 3; i <= NF; i++) if ($i ~ /^(px|hz)=/) m = m (m == "" ? "" : " ") $i; print m; f = 1 } END { if (!f) print "gone" }' "$1"; }
modes_of() { local id; for id in ${REAL//,/ }; do echo "$id $(mode_of "$1" "$id")"; done; }
changed() { diff <(modes_of "$1") <(modes_of "$2") | sed -n 's/^> //p' | tr '\n' ';'; }   # FROM TO: "" = none
needs_user() {   # WHEN WHAT
  echo "$(date '+%Y-%m-%d %H:%M') present-locked: a real display's mode changed $1 the virtual display ($2); before: $(modes_of "$OUT/displays-before.txt" | tr '\n' ';'). Not set back: a person checks it." >> "$OUT/needs-user.txt"
}
wrapup() {
  local st=$? i c gone nt nw ne unc p
  trap - EXIT INT TERM
  [[ -n $RC ]] || RC=$st
  for p in $WATCH $SAMPLER; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  [[ -n $L0 && ! -s $OUT/qemu.log ]] && tail -n +$((L0 + 1)) "$QL" > "$OUT/qemu.log" 2>/dev/null
  if [[ $LINKS == 1 && -n $(qemu_pid) ]]; then with_timeout 30 gssh "bash $G/present-guest.sh links-back; rm -rf $G" >/dev/null 2>&1; fi
  if [[ -n $(qemu_pid)$(inside_app) ]]; then vm_stop || res stop FAIL "the VM or the app did not stop: $(inside_app | tr '\n' ' ')"; fi
  if vd_alive; then
    kill "$VD_PID" 2>/dev/null   # the tool kills what still runs from the app first, then the display goes
    for ((i = 0; i < 50; i++)); do vd_alive || break; sleep 0.2; done
    vd_alive && kill -KILL "$VD_PID" 2>/dev/null
  fi
  if [[ $SAVED == 1 ]]; then
    # shellcheck disable=SC2086
    e2e_settings_restore "$DOM" "$OUT/settings" $KEYS && res settings info "the test app's settings put back" || res settings FAIL "not all settings put back ($OUT/settings)"
  fi
  [[ $TLOCK_MINE == 1 ]] && rm -rf "$TLOCK"
  if [[ -n $VD_ID ]]; then
    for ((i = 0; i < 50; i++)); do [[ -z $(listed | grep "^display $VD_ID ") ]] && break; sleep 0.2; done
    listed > "$OUT/displays-after.txt"
    gone=1; grep -q "^display $VD_ID " "$OUT/displays-after.txt" && gone=0
    c=$(changed "$OUT/displays-before.txt" "$OUT/displays-after.txt")
    if [[ -n $c ]]; then
      res mode-after needs-user "a real display's mode changed after the virtual display went: $c (not set back)"; needs_user after "$c"; RC=5
    else res mode-after ok "every real display's mode as before: $(modes_of "$OUT/displays-after.txt" | tr '\n' ';')"; fi
    (( gone )) || { res display FAIL "virtual display $VD_ID still listed 10 s after its tool ended"; [[ $RC == 0 || $RC == 4 ]] && RC=1; }
    with_timeout 180 /usr/bin/log show --info --start "$START" --predicate \
      '(process == "tccd" AND eventMessage CONTAINS "Notifying for access") OR (process == "WindowServer" AND eventMessage CONTAINS "setting mode") OR process == "nehelper"' \
      > "$OUT/log-side.txt" 2>&1
    nt=$(grep -c 'Notifying for access' "$OUT/log-side.txt"); nw=$(grep -c 'setting mode' "$OUT/log-side.txt")
    ne=$(grep -a 'nehelper' "$OUT/log-side.txt" | grep -a -F "($DOM)" | tail -1 | sed 's/.*nehelper[^:]*: //' | cut -c1-160)
    unc=""; for p in $(pgrep -x UserNotificationCenter); do unc+="$("$CENSUS" "$p" | grep '^windows ') "; done
    res side-effects "$( (( nt == 0 )) && echo info || echo warn)" "tccd 'Notifying for access' $nt; WindowServer 'setting mode' $nw; UserNotificationCenter: ${unc:-not running}; nehelper: ${ne:-no Local Network line for $DOM}"
  fi
  os_result_json "$S" omacvm-e2e-present-locked "$OUT/result.json" version="$VER" commit="$COMMIT" size="$SIZE" \
    seconds=$(( $(date +%s) - T0 )) exit="$RC" >/dev/null
  log "done: exit $RC ($OUT/summary.tsv)"
  exit "$RC"
}
trap wrapup EXIT
trap 'RC=130; exit 130' INT TERM

# --- 2. the displays and the session before; the virtual display
listed > "$OUT/displays-before.txt"
REAL=$(awk '$1 == "display" { printf "%s%s", (n++ ? "," : ""), $2 }' "$OUT/displays-before.txt")
res session-start info "locked: $("$VD" --lock-state) (person.sh: $(locked_now)); HID idle $(person_hid_idle) s; memory level $(lvl), pressure $(press); other VMs: none; macOS $(sw_vers -productVersion), $(sysctl -n hw.model)"
while read -r l; do res display-real info "$l"; done < "$OUT/displays-before.txt"
[[ -n $REAL ]] || { res displays FAIL "no real display listed"; stop_here 1; }
SERIAL=$(( ((RANDOM << 15) | RANDOM) | 0x1000000 ))
NAME="OmacVM Present Test $(printf '%x' "$SERIAL")"
NOTE=""; VDARGS=(); (( DRILL > 0 )) && { NOTE=org.omacvm.test.present.$$; VDARGS=(--unlock-note "$NOTE"); }
"$VD" "$((PW / 2))x$((PH / 2))" --hidpi --name "$NAME" --serial "$SERIAL" --while-locked --max-seconds 2700 \
  --kill-app "$APP" ${VDARGS[@]+"${VDARGS[@]}"} > "$OUT/vd.out" 2>&1 &
VD_PID=$!
for ((i = 0; i < 40; i++)); do VD_ID=$(sed -n 's/^id=//p' "$OUT/vd.out" | head -1); [[ -n $VD_ID ]] && break; vd_alive || break; sleep 0.25; done
[[ -n $VD_ID ]] || { res display VOID "no virtual display: $(tr '\n' ' ' < "$OUT/vd.out" | cut -c1-200)"; stop_here 4; }
sleep 3
listed > "$OUT/displays-with.txt"
VLINE=$(grep "^display $VD_ID " "$OUT/displays-with.txt")
VB=$(sed -n 's/.* bounds=\([-0-9]*,[-0-9]*,[0-9]*x[0-9]*\) .*/\1/p' <<<"$VLINE")
VPX=$(sed -n 's/.* px=\([0-9]*x[0-9]*\) .*/\1/p' <<<"$VLINE")
c=$(changed "$OUT/displays-before.txt" "$OUT/displays-with.txt")
if [[ -n $c ]]; then
  res mode-with needs-user "a real display's mode changed with the virtual display: $c (STANDARDS 32: not set back)"; needs_user with "$c"; stop_here 5
fi
res mode-with ok "every real display's mode as before: $(modes_of "$OUT/displays-with.txt" | tr '\n' ';')"
res display info "virtual display $VD_ID serial 0x$(printf '%x' "$SERIAL") '$NAME': ${VLINE#display $VD_ID }"
if [[ $VPX != "$SIZE" || $VLINE != *" active=1 "* || $VLINE != *" asleep=0 "* ]]; then
  res display VOID "macOS gave ${VPX:-no mode}$( [[ $VLINE == *" active=1 "* ]] || echo " (not active)") for the size asked, $SIZE"; stop_here 4
fi

# The session and memory watched every second: unlocked -> the app killed first, then the display
# (the display tool does the same by itself); memory critical -> the app and its VM killed.
watch_loop() {
  while kill -0 $$ 2>/dev/null; do
    if ! person_locked; then
      echo "$(date +%H:%M:%S) unlocked (IORegistry)" >> "$OUT/watch.txt"; kill_app; kill "$VD_PID" 2>/dev/null; break
    fi
    if (( $(press) >= 4 )); then
      echo "$(date +%H:%M:%S) memory critical (level $(lvl))" >> "$OUT/watch.txt"; kill_app; break
    fi
    sleep 1
  done
}
watch_loop </dev/null >/dev/null 2>&1 & WATCH=$!
broken() {   # why the row cannot go on ("" while it can)
  if [[ -s $OUT/watch.txt ]]; then tail -1 "$OUT/watch.txt"
  elif ! vd_alive; then echo "the display tool ended: $(vd_quit)"; fi
}

# --- 3. settings
# shellcheck disable=SC2086
e2e_settings_save "$DOM" "$OUT/settings" $KEYS || { res settings FAIL "not saved"; stop_here 1; }
SAVED=1
defaults write "$DOM" presentTiles -bool true
defaults write "$DOM" startFullScreen -bool true
defaults write "$DOM" skipInstallPaths -array "$APP"
for k in pauseWhileHidden hdr extraBrightness mediaControls vsyncLock pointerPlane gpuSafeMode; do defaults write "$DOM" "$k" -bool false; done

# --- 4. the VM, its window on the virtual display only
# The app starts qemu.log anew at each start; an older log is kept aside, so the run's lines start at line 1.
[[ -f $QL ]] && mv -f "$QL" "$QL.before-present"
L0=0
[[ -z $(qemu_pid) ]] && rm -f "$VMD/running"   # a QEMU that crashed before left it: "Start Anyway"
with_timeout 30 open -n -g --env "OMACVM_TEST_SKIP_DISPLAYS=$REAL" --env "OMACVM_TEST_MAIN_DISPLAY=$VD_ID" \
  --env OMACVM_PRESENT_HIDDEN=1 --env OMACVM_GUEST_PAUSE=0 --env OMACVM_GL_PRESENT_TILES=check \
  --env OMACVM_TEST_HELPERS_ANSWER=later --env OMACVM_TEST_FAST_NETWORK_ANSWER=normal \
  --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.present "$APP" --args --start --vm "$VM"
for ((i = 0; i < 60; i++)); do [[ -n $(qemu_pid) || -n $(broken) ]] && break; sleep 1; done
QP=$(qemu_pid)
[[ -n $(broken) ]] && { res start VOID "$(broken)"; stop_here 4; }
[[ -n $QP ]] || { res start FAIL "QEMU did not start in 60 s: $(tail -n +$((L0 + 1)) "$QL" 2>/dev/null | tail -3 | tr '\n' ' ' | cut -c1-200)"; stop_here 1; }
up=0
for ((i = 0; i < 150; i++)); do
  [[ -n $(broken) || -z $(qemu_pid) ]] && break
  with_timeout 15 gssh true 2>/dev/null && { up=1; break; }
  sleep 2
done
[[ -n $(broken) ]] && { res start VOID "$(broken)"; stop_here 4; }
(( up )) || { res start FAIL "the VM did not answer over SSH in 300 s$( [[ -z $(qemu_pid) ]] && echo " (QEMU ended)")"; stop_here 1; }
res start ok "QEMU $QP; the app's processes: $(inside_app | tr '\n' ' ')"
sleep 20   # the desktop up, the window placed
# census_off FILE PID: the PID's windows (window-census lines) outside the virtual display; QEMU's on it counted in ONVD.
IFS=, read -r vx vy vwh <<<"$VB"; vw=${vwh%x*}; vh=${vwh#*x}
# (A window with alpha 0 shows nothing anywhere: not counted.)
census_off() {
  local num alpha xy wh d wx wy ww wt
  while read -r _ num _ _ alpha xy wh _ d; do
    [[ $alpha == 0.00 ]] && continue
    wx=${xy%,*}; wy=${xy#*,}; ww=${wh%x*}; wt=${wh#*x}
    if [[ $d == "$VD_ID" ]] && (( wx >= vx - 1 && wy >= vy - 1 && wx + ww <= vx + vw + 1 && wy + wt <= vy + vh + 1 )); then
      [[ $2 == "$QP" ]] && ONVD=$((ONVD + 1))
    else printf 'pid %s window %s at %s %s on display %s; ' "$2" "$num" "$xy" "$wh" "$d"; fi
  done < <(grep '^window ' "$1")
}
# QEMU's windows must all be on it; the launcher's (if any) are noted: on an unlock the display tool
# kills every process of the app before the display goes.
off=""; other=""; ONVD=0
for p in $(inside_app); do
  "$CENSUS" "$p" > "$OUT/census-$p.txt" 2>&1
  census_off "$OUT/census-$p.txt" "$p" > "$OUT/census-off.txt"
  if [[ $p == "$QP" ]]; then off+=$(cat "$OUT/census-off.txt"); else other+=$(cat "$OUT/census-off.txt"); fi
done
if [[ -n $off || $ONVD == 0 ]]; then
  kill_app
  res window VOID "${off:-no QEMU window on the virtual display }(the app killed)"; stop_here 4
fi
res window ok "$ONVD QEMU window(s) inside the virtual display ($VB), none elsewhere; the app's other windows: ${other:-none}"

# --- 5. in the VM
COPYFILE_DISABLE=1 tar -C "$E" -cf - present-guest.sh present-pointer.py |
  ssh -i "$KEY" -p "$(port)" "${SSHO[@]}" root@127.0.0.1 "rm -rf $G && mkdir -p $G && tar -C $G -xf - && chmod 700 $G/*" ||
  { res guest FAIL "the guest helper did not copy"; stop_here 1; }
lo=$(with_timeout 60 gssh "bash $G/present-guest.sh links-off" 2>&1); LINKS=1
lc=$(with_timeout 60 gssh "bash $G/present-guest.sh links-check" 2>&1)
[[ $lc == inactive* ]] || { res links FAIL "Mac links still on in the VM: $lc"; stop_here 1; }
res links ok "Mac links off in the VM (${lo#off: }); $lc"
gm=""; for ((i = 0; i < 20; i++)); do gm=$(with_timeout 20 gssh "bash $G/present-guest.sh mode" 2>/dev/null); [[ $gm == "$SIZE"@* ]] && break; sleep 2; done
dm=$(with_timeout 20 gssh "bash $G/present-guest.sh damage" 2>&1)
res guest info "mode ${gm:-none}; damage: $dm"
GUEST=${gm%%@*}; DAMAGE=${dm%% *}; [[ $DAMAGE == 1 ]] || DAMAGE=0

# The drill: S seconds into the pointer, the private unlock notice; the app's windows sampled meanwhile.
if (( DRILL > 0 )); then
  ( sleep "$DRILL"; "$VD" --post-note "$NOTE" ) &
  ( t_end=$(( $(date +%s) + DRILL + 6 ))
    while (( $(date +%s) < t_end )); do
      for p in $(inside_app); do echo "$(date +%T) pid $p"; "$CENSUS" "$p" | grep '^window '; done
      sleep 0.1
    done ) > "$OUT/drill-census.txt" 2>&1 &
  SAMPLER=$!
fi
# The pointer at the top right; then on in 10 s steps until QEMU writes its next minute line.
sofar() { tail -n +$((L0 + 1)) "$QL" 2>/dev/null | grep -a -c 'tiles check, so far:'; }
pt=$(with_timeout $((SECS + 30)) gssh "python3 -I $G/present-pointer.py $SECS 60" 2>&1 | tail -1)
res pointer info "${pt:-no answer} (top right, $SECS s)"
n1=$(sofar); extra=0
while [[ -z $(broken) ]] && (( $(sofar) <= n1 && extra < 8 )); do
  with_timeout 40 gssh "python3 -I $G/present-pointer.py 10 30" >/dev/null 2>&1; extra=$((extra + 1))
done
(( extra )) && res pointer info "$((extra * 10)) s more until QEMU's next minute line ($( (( $(sofar) > n1 )) && echo "it came" || echo "none"))"
[[ -n $SAMPLER ]] && { wait "$SAMPLER" 2>/dev/null; SAMPLER=""; }
sleep 1
tail -n +$((L0 + 1)) "$QL" > "$OUT/qemu.log" 2>/dev/null
LOCKED=1; [[ -n $(broken) || $(locked_now) != yes ]] && LOCKED=0
listed > "$OUT/displays-end.txt"
AWAKE=0; [[ $(grep "^display $VD_ID " "$OUT/displays-end.txt") == *" active=1 asleep=0 "* ]] && AWAKE=1
grep -a -E 'tiled present|tiles check(, so far|.* [1-9][0-9]* pixels differ)' "$OUT/qemu.log" | tail -12 | cut -c1-200 |
  while read -r l; do res qemu-log info "$l"; done

# --- 6. the verdict
v=$(present_verdict "$OUT/qemu.log" "size=$SIZE" "guest=${GUEST:-none}" "locked=$LOCKED" "awake=$AWAKE" "damage=$DAMAGE")
VR=${v%%$'\t'*}; VW=${v#*$'\t'}
[[ $LOCKED == 1 ]] || VW="$VW: $(broken)"
res present "$VR" "$SIZE, $VER ($COMMIT): $VW"
case $VR in ok) RC=0 ;; FAIL) RC=1 ;; *) RC=4 ;; esac
res session-end info "locked: $("$VD" --lock-state) (person.sh: $(locked_now)); HID idle $(person_hid_idle) s; memory level $(lvl), pressure $(press); the virtual display $( (( AWAKE )) && echo awake || echo "not awake or gone")"
if (( DRILL > 0 )); then
  q=$(cat "$OUT/vd.out"); moved=$(grep '^window ' "$OUT/drill-census.txt" | grep -v -e " display $VD_ID\$" -e ' alpha 0.00 ')
  if [[ $q == *$'\n'killed=[1-9]*$'\n'quit=unlocked\ how=notice* && -z $(inside_app) && -z $moved ]]; then
    res drill ok "the display tool killed the app's $(sed -n 's/^killed=//p' <<<"$q") processes, then the display went (quit=unlocked how=notice); no window of the app on another display in $(grep -c ' pid ' "$OUT/drill-census.txt") samples; nothing runs from the app"
  else
    res drill FAIL "$(tr '\n' ' ' <<<"$q" | cut -c1-160); windows elsewhere: $(head -2 <<<"$moved" | tr '\n' ' '); left: $(inside_app | tr '\n' ' ')"; RC=1
  fi
fi
