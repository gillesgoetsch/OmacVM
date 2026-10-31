#!/bin/bash
# The e2e harnesses' "someone at the Mac" checks (src/tests/e2e/person.sh) and
# the CI runner pause (src/tests/e2e/ci-runners.sh), with made-up sources: a
# fake remote session (Screen Sharing, port 5900, Jump Desktop), a fake HID
# idle time, fake launchctl and pgrep. No screen, VM or runner needed.
#   src/tests/e2e-person.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
WATCHERS=()
# The made-up app's settings domain (onscreen.sh rows): gone at the end, its file too (in the real home:
# cfprefsd does not follow HOME).
DOM=""; PREFS=$HOME/Library/Preferences
undom() { [[ -n $DOM ]] && { defaults delete "$DOM" >/dev/null 2>&1; rm -f "$PREFS/$DOM.plist"; }; return 0; }
trap 'for p in ${WATCHERS[@]+"${WATCHERS[@]}"}; do kill "$p" 2>/dev/null; done; undom; rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
same() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }
has() { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1: want '$2' in '$3'"; fi; }

export HOME=$T/home; mkdir -p "$HOME"
unset OMACVM_E2E_IGNORE_IDLE PERSON_DIR PERSON_WATCH_PID
source "$R/src/tests/e2e/person.sh"

# ---- the made-up Mac: files say what its sources report
F=$T/fake; mkdir -p "$F"; : > "$F/pmset"; : > "$F/ps"; : > "$F/tcp"
echo $(( $(date +%s) - 1000 )) > "$F/last-input"
_person_pmset() { cat "$F/pmset"; }
_person_ps() { cat "$F/ps"; }
_person_tcp() { cat "$F/tcp"; }
_person_idle_raw() { echo $(( $(date +%s) - $(cat "$F/last-input") )); }
quiet_mac() { : > "$F/pmset"; : > "$F/ps"; : > "$F/tcp"; }
TAB=$'\t'

# ---- person_verdict: IDLE REMOTE OWN FOREIGN NOW
same "verdict: idle 400 s, nobody" "" "$(person_verdict 400 "" 0 0 10000)"
has "verdict: idle 20 s, never ours" "input 20 s ago, not ours" "$(person_verdict 20 "" 0 0 10000)"
same "verdict: idle 3 s, ours until 2 s ago" "" "$(person_verdict 3 "" 9998 0 10000)"
has "verdict: idle 3 s, ours until 60 s ago" "not ours" "$(person_verdict 3 "" 9940 0 10000)"
has "verdict: a remote session, however long idle" "remote session: jump-desktop" "$(person_verdict 5000 jump-desktop 0 0 10000)"
has "verdict: the watcher saw foreign input 100 s ago, ours after it" "not ours" "$(person_verdict 2 "" 9999 9900 10000)"
same "verdict: the watcher's foreign input 400 s ago" "" "$(person_verdict 400 "" 0 9600 10000)"
same "verdict: OMACVM_E2E_IGNORE_IDLE=1" "" "$(OMACVM_E2E_IGNORE_IDLE=1 person_verdict 1 vnc-5900 0 0 10000)"

# ---- person_remote: each kind of session, and what must not count
same "remote: none" "" "$(person_remote)"
echo '   pid 412(screensharingd): [0x1] 00:00:09 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
same "remote: Screen Sharing's assertion" "screen-sharing" "$(person_remote)"
quiet_mac
echo "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd${TAB}/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd" > "$F/ps"
same "remote: screensharingd runs (no assertion yet)" "screen-sharing" "$(person_remote)"
quiet_mac
# nettop -m tcp -l 1 -L 1 -n, as macOS 27 prints it
printf '18:06:28.587078,tcp4 192.168.1.20:5900<->192.168.1.31:52144,en0,Established,1280195,5739135,0,0,7768,40.59 ms,131072,\n' > "$F/tcp"
same "remote: an established connection on 5900" "vnc-5900" "$(person_remote)"
printf '18:06:28.586544,tcp4 *:5900<->*:*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,\n18:06:28.586492,tcp6 *.5900<->*.*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,\n' > "$F/tcp"
same "remote: 5900 only listening" "" "$(person_remote)"
quiet_mac
echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect${TAB}/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --rtcproxy --port 0" > "$F/ps"
same "remote: Jump Desktop's rtcproxy" "jump-desktop" "$(person_remote)"
echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/desktopproxy${TAB}desktopproxy --session 4" > "$F/ps"
same "remote: Jump Desktop's desktopproxy" "jump-desktop" "$(person_remote)"
{ echo "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect${TAB}/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --service"
  echo "Core Audio Driver (JumpAudio.driver)${TAB}Core Audio Driver (JumpAudio.driver)"
  echo "/usr/bin/pgrep${TAB}pgrep -f JumpConnect.*(rtcproxy|desktopproxy)"
  echo "/bin/bash${TAB}/bin/bash kit/mini-run.sh screensharingd Jump rtcproxy"; } > "$F/ps"
same "remote: Jump's idle service, its audio driver, a script naming them" "" "$(person_remote)"
quiet_mac
echo '   pid 412(screensharingd): [0x1] 00:00:09 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
printf '18:06:28.594041,tcp6 fe80::1%%en0.5900<->fe80::2%%en0.52144,en0,Established,249\n' > "$F/tcp"
same "remote: two kinds at once" "screen-sharing,vnc-5900" "$(person_remote)"
quiet_mac

# ---- person_posted: our own input hides nothing that came after it
person_posted 5
o=$(cat "$PERSON_OWN"); now=$(date +%s)
(( o >= now + 4 && o <= now + 5 )) && ok "posted: ours until now + 5 s" || bad "posted: '$o' (now $now)"
person_posted 1
same "posted: a shorter window does not shorten a longer one" "$o" "$(cat "$PERSON_OWN")"
echo 0 > "$PERSON_OWN"

# ---- the watcher: a fake HID idle source, foreign input and a remote connect logged with their times
PERSON_TICK=0.2 PERSON_IDLE_MIN=3 PERSON_POLL=0.2
person_watch_start; WATCHERS+=("$PERSON_WATCHER")
[[ -d $PERSON_DIR && -n $PERSON_WATCH_PID ]] && ok "watch: started (shared through PERSON_DIR)" || bad "watch: not started"
sleep 0.6
# Our own input: stamped first, then HID idle drops.
person_posted 3; date +%s > "$F/last-input"; sleep 0.8
same "watch: our own input is not logged" "" "$(cat "$PERSON_DIR/watch.log")"
# Someone's: HID idle drops with no stamp of ours.
echo 0 > "$PERSON_OWN"; echo $(( $(date +%s) - 50 )) > "$F/last-input"; sleep 0.6
inp=$(date +%s); echo "$inp" > "$F/last-input"; sleep 0.8
has "watch: foreign input logged" "input" "$(cut -f2 "$PERSON_DIR/watch.log")"
# The time logged is the input's, to the second, not the clock at this check (a minute on when the
# input came at hh:mm:59: CI failed so once). The watcher reads the clock twice (its now, then the
# idle time), and on a busy Mac more than a second can pass between the two: the line can say up to
# two seconds before the input.
e=$(awk -F'\t' '$2 == "input" { t = $1 } END { print t + 0 }' "$PERSON_DIR/watch.log")
(( e <= inp && e >= inp - 2 )) && ok "watch: ... at the input's second" || bad "watch: input at $inp, logged at '$e'"
has "watch: ... with its time" "HID input at $(date -r "$e" +%H:%M:%S)" "$(cat "$PERSON_DIR/watch.log")"
printf '18:06:28.1,tcp4 10.0.0.2:5900<->10.0.0.9:50000,en0,Established,1,1\n' > "$F/tcp"; sleep 1.5
has "watch: a Screen Sharing connect logged" "vnc-5900" "$(grep "${TAB}remote${TAB}" "$PERSON_DIR/watch.log")"
quiet_mac; sleep 1
has "watch: ... and its end" "none" "$(grep "${TAB}remote${TAB}" "$PERSON_DIR/watch.log" | tail -1)"

# ---- person_gate: overlap reported once, pause while someone is there, resume when quiet, give up
OVER=""; person_overlap() { OVER="$2: $1"; }
echo $(( $(date +%s) - 100 )) > "$F/last-input"
PERSON_WAIT=10 person_gate row-a > "$T/gate1.txt"; rc=$?
same "gate: quiet again -> goes on" 0 "$rc"
has "gate: the visit since the last gate goes to person_overlap" "row-a: HID input at" "$OVER"
has "gate: ... the connect as well" "vnc-5900" "$OVER"
OVER=""; PERSON_WAIT=10 person_gate row-b > /dev/null
same "gate: the same visit is not reported twice" "" "$OVER"
# A Screen Sharing session opens: the gate pauses, and goes on when it ends.
echo '   pid 412(screensharingd): [0x1] 00:00:01 PreventUserIdleDisplaySleep named: "Remote user is connected"' > "$F/pmset"
( sleep 1.5; : > "$F/pmset" ) &
t0=$(date +%s); PERSON_WAIT=20 person_gate row-c > "$T/gate2.txt"; rc=$?; t1=$(date +%s)
same "gate: a remote session -> pause, then on when it ends" 0 "$rc"
has "gate: ... PAUSE logged with the reason" "PAUSE before row-c: remote session: screen-sharing" "$(cat "$T/gate2.txt")"
has "gate: ... RESUME logged" "RESUME before row-c" "$(cat "$T/gate2.txt")"
(( t1 - t0 >= 1 )) && ok "gate: ... it waited" || bad "gate: did not wait (${t1}-${t0})"
# Someone types and stays: the gate gives up after PERSON_WAIT.
( for i in 1 2 3 4 5 6 7 8 9 10; do date +%s > "$F/last-input"; sleep 0.3; done ) & typing=$!
sleep 0.3
PERSON_WAIT=2 person_gate row-d > "$T/gate3.txt"; rc=$?
same "gate: someone stays -> gives up" 1 "$rc"
has "gate: ... and says why" "someone at the Mac since" "$PERSON_WHY"
has "gate: ... GIVE UP logged" "GIVE UP before row-d" "$(cat "$T/gate3.txt")"
wait "$typing"
# A harness started by this one (modifier-keys.sh by cc-switches.sh) joins the same watcher.
cat > "$T/child.sh" <<EOF
source "$R/src/tests/e2e/person.sh"
person_watch_start
echo "\$PERSON_DIR \$PERSON_WATCHER"
EOF
same "watch: a child harness uses the caller's watcher" "$PERSON_DIR " "$(bash "$T/child.sh")"
d=$PERSON_DIR; person_watch_stop
[[ ! -d $d ]] && ! kill -0 "${WATCHERS[0]}" 2>/dev/null && ok "watch: stopped, its folder gone" || bad "watch: still there"

# ---- person_span and person_overlap_row: the rows a visit touched; a FAIL among them is BLOCKED
S=$T/sum.tsv
printf 'a\tok\t-\nb\tok\t-\n' > "$S"
same "span: the rows after FROM, none failed" "a b$TAB" "$(person_span "$S" 0 1 2)"
r=$(person_overlap_row "HID input at 10:00:00" "a b" "")
same "overlap: only ok rows -> a skip row" "skip" "${r%%$TAB*}"
has "overlap: ... that names them and the visit" "rows a b ran while someone was at the Mac (HID input at 10:00:00)" "$r"
same "overlap: no rows since the last gate -> a skip row" "skip" "$(person_overlap_row ev "" "" | cut -f1)"
printf 'x\tFAIL\tbefore\nc\tok\t-\nd\tFAIL\twrong\ne\tskip\t-\n' > "$S"
same "span: rows before the gate's line are not blamed" "c d e${TAB}d" "$(person_span "$S" 1 1 2)"
r=$(person_overlap_row "vnc-5900" "c d e" "d")
same "overlap: a FAIL row -> a BLOCKED row" "BLOCKED" "${r%%$TAB*}"
has "overlap: ... that names it" "FAIL rows d ran while someone was at the Mac (vnc-5900)" "$r"
# The harnesses' own res and person_overlap (taken from each file): the FAIL row stays a FAIL.
E=$R/src/tests/e2e
harness_rows() {   # FILE: a FAIL before the last gate, an ok and a FAIL after it, then a visit
  sed -n '/^res() {/,/^}/p; /^person_overlap() {/,/^}/p' "$1" > "$T/h.sh"
  ( OUT=$T/h; rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/summary.tsv"; PFX=""
    n_ok=0; n_fail=0; n_blocked=0; n_skip=0
    source "$T/h.sh"
    res x FAIL before > /dev/null; GATE_LINE=1
    res c ok - > /dev/null; res d FAIL wrong > /dev/null
    person_overlap "HID input at 10:00:00" next > /dev/null
    echo "fail=$n_fail blocked=$n_blocked"; cut -f1-2 "$OUT/summary.tsv" | tr '\t\n' ': '; echo
    grep -c 'FAIL rows.*x' "$OUT/summary.tsv" )
}
h=$(harness_rows "$E/cc-switches.sh")
has "cc-switches: a visit over a FAIL row adds a BLOCKED person row" "x:FAIL c:ok d:FAIL person:BLOCKED" "$h"
has "cc-switches: ... the FAIL rows stay (pass stays false)" "fail=2 blocked=1" "$h"
same "cc-switches: ... the row before the gate is not blamed" 0 "${h##*$'\n'}"
h=$(harness_rows "$E/modifier-keys.sh")
has "modifier-keys: a visit over a FAIL case adds a BLOCKED person row" "keys-x:FAIL keys-c:ok keys-d:FAIL keys-person:BLOCKED" "$h"
has "modifier-keys: ... the FAIL rows stay" "fail=2 blocked=1" "$h"
same "modifier-keys: ... the case before the gate is not blamed" 0 "${h##*$'\n'}"

# ---- cc-switches' child_end: a child harness's exit code next to its rows
sed -n '/^child_end() {/,/^}/p' "$E/cc-switches.sh" > "$T/child_end.sh"
ce() {   # RC SUMMARY LOG: the rows child_end adds
  ( ROWS=""; res() { ROWS+="$1 $2;"; }
    source "$T/child_end.sh"
    printf "$2" > "$T/ce-sum.tsv"; printf '%s\n' "$3" > "$T/ce.log"
    child_end keys modifier-keys.sh "$1" "$T/ce-sum.tsv" "$T/ce.log" 2>&1; echo "$ROWS" )
}
same "child: 0 -> no row" "" "$(ce 0 'keys-a\tok\t-\n' '')"
same "child: 1 with a FAIL row -> no row more" "" "$(ce 1 'keys-a\tFAIL\t-\n' '')"
same "child: 5 (someone stayed) with a BLOCKED row -> no row more" "" "$(ce 5 'keys-a\tBLOCKED\t-\n' '')"
same "child: 3 (could not run) next to a BLOCKED row -> FAIL" "keys FAIL;" "$(ce 3 'keys-a\tBLOCKED\t-\n' 'modifier-keys: VM does not run')"
same "child: 1 without a FAIL row -> FAIL" "keys FAIL;" "$(ce 1 'keys-a\tok\t-\n' '')"
same "child: 5 without a BLOCKED row -> FAIL" "keys FAIL;" "$(ce 5 'keys-a\tok\t-\n' '')"
same "child: a crash (139) next to a FAIL row -> FAIL" "keys FAIL;" "$(ce 139 'keys-a\tFAIL\t-\n' '')"
same "child: its time limit while it waited for someone -> BLOCKED" "keys BLOCKED;" "$(ce 142 'keys-a\tok\t-\n' '== 10:00:00 PAUSE before keys-b: input 3 s ago, not ours')"
same "child: its time limit with no wait -> FAIL" "keys FAIL;" "$(ce 142 'keys-a\tok\t-\n' 'x')"

# ---- ci-runners.sh with a fake launchctl and pgrep
B=$T/bin; L=$T/loaded; W=$T/busy; A=$T/agents; mkdir -p "$B" "$L" "$W" "$A"
cat > "$B/launchctl" <<EOF
#!/bin/bash
# fake: loaded runners are files in $L
echo "\$*" >> "$T/launchctl.log"
case \$1 in
  print) [[ -e "$L/\${2##*/}" ]] ;;
  # launchd tears a service down after bootout returns (FAKE_ASYNC: a second later)
  bootout) [[ -e "$L/\${2##*/}" ]] || exit 1
    if [[ -n \${FAKE_ASYNC:-} ]]; then ( sleep 1; rm -f "$L/\${2##*/}" ) & else rm -f "$L/\${2##*/}"; fi ;;
  bootstrap) touch "$L/\$(plutil -extract Label raw -o - "\$3")" ;;
esac
EOF
cat > "$B/pgrep" <<EOF
#!/bin/bash
# fake: a runner folder with a job is a file in $W
p=\${@: -1}; d=\${p%/bin/Runner.Worker}; [[ -e "$W/\${d##*/}" ]]
EOF
chmod +x "$B/launchctl" "$B/pgrep"
for n in 1 2; do
  plutil -create xml1 "$A/actions.runner.o-r.mini-$n.plist"
  plutil -insert Label -string "actions.runner.o-r.mini-$n" "$A/actions.runner.o-r.mini-$n.plist"
  plutil -insert WorkingDirectory -string "/x/actions-runner-$n" "$A/actions.runner.o-r.mini-$n.plist"
  touch "$L/actions.runner.o-r.mini-$n"
done
touch "$W/actions-runner-2"   # runner 2 has a job
CR() { PATH=$B:$PATH CI_AGENTS=$A CI_STATE=$T/ci-state CI_GUARD_TICK=0.2 CI_POLL=0.5 "$R/src/tests/e2e/ci-runners.sh" "$@"; }
upto() { local i; for ((i = 0; i < $1 * 10; i++)); do "${@:2}" && return 0; sleep 0.1; done; return 1; }
running() { ls "$L" | tr '\n' ' ' | sed 's/ $//'; }
both_back() { [[ $(running) == "actions.runner.o-r.mini-1 actions.runner.o-r.mini-2" && ! -e $T/ci-state ]]; }
CR pause --wait 0 --holder $$ > "$T/ci1.txt"; rc=$?
same "ci: a runner on a job is not stopped (exit 4 after --wait)" 4 "$rc"
[[ ! -e $L/actions.runner.o-r.mini-1 && -e $L/actions.runner.o-r.mini-2 ]] && ok "ci: the idle runner stopped, the busy one kept" || bad "ci: $(ls "$L" | tr '\n' ' ')"
rm -f "$W/actions-runner-2"
CR pause --wait 30 --holder $$ > "$T/ci2.txt"; rc=$?
same "ci: its job over -> stopped too" 0 "$rc"
same "ci: no runner runs" "" "$(ls "$L")"
same "ci: both written down" 2 "$(wc -l < "$T/ci-state/stopped" | tr -d ' ')"
sleep 60 & other=$!
CR pause --wait 0 --holder $other > /dev/null
CR resume --holder $$ > "$T/ci3.txt"
same "ci: another gate still holds the pause: nothing started" "" "$(ls "$L")"
has "ci: ... and says so" "other holder" "$(cat "$T/ci3.txt")"
kill $other; wait $other 2>/dev/null
upto 5 both_back && ok "ci: the last holder ended without its resume -> its guard starts both, state gone" ||
  bad "ci: guard: running '$(running)', state '$(ls "$T/ci-state" 2>/dev/null | tr '\n' ' ')'"
CR resume > /dev/null; rc=$?
same "ci: resume with nothing paused does nothing" "0" "$rc"
has "ci: status lists the runners" "actions.runner.o-r.mini-1	running	idle" "$(CR status)"
# bootout returns before the service is gone: pause says "no runner runs" only once it is.
FAKE_ASYNC=1 CR pause --wait 0 --holder $$ > "$T/ci5.txt"; rc=$?
same "ci: an asynchronous bootout: pause waits until the runners are gone" "0 none" "$rc $(ls "$L" | grep -c . | sed 's/^0$/none/')"
CR resume --holder $$ > "$T/ci4.txt"; rc=$?
both_back && ok "ci: resume by the last holder starts both, state gone" || bad "ci: resume: '$(running)' rc $rc"
# The gate killed with no cleanup at all (kill -9; an ssh drop that kills its EXIT trap): the guard resumes.
sleep 30 & h=$!
CR pause --wait 0 --holder $h > /dev/null
same "ci: paused for a gate" "" "$(running)"
kill -9 $h; wait $h 2>/dev/null
upto 5 both_back && ok "ci: the gate killed (kill -9) -> its guard starts both, state gone" ||
  bad "ci: after kill -9: running '$(running)', state '$(ls "$T/ci-state" 2>/dev/null | tr '\n' ' ')'"
has "ci: ... and logs it" "ended without a resume" "$(cat "$T/ci-state.log" 2>/dev/null)"
# The holder's pid now belongs to another process (its start time differs): no pause kept for it.
sleep 30 & h=$!
CR pause --wait 0 --holder $h > /dev/null
echo "Thu Jan  1 00:00:00 1970" > "$T/ci-state/holder.$h"
upto 5 both_back && ok "ci: a holder pid used again by another process keeps no pause" || bad "ci: pid reuse: '$(running)'"
kill $h; wait $h 2>/dev/null
# The holder dies while its pause still waits for a job: what the guard started again is not stopped again.
touch "$W/actions-runner-2"
sleep 1 & h=$!
CR pause --wait 30 --holder $h > "$T/ci6.txt" & pz=$!
upto 5 [ ! -e "$L/actions.runner.o-r.mini-1" ] || bad "ci: runner 1 not stopped"
wait $h 2>/dev/null
upto 5 [ -e "$L/actions.runner.o-r.mini-1" ] || bad "ci: the guard did not start runner 1"
rm -f "$W/actions-runner-2"; wait $pz; rc=$?
same "ci: the holder gone during its pause -> exit 4, nothing stopped again, both run" "4 actions.runner.o-r.mini-1 actions.runner.o-r.mini-2" "$rc $(running)"
upto 5 [ ! -e "$T/ci-state" ] || bad "ci: state left after the holder died: $(ls "$T/ci-state" | tr '\n' ' ')"
# ... and a pause that waits only for jobs ends with its holder, not after --wait.
touch "$W/actions-runner-1" "$W/actions-runner-2"
sleep 1 & h=$!
CR pause --wait 30 --holder $h > /dev/null & pz=$!
wait $h 2>/dev/null
gone() { ! kill -0 "$1" 2>/dev/null; }
upto 5 gone $pz && ok "ci: the holder gone -> its pause ends while jobs still run" || { bad "ci: pause still waits for a dead holder"; kill $pz; }
rm -f "$W/actions-runner-1" "$W/actions-runner-2"
upto 5 [ ! -e "$T/ci-state" ] || bad "ci: state left after the holder died: $(ls "$T/ci-state" | tr '\n' ' ')"

# ---- onscreen.sh: waits only between rows, its windows hidden meanwhile; inside a row only a look
sed -n '/^onscreen_ok() {/,/^}/p; /^onscreen_mid() {/,/^}/p; /^hide_ours() {/,/^}/p; /^show_ours() {/,/^}/p' "$E/onscreen.sh" > "$T/os-gate.sh"
printf '#!/bin/bash\necho "$*" >> "%s/tool.log"\n' "$T" > "$T/tool"; chmod +x "$T/tool"
sleep 30 & P1=$!; sleep 30 & P2=$!
os_gate() {   # CALL [SECONDS SOMEONE STAYS]: one call of the gate in a subshell; prints rc, seconds, GONE/MID
  ( TD=$T; T=$TD/tool; S=$TD/os-s.tsv; : > "$S"; GONE=""; MID=""; HIDDEN=""; GATE_LINE=0; PERSON_WAIT=${3:-5}; PERSON_POLL=0.2
    away() { [[ ! -e $F/someone ]]; }; who() { echo "a test"; }; log() { :; }
    launcher_pid() { echo "$P1"; }; qemu_pid() { echo "$P2"; }
    _person_new() { :; }; person_overlap() { :; }
    source "$TD/os-gate.sh"
    t0=$(date +%s); "$1"; rc=$?; echo "$rc $(( $(date +%s) - t0 )) ${GONE:+gone}${MID:+mid:$MID}" )
}
: > "$T/tool.log"; touch "$F/someone"; ( sleep 1; rm -f "$F/someone" ) &
r=$(os_gate onscreen_ok)
same "onscreen: someone between rows -> waits, then on" 0 "${r%% *}"
same "onscreen: ... the app's and the VM's windows hidden while waiting, shown after" "hide $P1|hide $P2|unhide $P1|unhide $P2|" "$(tr '\n' '|' < "$T/tool.log")"
: > "$T/tool.log"; touch "$F/someone"
r=$(os_gate onscreen_ok 5 1)
same "onscreen: someone who stays -> no more rows" "1 gone" "$(echo "$r" | cut -d' ' -f1,3)"
same "onscreen: ... the windows stay hidden (the cleanup quits the app)" "hide $P1|hide $P2|" "$(tr '\n' '|' < "$T/tool.log")"
: > "$T/tool.log"
r=$(os_gate onscreen_mid)
has "onscreen: someone inside a row -> that row stops at once, no wait" "1 0 mid:someone came to the Mac during the row" "$r"
same "onscreen: ... nothing hidden or shown" "" "$(cat "$T/tool.log")"
rm -f "$F/someone"
same "onscreen: nobody inside a row -> on" "0 0 " "$(os_gate onscreen_mid)"
kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null
# Inside a row nothing waits (a wait there kept the row's window, maybe a full-screen VM, up for 30 min).
w=$(awk '/^(row_[a-z_]+|switch_stopped|start_in_window|gpu_lock_switch|switch_applied)\(\) \{/ { f = $1 }
  f && /onscreen_ok/ { print f } /^}/ { f = "" }' "$E/onscreen.sh" | sort -u | tr '\n' ' ')
same "onscreen: no wait inside a row (onscreen_ok only between rows)" "" "$w"
grep -qE 'onscreen_mid \|\| \{ "\$T" full "\$QP" off' "$E/onscreen.sh" && ok "onscreen: the pointer row leaves full screen before it stops for someone" ||
  bad "onscreen: the pointer row may stop in full screen"

# ---- onscreen.sh's exit code: 1 a FAIL, 5 BLOCKED rows (3 was also the code of other ends); CI runners
# still on jobs after the wait: no rows on screen (BLOCKED), the runners back at the end
DOM=org.omacvm.app.test.e2e-person.$$
OSA=$T/os/Test.app; mkdir -p "$OSA/Contents/Resources/scripts" "$T/os/vms/OmacVM M-e2e"
for kv in "CFBundleIdentifier string $DOM" "CFBundleShortVersionString string 9.9.9" "OmacVMCommit string 0000000"; do
  /usr/libexec/PlistBuddy -c "Add :$kv" "$OSA/Contents/Info.plist" >/dev/null
done
printf '#!/bin/bash\necho "ERROR made-up update"; exit 1\n' > "$OSA/Contents/Resources/scripts/update-vm.sh"
echo "NAME='OmacVM M-e2e'" > "$T/os/vms/OmacVM M-e2e/vm.env"
defaults write "$DOM" vmsRoot "$T/os/vms"
# Nothing of the app may open here: a made-up open (and screencapture) that only say they were called.
printf '#!/bin/bash\necho "open $*" >> "%s/os-open.log"; exit 1\n' "$T" > "$B/open"
printf '#!/bin/bash\necho "screencapture $*" >> "%s/os-open.log"; exit 1\n' "$T" > "$B/screencapture"
chmod +x "$B/open" "$B/screencapture"
OS() {   # OUT ARGS...: onscreen.sh with the made-up runners and app (at most 2 min); prints its exit code
  local o=$T/os/$1; shift
  PATH=$B:$PATH CI_AGENTS=$A CI_STATE=$T/ci-state CI_GUARD_TICK=0.2 CI_POLL=0.3 OMACVM_E2E_CI_WAIT=1 PERSON_WAIT=2 PERSON_POLL=0.5 \
    /usr/bin/perl -e 'alarm shift; exec @ARGV' 120 "$E/onscreen.sh" --app "$OSA" --vm "OmacVM M-e2e" --out "$o" "$@" > "$o.txt" 2>&1 < /dev/null
  echo $?
}
same "onscreen exit: BLOCKED rows only -> 5" 5 "$(OS h1 --headless --only window)"
has "onscreen exit: ... the row says why" "window	BLOCKED	not run on screen: --headless" "$(cat "$T/os/h1/summary.tsv")"
same "onscreen exit: a FAIL next to BLOCKED rows -> 1" 1 "$(OS h2 --headless --only window,update-vm)"
has "onscreen exit: ... the FAIL row" "update-vm	FAIL" "$(cat "$T/os/h2/summary.tsv")"
touch "$W/actions-runner-2"   # runner 2 on a job for the whole run
same "onscreen --pause-ci: a runner still on a job after the wait -> 5" 5 "$(OS ci --only window --pause-ci)"
has "onscreen --pause-ci: ... no row on screen, the row says why" "window	BLOCKED	not run on screen: this Mac's CI runners still run jobs" "$(cat "$T/os/ci/summary.tsv")"
same "onscreen --pause-ci: ... nothing of the app opened" "" "$(cat "$T/os-open.log" 2>/dev/null)"
rm -f "$W/actions-runner-2"
upto 5 both_back && ok "onscreen --pause-ci: ... the stopped runner back at the end, state gone" ||
  bad "onscreen --pause-ci: running '$(running)', state '$(ls "$T/ci-state" 2>/dev/null | tr '\n' ' ')'"
undom

# ---- the harnesses ask between rows, not only at their start (3.2.4: two Screen Sharing connects
# inside a run that looked only at its start)
wired() {   # NAME FILE PATTERN...: every pattern in the file
  local n=$1 f=$2 p; shift 2
  for p in "$@"; do grep -qE -- "$p" "$f" || { bad "wiring: $n: no /$p/"; return; }; done
  ok "wiring: $n"
}
wired "cc-switches waits before its first row and before each step" "$E/cc-switches.sh" \
  '^source "\$HERE/person.sh"' '^person_gate start' 'person_watch_start' 'gate "switch-\$n"' '    gate "\$st"' \
  '\{ gate keys; step_keys; \}' '\{ gate window; step_window; \}' '\{ gate unplug; step_unplug; \}' '^  gate update' '^    gate prepare'
wired "cc-switches: a visit's row, the watcher stopped, CI runners back" "$E/cc-switches.sh" \
  'person_overlap "\$ev" end' 'person_watch_stop' 'ci-runners.sh" resume --holder \$\$' 'ci-runners.sh" pause --wait' \
  'alarm shift; exec @ARGV. \$\(\( 300 \+ PERSON_WAIT \)\) "\$HERE/modifier-keys.sh"' 'PERSON_STOP=1; die' 'res aborted "\$\( \(\( \$\{PERSON_STOP:-0\} \)\) && echo BLOCKED'
# No question to the Mac's state left that looks only once (the old start-only checks).
if grep -nE 'HIDIdleTime|screensharingd|JumpConnect' "$E/cc-switches.sh" "$E/onscreen.sh" "$E/modifier-keys.sh" "$E/display-unplug.sh"; then
  bad "wiring: a harness asks HID idle or remote sessions itself (person.sh does)"
else ok "wiring: HID idle and remote sessions only through person.sh"; fi
wired "modifier-keys waits before each case and stamps its own events" "$E/modifier-keys.sh" \
  '^source "\$HERE/person.sh"' 'person_gate "keys-\$name"' 'person_posted 3; "\$KS" --pid "\$PID" \$evs; person_posted' \
  'res delivery BLOCKED'
# Someone who stayed has its own exit code (5); 3 stays "could not run" (no VM, no SSH: maybe a crash).
for f in modifier-keys display-unplug; do
  same "exit code: $f exits 5 only for BLOCKED" "1 1" \
    "$(grep -c 'exit 5' "$E/$f.sh") $(grep -c '^(( n_blocked > 0 )) && exit 5$' "$E/$f.sh")"
done
wired "cc-switches reads the children's exit codes" "$E/cc-switches.sh" \
  'child_end keys modifier-keys.sh "\$rc"' 'child_end unplug display-unplug.sh "\$rc"'
# The EXIT trap that stops the watcher is set before the watcher starts (a run stopped in between left its
# folder and, for cc-switches, ran without its cleanup).
for f in modifier-keys display-unplug cc-switches onscreen; do
  same "watcher: $f sets its EXIT trap first" "trap first" "$(awk '/^ *trap .* EXIT$/ && !t { t = NR }
    /^[^#]*person_watch_start( |;|$)/ && $0 !~ /\(\)/ && !w { w = NR } END { print (t && w && t < w) ? "trap first" : "trap " t ", watcher " w }' "$E/$f.sh")"
done
# The cleanup goes to its end whatever comes (a second Ctrl-C, a hangup, a lost stdout): first thing in it.
for f in cc-switches onscreen; do
  first=$(awk '/^cleanup\(\) \{/ { c = 1; next } c && !/^ *#/ && !/^  local rc=\$\?$/ { print; exit }' "$E/$f.sh")
  same "cleanup: $f ignores signals first" "  trap '' INT TERM HUP PIPE" "$first"
done
wired "cc-switches: the resume's output in the results" "$E/cc-switches.sh" 'resume --holder \$\$ >> "\$OUT/ci-runners.log" 2>&1'
wired "onscreen: the resume's output in the results" "$E/onscreen.sh" 'resume --holder \$\$ >> "\$OUT/ci-runners.log" 2>&1'
wired "display-unplug waits before each case" "$E/display-unplug.sh" \
  '^source "\$HERE/person.sh"' 'gate full && case_run' 'gate fullpanel && case_run' 'gate window && case_run' '&& gate head; then'
wired "onscreen waits instead of stopping at once, stamps its events" "$E/onscreen.sh" \
  '^source "\$E/person.sh"' 'PAUSE on screen' 'RESUME on screen' 'posted\(\) \{ person_posted' 'ci-runners.sh" pause'

exit $fail
