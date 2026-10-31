#!/bin/bash
# The VM lives on when the display its window is on is unplugged (#402). Part of
# the release gate (cc-switches.sh, step "unplug"); also alone on a test Mac.
# A macOS virtual display (app/scripts/dev/virtual-display.m: 6K Retina, like a
# Pro Display XDR; a new serial each time) is plugged in and taken away while a
# real VM of the test identity has its window there:
#   full       full screen on it (the menu bar's display), one window per
#              display on the other one: --rounds rounds (default 3)
#   fullpanel  "Full screen including notch" (a made-up notch,
#              OMACVM_TEST_NOTCH_GEOMETRY): 2 rounds; QEMU crashed here (3.1.7)
#   window     a window on it: 1 round
#   head-*     #428's layout: the main window in full screen on the other
#              display, the window for the VM's second display in full screen
#              on the virtual one (the menu bar's display). One VM start for:
#              head-unplug  unplugged and plugged in again, --rounds rounds
#              head-flap    gone and back within 2.5 s, --flap-rounds rounds
#              head-tiny    at 1 x 1 for 3 s and back (a waking display),
#                           --flap-rounds rounds
#              head-locked  the locked path (OMACVM_TEST_LOCK_HOOK=1: the
#                           test Mac is never locked): unplugged while
#                           "locked", "unlocked", plugged in again; and gone
#                           and back while "locked"; 3 rounds each
#              Each round counts QEMU's windows and the full-screen Spaces
#              (app/scripts/dev/window-census.m) twice, 4 s apart: no more
#              than at the start, the main window on the remaining display,
#              the display's window back in full screen with one try once
#              the display is back.
#   fullpanel-builtin  "Full screen including notch" on the Mac's own notched
#              built-in display (a real notch, not made up), the VM's second
#              display on a virtual one (2560x1440, not main): unplugged and
#              plugged in again --rounds rounds; with --builtin-off also the
#              built-in display off for 10 s and back (the lid shut and opened
#              with another display on: app/scripts/dev/builtin-display.m),
#              with --sleep also the displays asleep and awake once (not on a
#              Mac that locks at display sleep); a session found locked after
#              either ends the case (BLOCKED: nobody can unlock it). After
#              each: the last FullPanel line omacvm check reads is
#              "strip covered", no "strip not back" and no "strip lost" (but
#              one that "went with" the display change) since the event, the
#              main window covers the built-in display, the
#              full-screen Spaces and the built-in's current Space as before,
#              the built-in's mode unchanged. Skipped on a Mac without a
#              notched built-in display; not in the default list (--only
#              fullpanel-builtin).
# After each unplug: the same QEMU still runs 8 s later, the VM answers over
# SSH, and no new crash report of the app's QEMU.
#
#   src/tests/e2e/display-unplug.sh --vm NAME [--rounds N] [--flap-rounds N] [--only LIST] [--sleep] [--builtin-off] [--out DIR]
#     --only LIST   cases (comma list): full,fullpanel,window,head,fullpanel-builtin
#                   (default: all but fullpanel-builtin)
#     --sleep       fullpanel-builtin also puts the displays to sleep and wakes them
#     --builtin-off fullpanel-builtin also switches the built-in display off for 10 s
#     --out DIR     summary.tsv and the logs (default ~/omacvm-e2e/unplug-<time>)
# Needs: ~/Applications/"OmacVM Test.app" (org.omacvm.app.test; OMACVM_E2E_APP=PATH
# for another copy of it), NAME stopped in
# its VMs folder, clang (builds the display tool), and the test Mac to itself:
# the caller holds its lock (cc-switches.sh does), nobody uses it, no other VM
# runs (a display going changes every window on the Mac). The test app's
# startFullScreen and the VM's notch-mode are put back as they were.
# Between cases it waits while someone is at the Mac (person.sh); a case that
# failed while someone came and went gets a BLOCKED "person" row.
# Exit 0 only when every unplug passed; 1 a case failed; 2 a wrong call; 3 it
# could not run (another VM, a tool); 5 someone stayed at the Mac (BLOCKED rows).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/person.sh"
R=$(cd "$HERE/../../.." && pwd)

VM=""; ROUNDS=3; FLAPS=10; ONLY=""; OUT=""; SLEEP=0; BOFF=0
while (( $# )); do
  case $1 in
    --sleep) SLEEP=1; shift ;;
    --builtin-off) BOFF=1; shift ;;
    --vm) VM=$2; shift 2 ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --flap-rounds) FLAPS=$2; shift 2 ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "usage: display-unplug.sh --vm NAME [--rounds N] [--flap-rounds N] [--only full,fullpanel,window,head,fullpanel-builtin] [--sleep] [--builtin-off] [--out DIR]" >&2; exit 2 ;;
  esac
done
[[ -n $VM ]] || { echo "display-unplug: --vm NAME (a test VM)" >&2; exit 2; }
[[ $ROUNDS =~ ^[1-9][0-9]?$ && $FLAPS =~ ^[1-9][0-9]?$ ]] || { echo "display-unplug: --rounds and --flap-rounds 1-99" >&2; exit 2; }
want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }

export OMACVM_TEST_IDENTITY=1
APP=${OMACVM_E2E_APP:-"$HOME/Applications/OmacVM Test.app"}   # another copy of the test identity: OMACVM_E2E_APP
APPID=org.omacvm.app.test
KEY=$HOME/.ssh/omacvm
NOTCH=645.5x824.5x34x1470x956   # a 14" MacBook Pro's notch, in points
OUT=${OUT:-$HOME/omacvm-e2e/unplug-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
: > "$OUT/summary.tsv"
n_fail=0; n_blocked=0
res() {   # STEP ok|FAIL|BLOCKED|skip DETAIL
  printf '%s\t%s\t%s\n' "unplug-$1" "$2" "$3" >> "$OUT/summary.tsv"
  printf '%-34s %-7s %s\n' "unplug-$1" "$2" "$3"
  [[ $2 == FAIL ]] && n_fail=$((n_fail + 1))
  [[ $2 == BLOCKED ]] && n_blocked=$((n_blocked + 1))
  return 0
}
# Someone at the Mac between two cases (person.sh; the caller's watcher when cc-switches.sh runs this).
GATE_LINE=0
person_overlap() {   # EVENTS NEXT
  local span r
  span=$(person_span "$OUT/summary.tsv" "$GATE_LINE" 1 2)
  r=$(person_overlap_row "$1" "${span%%$'\t'*}" "${span#*$'\t'}")
  res person "${r%%$'\t'*}" "${r#*$'\t'}"
}
gate() {   # CASE: 0 when it may run (else its BLOCKED row is written)
  [[ -z $PERSON_WHY ]] && person_gate "unplug-$1" && { GATE_LINE=$(wc -l < "$OUT/summary.tsv" | tr -d ' '); return 0; }
  res "$1" BLOCKED "not run: $PERSON_WHY"; return 1
}
log() { echo "== $(date +%H:%M:%S) $*"; }

VMD=$( (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") 2>&1) || { echo "display-unplug: $VMD" >&2; exit 2; }
QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
qemu_pid() { LC_ALL=C pgrep -f "$QPAT $VM( |$)" | head -1; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'"; }
gssh() { ssh -i "$KEY" -p "$(port)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@" < /dev/null; }
# Every QEMU on this Mac but this VM's (the person's VM above all): none may run.
others() { LC_ALL=C pgrep -fl "qemu-system-aarch64|runtime/bin/OmacVM -name|MacOS/OmacVM-VM -name" | LC_ALL=C grep -v -E "$QPAT $VM( |$)"; }
[[ -z $(others) ]] || { echo "display-unplug: another VM runs (a display going moves its windows too): $(others | head -1)" >&2; exit 3; }
[[ -z $(qemu_pid) ]] || { echo "display-unplug: $VM runs: stop it first" >&2; exit 3; }
crashes() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^OmacVM-.*\.ips$'; }

# The display tool, built here.
VD="$OUT/virtual-display"
clang -fobjc-arc -framework Foundation -framework CoreGraphics "$R/app/scripts/dev/virtual-display.m" -o "$VD" \
  > "$OUT/build-tool.log" 2>&1 || { echo "display-unplug: could not build the display tool ($OUT/build-tool.log)" >&2; exit 3; }
# Windows and Spaces, counted (#428).
CENSUS="$OUT/window-census"
clang -fobjc-arc -framework Foundation -framework CoreGraphics -F/System/Library/PrivateFrameworks -framework SkyLight \
  "$R/app/scripts/dev/window-census.m" -o "$CENSUS" >> "$OUT/build-tool.log" 2>&1 ||
  { echo "display-unplug: could not build the census tool ($OUT/build-tool.log)" >&2; exit 3; }
VD_PID=""; VD_ID=""; VD_OUT="$OUT/vd.out"
plug() {   # the virtual display, with the menu bar on it
  local i
  "$VD" 3008x1692 --hidpi --main --name "OmacVM Unplug Test $RANDOM" --serial $((0x4280000 + RANDOM)) > "$VD_OUT" 2>&1 &
  VD_PID=$!
  for ((i = 0; i < 30; i++)); do VD_ID=$(sed -n 's/^id=//p' "$VD_OUT"); [[ -n $VD_ID ]] && break; sleep 0.5; done
  [[ -n $VD_ID ]] || { kill "$VD_PID" 2>/dev/null; VD_PID=""; return 1; }
  sleep 3
}
unplug() { [[ -n $VD_PID ]] && { kill "$VD_PID" 2>/dev/null; wait "$VD_PID" 2>/dev/null; }; VD_PID=""; VD_ID=""; }
vd_signal() {   # USR1 (gone) | USR2 (back) | HUP (1 x 1 and back): waits for the tool's state line
  local n i; n=$(grep -c '^state=' "$VD_OUT"); kill -"$1" "$VD_PID" 2>/dev/null || return 1
  for ((i = 0; i < 20; i++)); do (( $(grep -c '^state=' "$VD_OUT") > n )) && break; sleep 0.25; done
  grep '^state=' "$VD_OUT" | tail -1
}
# The locked path without locking the test Mac (app/scripts/dev/test-lock.m).
LOCKTOOL="$OUT/test-lock"
clang -fobjc-arc -framework Foundation "$R/app/scripts/dev/test-lock.m" -o "$LOCKTOOL" >> "$OUT/build-tool.log" 2>&1 ||
  { echo "display-unplug: could not build the lock tool ($OUT/build-tool.log)" >&2; exit 3; }
lockhook() { "$LOCKTOOL" "$1"; }
# The built-in display off and back (fullpanel-builtin --builtin-off).
BDISP="$OUT/builtin-display"
if (( BOFF )); then
  clang -fobjc-arc -framework AppKit -framework CoreGraphics "$R/app/scripts/dev/builtin-display.m" -o "$BDISP" \
    >> "$OUT/build-tool.log" 2>&1 || { echo "display-unplug: could not build the built-in display tool ($OUT/build-tool.log)" >&2; exit 3; }
fi
# The Mac's session locked (the screen lock): nobody can unlock it from here.
session_locked() { person_locked; }

# Put back what this changes, also on Ctrl-C.
FS_BEFORE=$(defaults read "$APPID" startFullScreen 2>/dev/null || echo unset)
NOTCH_BEFORE=$(cat "$VMD/notch-mode" 2>/dev/null || echo none)
restore() {
  person_watch_stop
  unplug
  local p; p=$(qemu_pid)
  if [[ -n $p ]]; then
    gssh "systemctl poweroff" >/dev/null 2>&1
    for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  fi
  if [[ $FS_BEFORE == unset ]]; then defaults delete "$APPID" startFullScreen 2>/dev/null
  else defaults write "$APPID" startFullScreen -bool "$( [[ $FS_BEFORE == 1 ]] && echo true || echo false)"; fi
  if [[ $NOTCH_BEFORE == none ]]; then rm -f "$VMD/notch-mode"; else echo "$NOTCH_BEFORE" > "$VMD/notch-mode"; fi
}
trap restore EXIT

start() {   # window|full|fullpanel, on the virtual display; head: full on the other one; fullpanel-builtin
  local mode=$1 i env=(--env "OMACVM_TEST_MAIN_DISPLAY=$VD_ID" --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e)
  rm -f "$VMD/notch-mode"
  case $mode in
    window) defaults write "$APPID" startFullScreen -bool false ;;
    full) defaults write "$APPID" startFullScreen -bool true ;;
    head) defaults write "$APPID" startFullScreen -bool true
          env=(--env "OMACVM_TEST_MAIN_DISPLAY=$OTHER_ID" --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e
               --env OMACVM_TEST_LOCK_HOOK=1) ;;
    fullpanel) defaults write "$APPID" startFullScreen -bool true; echo fullpanel > "$VMD/notch-mode"
               env+=(--env "OMACVM_TEST_NOTCH_GEOMETRY=$NOTCH") ;;
    fullpanel-builtin) defaults write "$APPID" startFullScreen -bool true; echo fullpanel > "$VMD/notch-mode"
               env=(--env "OMACVM_TEST_MAIN_DISPLAY=$BUILTIN_ID" --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e
                    --env OMACVM_TEST_LOCK_HOOK=1) ;;
  esac
  (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") >/dev/null || return 1
  # A QEMU that crashed (an earlier round) left the run marker: the start would ask "Start Anyway".
  [[ -z $(qemu_pid) ]] && rm -f "$VMD/running"
  open -n "${env[@]}" --env OMACVM_TEST_HELPERS_ANSWER=later "$APP" --args --start --vm "$VM"
  for ((i = 0; i < 40; i++)); do [[ -n $(qemu_pid) ]] && break; sleep 1; done
  [[ -n $(qemu_pid) ]] || return 1
  # The desktop up (its display agent moves the outputs), then a moment for full screen.
  for ((i = 0; i < 90; i++)); do gssh "test -d /run/user/\$(id -u \$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env))/hypr" 2>/dev/null && { sleep 25; return 0; }; sleep 2; done
  return 1
}
launcher_stop() { local p; for p in $(LC_ALL=C pgrep -f "$APP/Contents/MacOS/OmacVM --start --vm $VM\$"); do kill "$p" 2>/dev/null; done; }
stop() {
  local p i; p=$(qemu_pid); [[ -n $p ]] || { launcher_stop; return 0; }
  gssh "systemctl poweroff" >/dev/null 2>&1
  for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  ! kill -0 "$p" 2>/dev/null
}
case_run() {   # NAME MODE ROUNDS
  local name=$1 mode=$2 rounds=$3 pid r c0 l0 new
  log "$name: $mode on a virtual display, $rounds unplug(s)"
  plug || { res "$name" FAIL "no virtual display"; return; }
  start "$mode" || { res "$name" FAIL "the VM did not come up on the virtual display"; unplug; stop; return; }
  pid=$(qemu_pid)
  if [[ $mode == fullpanel ]]; then
    local area; area=$(grep -h 'OmacVM: notch area:' "$VMD/logs/qemu.log" | tail -1)
    if [[ $area != *"notch area: fullpanel"* ]]; then
      res "$name" skip "the VM did not start in Full screen including notch (Omanotch on and Update VM give it): ${area:-no notch area line}"
      unplug; stop; return
    fi
    res "$name-start" ok "$(cut -c1-100 <<<"$area")"
  fi
  for ((r = 1; r <= rounds; r++)); do
    c0=$(crashes); l0=$(wc -l < "$VMD/logs/qemu.log")
    unplug
    sleep 8
    tail -n +$((l0 + 1)) "$VMD/logs/qemu.log" > "$OUT/$name-$r-qemu.log" 2>/dev/null
    new=$(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep '^OmacVM-.*\.ips$' | head -1)
    if ! kill -0 "$pid" 2>/dev/null; then
      res "$name-$r" FAIL "QEMU ended at the unplug$( (( $(crashes) > c0 )) && echo ": crash report $new")"
      break
    elif ! gssh true; then
      res "$name-$r" FAIL "QEMU runs, but the VM does not answer over SSH"
      break
    elif (( $(crashes) > c0 )); then
      res "$name-$r" FAIL "a new crash report: $new"
      break
    fi
    res "$name-$r" ok "QEMU $pid runs on, the VM answers"
    (( r < rounds )) && { plug || { res "$name-plug-$r" FAIL "no virtual display"; break; }; sleep 12; }
  done
  unplug
  stop || res "$name-stop" FAIL "the VM did not shut down"
  sleep 3
}

# #428: count QEMU's windows and the full-screen Spaces; the main window on the other display.
census() { "$CENSUS" "$(qemu_pid)"; }
fullspaces() { sed -n 's/^spaces [0-9]* fullscreen //p' <<<"$1"; }
qwindows() { sed -n 's/^windows \([0-9]*\) .*/\1/p' <<<"$1"; }
on_display() { grep -c "^window .* alpha 1.00 .* display $2\$" <<<"$1"; }
tries() { tail -n +$(($1 + 1)) "$VMD/logs/qemu.log" | grep -c 'full screen for its window (try'; }
# NAME BACK L0 [TRIES]: alive, no growth over 4 s, as at the start; BACK=1: the display is back
# and its window in full screen after TRIES full-screen tries since qemu.log line L0 (default 1;
# "0-1": either), BACK=0: none.
head_check() {
  local name=$1 back=$2 l0=$3 want_t=${4:-1} a b fa fb na nb t want_f where
  if ! kill -0 "$HPID" 2>/dev/null; then res "$name" FAIL "QEMU ended"; return 1; fi
  gssh true || { res "$name" FAIL "QEMU runs, but the VM does not answer over SSH"; return 1; }
  (( $(crashes) > C0 )) && { res "$name" FAIL "a new crash report"; return 1; }
  a=$(census); sleep 4; b=$(census)
  printf '%s\n--\n%s\n' "$a" "$b" > "$OUT/$name.census"
  fa=$(fullspaces "$a"); fb=$(fullspaces "$b"); na=$(qwindows "$a"); nb=$(qwindows "$b")
  t=$(tries "$l0"); want_f=$(( back ? F0 : F0 - 1 )); where=gone
  (( back )) && where=back || want_t=0
  tail -n +$((l0 + 1)) "$VMD/logs/qemu.log" | grep -i 'omacvm: display\|full screen' > "$OUT/$name.qemu.log"
  if (( fb > fa || nb > na )); then res "$name" FAIL "growing: full-screen Spaces $fa -> $fb, windows $na -> $nb in 4 s"
  elif (( fb > F0 || nb > N0 + 2 )); then res "$name" FAIL "more than at the start: full-screen Spaces $fb (start $F0), windows $nb (start $N0)"
  elif (( fb != want_f )); then res "$name" FAIL "full-screen Spaces $fb, want $want_f (start $F0; the display $where)"
  elif (( $(on_display "$b" "$OTHER_ID") < 1 )); then res "$name" FAIL "no VM window shown on the remaining display $OTHER_ID"
  elif (( back )) && (( $(on_display "$b" "$VD_ID") < 1 )); then res "$name" FAIL "the display's window is not back on it"
  elif (( LOGS_TRIES )) && { [[ $want_t == 0-1 ]] && (( t > 1 )) || [[ $want_t != 0-1 ]] && (( t != want_t )); }; then
    res "$name" FAIL "$t full-screen tries for the display's window (want $want_t)"
  else res "$name" ok "full-screen Spaces $fb (start $F0), windows $nb (start $N0), tries $( (( LOGS_TRIES )) && echo "$t" || echo "not logged (before 3.1.15)")"; return 0; fi
  return 1
}
case_head() {   # #428's layout, one VM start for every head case
  local r l0 st a
  log "head: main window in full screen on display $OTHER_ID, the second display's window on a virtual one"
  plug || { res head FAIL "no virtual display"; return; }
  start head || { res head FAIL "the VM did not come up"; unplug; stop; return; }
  HPID=$(qemu_pid); C0=$(crashes); sleep 10
  # 3.1.15 and newer log each full-screen try and have the test lock hook.
  LOGS_TRIES=0; grep -q 'omacvm: displays: test lock hook on' "$VMD/logs/qemu.log" && LOGS_TRIES=1
  a=$(census); F0=$(fullspaces "$a"); N0=$(qwindows "$a"); echo "$a" > "$OUT/head-start.census"
  if (( F0 != FBASE + 2 )) || (( $(on_display "$a" "$VD_ID") < 1 )); then
    res head-start FAIL "not both in full screen: full-screen Spaces $F0 (before the VM $FBASE)"; unplug; stop; return
  fi
  res head-start ok "both in full screen: full-screen Spaces $F0, QEMU windows $N0"
  if want head-unplug; then
    for ((r = 1; r <= ROUNDS; r++)); do
      l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal USR1); sleep 6
      head_check "head-unplug-$r" 0 "$l0" || break
      l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal USR2); VD_ID=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$st"); sleep 12
      head_check "head-unplug-$r-back" 1 "$l0" || break
    done
  fi
  if want head-flap; then
    for ((r = 1; r <= FLAPS; r++)); do
      l0=$(wc -l < "$VMD/logs/qemu.log"); vd_signal USR1 >/dev/null; sleep 1.5
      st=$(vd_signal USR2); VD_ID=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$st"); sleep 12
      head_check "head-flap-$r" 1 "$l0" || break
    done
  fi
  if want head-tiny; then
    st=$(vd_signal HUP); sleep 1
    a=$("$CENSUS" | grep "^display $VD_ID ")   # the tool's own view of its size can lag
    if [[ $st != state=tiny* || $a != *" 1x1" ]]; then
      res head-tiny skip "the virtual display does not go to 1 x 1: ${st:-no answer}; ${a:-not listed}"
      [[ $st == state=tiny* ]] && vd_signal HUP >/dev/null
    else
      vd_signal HUP >/dev/null; sleep 12
      for ((r = 1; r <= FLAPS; r++)); do
        l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal HUP); sleep 2; vd_signal HUP >/dev/null; sleep 12
        # macOS may not tell QEMU about a 1 x 1 mode this short (then nothing moves): 0 or 1 tries
        head_check "head-tiny-$r" 1 "$l0" 0-1 || break
        (( r == 1 )) && res head-tiny-mode ok "1 x 1 for 2-3 s each round: $a"
      done
    fi
  fi
  if want head-locked && (( ! LOGS_TRIES )); then
    res head-locked skip "this build has no test lock hook (before 3.1.15)"
  elif want head-locked; then
    for ((r = 1; r <= 3; r++)); do
      l0=$(wc -l < "$VMD/logs/qemu.log"); lockhook lock; sleep 1
      if ! tail -n +$((l0 + 1)) "$VMD/logs/qemu.log" | grep -q 'no window changes while locked or asleep (test: locked)'; then
        res "head-locked-$r" FAIL "QEMU did not see the test lock"; lockhook unlock; break
      fi
      vd_signal USR1 >/dev/null; sleep 8
      a=$(census)
      if (( $(fullspaces "$a") > F0 || $(tries "$l0") > 0 )); then
        res "head-locked-$r" FAIL "while locked: full-screen Spaces $(fullspaces "$a") (start $F0), $(tries "$l0") full-screen tries"; lockhook unlock; break
      fi
      lockhook unlock; sleep 4
      head_check "head-locked-$r-unlocked" 0 "$l0" || break
      l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal USR2); VD_ID=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$st"); sleep 12
      head_check "head-locked-$r-back" 1 "$l0" || break
      # gone and back while locked: nothing moves until the unlock
      l0=$(wc -l < "$VMD/logs/qemu.log"); lockhook lock; sleep 1; vd_signal USR1 >/dev/null; sleep 1.5
      st=$(vd_signal USR2); VD_ID=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$st"); sleep 6
      a=$(census)
      if (( $(fullspaces "$a") > F0 || $(tries "$l0") > 0 )); then
        res "head-locked-flap-$r" FAIL "while locked: full-screen Spaces $(fullspaces "$a"), $(tries "$l0") tries"; lockhook unlock; break
      fi
      # macOS may have moved its window's Space away and back (nothing to do) or not (made again: 1 try)
      lockhook unlock; sleep 12
      head_check "head-locked-flap-$r" 1 "$l0" 0-1 || break
    done
  fi
  unplug
  stop || res head-stop FAIL "the VM did not shut down"
  sleep 3
}

# fullpanel-builtin: the strip beside the real notch after display changes.
fp_line() { grep -E '^omacvm: full panel: (strip covered|strip lost|display change:|.*normal full screen)' "$VMD/logs/qemu.log" | tail -1; }
# The lines since the event hold a strip lost for good, or a strip not back (a loss the next
# line turns into a display change, "the strip lost ... went with it", is none).
fp_bad() {
  [[ $1 == *"strip not back"* ]] ||
    (( $(grep -c 'full panel: strip lost:' <<<"$1") > $(grep -c 'full panel: display change: the strip lost' <<<"$1") ))
}
builtin_size() { awk -v id="$BUILTIN_ID" '$1 == "display" && $2 == id {print $NF; exit}' <<<"$1"; }
builtin_space() { awk -v id="$BUILTIN_ID" '$1 == "current" && $2 == id {print $3 " " $4; exit}' <<<"$1"; }
# NAME L0 WANT_F: alive, the strip covered again since qemu.log line L0, the main window over the
# whole built-in, WANT_F full-screen Spaces, the built-in's current Space as at the start.
fp_check() {
  local name=$1 l0=$2 want_f=$3 a i since last size full
  for ((i = 0; i < 30; i++)); do
    since=$(tail -n +$((l0 + 1)) "$VMD/logs/qemu.log")
    last=$(fp_line)
    [[ $last == *"strip covered"* ]] && ! fp_bad "$since" && break
    sleep 1
  done
  tail -n +$((l0 + 1)) "$VMD/logs/qemu.log" | grep -i 'full panel\|omacvm: display' > "$OUT/$name.qemu.log"
  if ! kill -0 "$HPID" 2>/dev/null; then res "$name" FAIL "QEMU ended"; return 1; fi
  gssh true || { res "$name" FAIL "QEMU runs, but the VM does not answer over SSH"; return 1; }
  (( $(crashes) > C0 )) && { res "$name" FAIL "a new crash report"; return 1; }
  a=$(census); echo "$a" > "$OUT/$name.census"
  size=$(builtin_size "$a"); full=$(fullspaces "$a")
  if fp_bad "$since"; then
    res "$name" FAIL "$(grep -h 'strip lost\|strip not back' "$OUT/$name.qemu.log" | tail -1 | cut -c1-140)"
  elif [[ $last != *"strip covered"* ]]; then res "$name" FAIL "the last line check reads: ${last:-none}"
  elif ! grep -q "^window .* ${BUILTIN_ORIGIN} ${size} display $BUILTIN_ID\$" <<<"$a"; then
    res "$name" FAIL "no VM window over the whole built-in display ($BUILTIN_ORIGIN $size)"
  elif (( full != want_f )); then res "$name" FAIL "full-screen Spaces $full, want $want_f (at the start $F0)"
  elif [[ $(builtin_space "$a") != "$S0" ]]; then res "$name" FAIL "the built-in's current Space $(builtin_space "$a"), at the start $S0"
  else res "$name" ok "$(cut -c1-90 <<<"${last#omacvm: full panel: }"); Spaces $full, current as at the start"; return 0; fi
  return 1
}
case_fullpanel_builtin() {
  local r l0 a st area
  BUILTIN_ID=$("$CENSUS" | awk '$1 == "builtin" {print $2; exit}')
  if [[ -z $BUILTIN_ID || $("$APP/Contents/Resources/tools/mac-notch" 2>/dev/null) != notch ]]; then
    res fullpanel-builtin skip "this Mac has no built-in display with a notch"; return
  fi
  BUILTIN_ORIGIN=$("$CENSUS" | awk -v id="$BUILTIN_ID" '$1 == "display" && $2 == id {print $(NF - 1); exit}')
  log "fullpanel-builtin: including notch on built-in display $BUILTIN_ID, the second display on a virtual one"
  "$VD" 2560x1440 --name "OmacVM Notch Test $RANDOM" --serial $((0x4290000 + RANDOM)) > "$VD_OUT" 2>&1 &
  VD_PID=$!
  for ((r = 0; r < 30; r++)); do VD_ID=$(sed -n 's/^id=//p' "$VD_OUT"); [[ -n $VD_ID ]] && break; sleep 0.5; done
  [[ -n $VD_ID ]] || { unplug; res fullpanel-builtin FAIL "no virtual display"; return; }
  sleep 3
  start fullpanel-builtin || { res fullpanel-builtin FAIL "the VM did not come up"; unplug; stop; return; }
  HPID=$(qemu_pid); C0=$(crashes); sleep 10
  area=$(grep -h 'OmacVM: notch area:' "$VMD/logs/qemu.log" | tail -1)
  if [[ $area != *"notch area: fullpanel"* ]]; then
    res fullpanel-builtin skip "the VM did not start in Full screen including notch (Omanotch on and Update VM give it): ${area:-no notch area line}"
    unplug; stop; return
  fi
  a=$(census); echo "$a" > "$OUT/fullpanel-builtin-start.census"
  F0=$(fullspaces "$a"); S0=$(builtin_space "$a")
  if [[ $(fp_line) != *"strip covered"* ]]; then
    res fullpanel-builtin-start FAIL "no strip covered at the start: $(fp_line)"; unplug; stop; return
  fi
  res fullpanel-builtin-start ok "$(cut -c1-100 <<<"$(fp_line)"); full-screen Spaces $F0"
  for ((r = 1; r <= ROUNDS; r++)); do
    l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal USR1); sleep 8
    fp_check "fullpanel-builtin-unplug-$r" "$l0" $((F0 - 1)) || break
    l0=$(wc -l < "$VMD/logs/qemu.log"); st=$(vd_signal USR2); VD_ID=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$st"); sleep 15
    fp_check "fullpanel-builtin-replug-$r" "$l0" "$F0" || break
  done
  if (( BOFF )); then
    # The user's trigger: the built-in leaves the display set and comes back (macOS puts it back
    # when the tool ends). Its mode must be the same after (macOS keeps one per set of displays).
    local m0 m1
    m0=$("$BDISP" mode); l0=$(wc -l < "$VMD/logs/qemu.log")
    if "$BDISP" off 10 > "$OUT/fullpanel-builtin-off.tool" 2>&1; then
      sleep 12
      fp_check fullpanel-builtin-off "$l0" "$F0"
    else
      res fullpanel-builtin-off FAIL "the built-in display did not go off and back: $(tail -1 "$OUT/fullpanel-builtin-off.tool")"
    fi
    m1=$("$BDISP" mode)
    [[ $m1 == "$m0" ]] || res fullpanel-builtin-off-mode FAIL "the built-in's mode changed ($m0 -> $m1): left as it is, tell the person"
    if session_locked; then
      res fullpanel-builtin-off-session BLOCKED "the session is locked after the built-in display went off: no further rows"
      SLEEP=0
    fi
  fi
  if (( SLEEP )); then
    if [[ $(sysadminctl -screenLock status 2>&1) != *"screenLock is off"* ]]; then
      res fullpanel-builtin-sleep skip "this Mac locks at display sleep (the rest would need a password)"
    else
      # The wake is ours (person.sh: not someone at the Mac).
      l0=$(wc -l < "$VMD/logs/qemu.log"); pmset displaysleepnow; sleep 10; person_posted 5; caffeinate -u -t 3; sleep 20
      fp_check fullpanel-builtin-sleep "$l0" "$F0"
      session_locked && res fullpanel-builtin-sleep-session BLOCKED "the session is locked after display sleep: no further rows"
    fi
  fi
  unplug
  stop || res fullpanel-builtin-stop FAIL "the VM did not shut down"
  sleep 3
}

person_watch_start
want full && gate full && case_run full full "$ROUNDS"
want fullpanel && gate fullpanel && case_run fullpanel fullpanel 2
want window && gate window && case_run window window 1
[[ -n $ONLY && $ONLY == *",fullpanel-builtin,"* ]] && gate fullpanel-builtin && case_fullpanel_builtin
if { want head || want head-unplug || want head-flap || want head-tiny || want head-locked; } && gate head; then
  [[ -n $ONLY && $ONLY != *",head,"* ]] || ONLY=",head-unplug,head-flap,head-tiny,head-locked,"
  OTHER_ID=$("$CENSUS" | awk '$1 == "display" && $4 == "active" {print $2; exit}')
  FBASE=$(fullspaces "$("$CENSUS")")
  if [[ -z $OTHER_ID ]]; then res head skip "no display of this Mac to keep (head cases)"; else case_head; fi
fi
ev=$(_person_new | _person_events); [[ -n $ev ]] && person_overlap "$ev" end
person_watch_stop
log "done: $n_fail failed, $n_blocked blocked ($OUT/summary.tsv)"
(( n_fail > 0 )) && exit 1
(( n_blocked > 0 )) && exit 5
exit 0
