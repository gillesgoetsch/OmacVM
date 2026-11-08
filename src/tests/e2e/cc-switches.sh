#!/bin/bash
# The person's path end to end, before every release (src/release/release.sh
# runs it as a gate; README.md next to this file). On a test Mac, with
# OmacVM.app's test identity ("OmacVM Test", org.omacvm.app.test, its own
# Bridge and Gestures) and a real VM:
#   * the control centre in the VM, driven with real key presses (the real
#     `omacvm` in tmux in the desktop user's session: guest-cc.py);
#   * every switch on and off, the fast network with the VM running and after
#     a restart, Touch ID (the test Bridge's stand-in answers yes or no) with
#     its first request right after a Bridge restart, Graphics, update checks;
#   * the app's window (Accessibility on the launcher's pid: ax.swift): its
#     fast network button, update checks, Update VM;
#   * the update path: the release before (its published zip as the test
#     identity) -> this build through the app's own updater and a local feed
#     signed with a throwaway key, then Update VM, then every switch again.
# Every step checks the control centre's answer, `omacvm vms --json`
# (reachable: true) and the Bridge's log (no refusal, the job ended 0).
#
#   src/tests/e2e/cc-switches.sh --vm NAME [options]
#     --vm NAME          the test VM (in the test app's VMs folder; desktop user logged in by autologin)
#     --clone-from NAME  first make NAME an APFS clone of this stopped test VM (new name and SSH port)
#     --app APP          the build to test, a signed test-identity app: copied over
#                        ~/Applications/"OmacVM Test.app" first (default: the one there)
#     --previous ZIP     the release before (OmacVM-X.Y.Z.zip as published) for the update
#                        path; "latest" downloads releases/latest (gh); default: none (the run
#                        then does not count for the gate)
#     --only LIST        steps (comma list): prepare,baseline,switches,fastnet,touchid,graphics,
#                        updates,keys,window,unplug,update (default: all; update needs --previous)
#     --slow             also the slow switches (thp-kernel, x86-apps: builds in the VM)
#     --features LIST    only these switches (comma list; while working on a fix: never counts for the gate)
#     --out DIR          results (default ~/omacvm-e2e/<time>): summary.tsv, result.json, logs
#     --owner NAME       lock owner name (default cc-e2e)
#     --keep-vm          keep a VM this run cloned (default: deleted at the end)
#     --root DIR         the test app's VMs folder for this run (set back at the end)
#     --hidden           no window on this Mac's screen (a Mac someone works on): VMs without a
#                        window, Update VM through the app's own script, no window steps; never
#                        counts for the gate
#     --pause-ci         this Mac's self-hosted CI runners stopped while the run goes (each once
#                        its job ends; started again at the end: ci-runners.sh), as for a gate
#                        (also OMACVM_E2E_PAUSE_CI=1)
# With --app, the test app that was installed comes back at the end (other
# tests on this Mac use it) unless OMACVM_E2E_KEEP_APP=1.
# Exit 0 only when every step passed (ok or a skip that says why it does not
# apply on this Mac). FAIL = the product is wrong; BLOCKED = this Mac cannot
# run the step (a person must do something once, e.g. install the fast
# network's service): both fail the gate. result.json carries the app's
# commit; release.sh takes it only for the release commit.
# Stop rules: each step has its own time limit; no retries.
# Never on the person's own Mac session in use: refuses with a battery (the
# MacBook) unless OMACVM_E2E_LAPTOP=1. Before the first row and between rows
# (person.sh) it waits while someone is at the Mac: a remote session (Screen
# Sharing, port 5900, Jump Desktop) or input that was not ours in the last 5
# minutes; at most 30 min each time (PERSON_WAIT), then the rest is BLOCKED.
# Rows that ran while someone came and went get a "person" row (person.log has
# the times). Never the person's own app, helpers or VM (fingerprinted before
# and after).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)
source "$HERE/person.sh"

VM=""; CLONE=""; NEWAPP=""; PREV=""; ONLY=""; SLOW=0; OUT=""; OWNER=cc-e2e; KEEP=0; FEATS=""; ROOTARG=""; HIDDEN=0
PAUSE_CI=${OMACVM_E2E_PAUSE_CI:-0}
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --clone-from) CLONE=$2; shift 2 ;;
    --app) NEWAPP=$2; shift 2 ;;
    --previous) PREV=$2; shift 2 ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --slow) SLOW=1; shift ;;
    --features) FEATS=",$2,"; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --owner) OWNER=$2; shift 2 ;;
    --keep-vm) KEEP=1; shift ;;
    --root) ROOTARG=$2; shift 2 ;;
    --hidden) HIDDEN=1; shift ;;
    --pause-ci) PAUSE_CI=1; shift ;;
    *) sed -n '19,47s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $VM ]] || { sed -n '19,47s/^# \{0,1\}//p' "$0" >&2; exit 2; }
ONLY_ARG=${ONLY:-all}
[[ -n $FEATS ]] && ONLY_ARG="$ONLY_ARG features$FEATS"
(( HIDDEN )) && ONLY_ARG="$ONLY_ARG hidden"
# The gate covers the update from the release before too.
[[ -z $PREV ]] && ONLY_ARG="$ONLY_ARG no-update-path"
want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }

APP="$HOME/Applications/OmacVM Test.app"
APPID=org.omacvm.app.test
CLI="$APP/Contents/Resources/omacvm/omacvm"
BRIDGE_APP="$APP/Contents/Helpers/OmacVM Test Bridge.app"
BLOG="$HOME/Library/Logs/omacvm-test-bridge.log"
BDIR="$HOME/Library/Application Support/omacvm-test-bridge"
KEY=$HOME/.ssh/omacvm
OUT=${OUT:-$HOME/omacvm-e2e/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
T0=$(date +%s)
: > "$OUT/summary.tsv"
exec > >(tee -a "$OUT/run.log") 2>&1
export OMACVM_TEST_IDENTITY=1

n_ok=0; n_fail=0; n_blocked=0; n_skip=0
PFX=""   # the pass: "" (this build set up fresh), "update-" (after the update from the release before)
res() {   # STEP ok|FAIL|BLOCKED|skip DETAIL
  printf '%s\t%s\t%s\n' "$PFX$1" "$2" "$3" >> "$OUT/summary.tsv"
  printf '%-34s %-7s %s\n' "$PFX$1" "$2" "$3"
  case $2 in ok) n_ok=$((n_ok + 1)) ;; FAIL) n_fail=$((n_fail + 1)) ;; BLOCKED) n_blocked=$((n_blocked + 1)) ;; *) n_skip=$((n_skip + 1)) ;; esac
  return 0
}
log() { echo "== $(date +%H:%M:%S) $*"; }
CLONES=()   # VMs this run cloned: deleted at the end unless --keep-vm
remove_clones() {   # and the SSH host key each clone was given (use_vm)
  local c
  for c in ${CLONES[@]+"${CLONES[@]}"}; do
    (( KEEP )) || { rm -rf "$c"; (source "$HERE/test-vms.sh" && e2e_pin_drop "$(basename "$c")"); }
  done
  CLONES=()
}
DIED=""; FINISHED=0   # a run that stops before its end is never a gate result
die() { DIED=$*; echo "cc-switches: $*" >&2; exit 3; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# ---- guards: a test Mac nobody uses right now ----
[[ $(uname -m) == arm64 ]] || die "Apple Silicon only"
[[ -e $HOME/.omacvm-user-testing ]] && die "the person is testing (~/.omacvm-user-testing): no VM now"
# No `ioreg | grep -q` under pipefail: its SIGPIPE made a MacBook count as having no battery.
if [[ ${OMACVM_E2E_LAPTOP:-} != 1 && $(ioreg -rc AppleSmartBattery 2>/dev/null) == *'"BatteryInstalled" = Yes'* ]]; then
  die "this Mac has a battery (a MacBook someone may work on): run it on the test Mac, or OMACVM_E2E_LAPTOP=1"
fi
# Nobody at the Mac: no input for 5 min, no remote session (Screen Sharing or Jump Desktop, also one
# left alone: someone may be watching this screen). Else wait for it (person.sh).
person_gate start || die "$PERSON_WHY"
LOCKS=()
lock() {   # DIR: ours, or taken now (same owner counts: the caller may hold it)
  local o; o=$(cat "$1/owner" 2>/dev/null)
  if mkdir "$1" 2>/dev/null || [[ $o == "$OWNER"* ]]; then
    echo "$OWNER $(date '+%F %T') cc-switches e2e, pid $$" > "$1/owner"; LOCKS+=("$1")
  else
    for l in ${LOCKS[@]+"${LOCKS[@]}"}; do rm -rf "$l"; done
    die "$1 is held: $o"
  fi
}
# A colon-separated list (a home folder may have a space in its path: the mini's has).
IFS=: read -ra LOCKLIST <<< "${OMACVM_E2E_LOCKS:-$HOME/.omacvm-mini-vm.lock:$HOME/.omacvm-test-identity.lock}"
for l in "${LOCKLIST[@]}"; do lock "$l"; done

# The person's own helpers, app and VM: the same at the end.
fingerprint() {
  local f
  for f in "$HOME/Applications/OmacVM.app" "/Applications/OmacVM.app" "$HOME/Applications/OmacVMBridge.app" \
           "$HOME/Applications/OmacVMGestures.app" "$HOME/Applications/Omanotch.app"; do
    [[ -e $f ]] && echo "$f $(find "$f" -type f -exec shasum {} + 2>/dev/null | shasum | cut -c1-16)"
  done
  launchctl list 2>/dev/null | awk '$3 ~ /^org\.omacvm\./ && $3 !~ /test/ {print $3}' | sort
  defaults read org.omacvm.app vmsRoot 2>/dev/null
  for f in cli settings.json; do echo "omacvm/$f $(shasum "$HOME/Library/Application Support/omacvm/$f" 2>/dev/null | cut -c1-16)"; done
  for f in token relay-key; do echo "omacvm-bridge/$f $(shasum "$HOME/Library/Application Support/omacvm-bridge/$f" 2>/dev/null | cut -c1-16)"; done
  ls -ld "$HOME/OmacVM/Omarchy" 2>/dev/null | awk '{print $1, $NF}'
}
fingerprint > "$OUT/fp-before.txt"
# The test identity's own state (its CLI, keys, pins, its Bridge's folder): as it was, at the end.
TSTATE=("$HOME/Library/Application Support/omacvm-test" "$HOME/Library/Application Support/omacvm-test-bridge")
mkdir -p "$OUT/state-before"
HELPERS_BEFORE=$(LC_ALL=C pgrep -f "OmacVM Test (Bridge|Gestures).app/Contents/MacOS/" | tr '\n' ' ')
for d in "${TSTATE[@]}"; do [[ -d $d ]] && ditto "$d" "$OUT/state-before/$(basename "$d")"; done

QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
qemu_pid() { LC_ALL=C pgrep -f "$QPAT $VM( |$)" | head -1; }
launcher_pid() { LC_ALL=C pgrep -f "OmacVM Test.app/Contents/MacOS/OmacVM( |$)" | head -1; }
SERVER=""
cleanup() {
  local rc=$?
  # Nothing stops the cleanup half way (a second Ctrl-C, a hangup, a lost stdout after an ssh drop):
  # the CI runners come back at its end.
  trap '' INT TERM HUP PIPE
  log "cleanup"
  local ev; ev=$(_person_new | _person_events); [[ -n $ev ]] && person_overlap "$ev" end
  # Stopped for someone at the Mac: not a product failure (the person row says which row was next).
  (( FINISHED )) || res aborted "$( (( ${PERSON_STOP:-0} )) && echo BLOCKED || echo FAIL)" "the run stopped before its end (exit $rc${DIED:+: $DIED})"
  local p; p=$(qemu_pid)
  if [[ -n $p ]]; then gssh "systemctl poweroff" >/dev/null 2>&1; for _ in $(seq 60); do kill -0 "$p" 2>/dev/null || break; sleep 1; done; kill "$p" 2>/dev/null; fi
  p=$(launcher_pid); [[ -n $p ]] && kill "$p" 2>/dev/null
  [[ -n $SERVER ]] && kill "$SERVER" 2>/dev/null
  rm -f "$BDIR/touchid-test"
  # The update path put the release before (then a relabelled copy) over the test app: this build goes back.
  if [[ -n ${ORIG:-} && -d $ORIG ]]; then rm -rf "$APP"; ditto "$ORIG" "$APP"; fi
  # --app: the test app that was there before.
  if [[ -n ${PRE:-} && -d $PRE && ${OMACVM_E2E_KEEP_APP:-} != 1 ]]; then rm -rf "$APP"; ditto "$PRE" "$APP"; fi
  remove_clones
  # Only a setting this run changed goes back (a run that stopped before that leaves it alone).
  if [[ -n $ROOTARG && ${ROOT_SET:-0} == 1 ]]; then
    if [[ -n $OLDROOT ]]; then defaults write "$APPID" vmsRoot "$OLDROOT"; else defaults delete "$APPID" vmsRoot 2>/dev/null; fi
  fi
  # The test helpers this run started go again (one that ran before keeps running).
  [[ -z $HELPERS_BEFORE ]] && LC_ALL=C pkill -f "OmacVM Test (Bridge|Gestures).app/Contents/MacOS/" 2>/dev/null
  for d in "${TSTATE[@]}"; do
    rm -rf "$d"; [[ -d $OUT/state-before/$(basename "$d") ]] && ditto "$OUT/state-before/$(basename "$d")" "$d"
  done
  fingerprint > "$OUT/fp-after.txt"
  if diff -q "$OUT/fp-before.txt" "$OUT/fp-after.txt" >/dev/null; then res cleanup ok "the person's helpers, app and VM unchanged"
  else res cleanup FAIL "the person's helpers, app or VM changed: diff $OUT/fp-before.txt $OUT/fp-after.txt"; fi
  person_watch_stop
  (( ${CI_PAUSED:-0} )) && "$HERE/ci-runners.sh" resume --holder $$ >> "$OUT/ci-runners.log" 2>&1
  for l in ${LOCKS[@]+"${LOCKS[@]}"}; do rm -rf "$l"; done
  write_result
  echo; echo "$n_ok ok, $n_fail FAIL, $n_blocked BLOCKED, $n_skip skip in $(( ($(date +%s) - T0) / 60 )) min: $OUT/summary.tsv"
}
write_result() {
  # The build these steps ran on (the app here at the end may be the one from before --app).
  /usr/bin/python3 - "$OUT" "${TESTED_COMMIT:-}" "${TESTED_VERSION:-}" \
    "$n_ok" "$n_fail" "$n_blocked" "$n_skip" "$(( $(date +%s) - T0 ))" "$ONLY_ARG" <<'PY'
import json, sys, time
out, commit, version, ok, fail, blocked, skip, secs, only = sys.argv[1:]
rows = [l.rstrip("\n").split("\t", 2) for l in open(out + "/summary.tsv") if l.strip()]
json.dump({"kind": "omacvm-e2e-cc-switches", "commit": commit, "version": version, "only": only,
           "pass": int(fail) == 0 and int(blocked) == 0 and int(ok) > 0 and only == "all",
           "counts": {"ok": int(ok), "FAIL": int(fail), "BLOCKED": int(blocked), "skip": int(skip)},
           "not_ok": [r for r in rows if len(r) == 3 and r[1] in ("FAIL", "BLOCKED")],
           "seconds": int(secs), "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z")},
          open(out + "/result.json", "w"), indent=1)
PY
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Someone coming to the Mac between two checks: the watcher writes it down with the time (started
# after the trap, which stops it).
PERSON_KEEP_LOG=$OUT/person.log; person_watch_start

# Between two rows: someone at the Mac -> wait (person.sh); rows that ran while someone came and
# went get their own row. GATE_LINE: summary.tsv's length at the last check.
GATE_LINE=0
person_overlap() {   # EVENTS NEXT
  local span r
  span=$(person_span "$OUT/summary.tsv" "${GATE_LINE:-0}" 1 2)
  r=$(person_overlap_row "$1" "${span%%$'\t'*}" "${span#*$'\t'}")
  res person "${r%%$'\t'*}" "${r#*$'\t'}"
}
gate() {   # ROW: the row about to run
  person_gate "$PFX$1" || { res person BLOCKED "$PERSON_WHY: $PFX$1 and the rows after it not run"; PERSON_STOP=1; die "$PERSON_WHY"; }
  GATE_LINE=$(wc -l < "$OUT/summary.tsv" | tr -d ' ')
}
# This Mac's CI runners stopped for the run (their jobs start VMs and load the Mac).
CI_PAUSED=0
if (( PAUSE_CI )); then
  CI_PAUSED=1
  log "CI runners: each stopped once its job ends (<= 50 min)"
  "$HERE/ci-runners.sh" pause --wait 3000 --holder $$ || die "this Mac's CI runners still run jobs after 50 min"
fi

tmo() {   # SECONDS CMD...: macOS has no timeout(1)
  local secs=$1; shift
  "$@" & local p=$! w
  ( sleep "$secs"; kill "$p" 2>/dev/null ) & w=$!
  wait "$p"; local r=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $r
}

# ---- the app ----
if [[ -n $NEWAPP ]]; then
  [[ $(plist "$NEWAPP" CFBundleIdentifier) == "$APPID" ]] || die "$NEWAPP is not the test identity ($APPID)"
  codesign --verify --deep --strict "$NEWAPP" || die "$NEWAPP does not verify"
  [[ -n $(launcher_pid) || -n $(LC_ALL=C pgrep -f "OmacVM Test.app/Contents/" | head -1) ]] && die "the test app runs: quit it first"
  # The test app other tests on this Mac use comes back at the end.
  PRE=$OUT/app-before/OmacVM\ Test.app
  [[ -d $APP ]] && { mkdir -p "$OUT/app-before"; ditto "$APP" "$PRE"; }
  rm -rf "$APP" && ditto "$NEWAPP" "$APP"
fi
[[ -x $CLI ]] || die "$CLI missing"
codesign --verify --deep --strict "$APP" 2>/dev/null && res app ok "$(plist "$APP" CFBundleShortVersionString) $(plist "$APP" OmacVMCommit | cut -c1-12) team $(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" \
  || res app FAIL "$APP does not verify"
TESTED_COMMIT=$(plist "$APP" OmacVMCommit); TESTED_VERSION=$(plist "$APP" CFBundleShortVersionString)
OLDROOT=$(defaults read "$APPID" vmsRoot 2>/dev/null)
if [[ -n $ROOTARG ]]; then mkdir -p "$ROOTARG"; ROOTARG=$(cd "$ROOTARG" && pwd); defaults write "$APPID" vmsRoot "$ROOTARG"; ROOT_SET=1; fi
# The test app's own VMs folder, never the installed app's (test-vms.sh; the
# test app does not use ~/OmacVM either: TestVMs in VMPick.swift).
ROOT=$(source "$HERE/test-vms.sh" && e2e_vms_root "$APPID") || die "no test VMs folder: pass --root DIR or set $APPID vmsRoot"
VMD=$ROOT/$VM

# ---- tools ----
swiftc -O -o "$OUT/ax" "$HERE/ax.swift" 2> "$OUT/ax-build.log" || res tools FAIL "ax.swift does not build: $OUT/ax-build.log"
vminfo() {   # one VM of `omacvm vms --json`, as "state reachable ip omacvm"
  "$CLI" vms --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
for v in json.load(sys.stdin).get("vms", []):
    if v.get("name") == sys.argv[1] and v.get("type") == "app":
        print(v.get("state"), str(v.get("reachable")).lower(), v.get("ip") or "-", v.get("omacvm") or "-"); break
else:
    print("missing false - -")' "$VM"
}
IP=""
vssh() {   # ssh to $IP (127.0.0.1:PORT, or the fast network's address); the VM's own key first, as onscreen.sh does
  local h=${IP%:*} p=22
  [[ $IP == *:* ]] && p=${IP##*:}
  ssh -i "$VMD/ssh-key" -i "$KEY" -p "$p" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "root@$h" "$@"
}
gssh() {   # the VM as root; the address again from `omacvm vms` when it moved (the fast network)
  local rc=255 i
  [[ -n $IP ]] && { vssh "$@" < /dev/null; rc=$?; }
  (( rc == 255 )) || return $rc
  i=$(vminfo | awk '{print $3}'); [[ $i != - && -n $i ]] || return 255
  IP=$i; vssh "$@" < /dev/null
}
gpush() { gssh true >/dev/null 2>&1; vssh "install -D -m 755 /dev/stdin $1"; }
reachable() {   # SECONDS: `omacvm vms --json` says running + reachable within SECONDS
  local i
  for ((i = 0; i < $1; i += 3)); do [[ $(vminfo | awk '{print $1, $2}') == "running true" ]] && return 0; sleep 3; done
  return 1
}
cc() {   # ARGS...: guest-cc.py in the VM. Sets CCJ (its JSON, kept as $OUT/cc-<n>-<what>.json) and CCS
  # (a short line); call it directly, never in $(...): the two would be lost with the subshell.
  CCN=$(( ${CCN:-0} + 1 ))
  CCJ=$OUT/${PFX}cc-$CCN-$1.json
  local q="" a rc r="'\\''"
  # Each argument in single quotes, its bytes as they are: bash 3.2's printf %q
  # writes a byte of some characters on its own (… = E2 '\200' A6), and that
  # line in ssh's arguments here is not UTF-8 (#545).
  for a in "$@"; do a=${a//\'/$r}; q+=" '$a'"; done
  gssh "python3 /var/lib/omacvm-e2e/guest-cc.py$q" > "$CCJ" 2> "$CCJ.err"
  rc=$?
  CCS=$(/usr/bin/python3 - "$CCJ" <<'PY'
import json, sys
try:
    o = json.load(open(sys.argv[1]))
except Exception:
    print("no answer from the VM"); sys.exit(0)
bits = []
for k in ("error", "already", "seconds", "asked", "answer", "question"):
    if o.get(k): bits.append(f"{k}: {str(o[k])[:160]}")
for k in ("before", "after"):
    v = o.get(k)
    if isinstance(v, dict): bits.append(f"{k}: {v.get('on')}, {v.get('status')} ({v.get('note', '')[:70]})")
if o.get("status"):   # `row`: the row itself
    bits.append(f"row: {o.get('on')}, {o['status']} ({str(o.get('note', ''))[:70]})")
if o.get("trouble"): bits.append("trouble: " + " | ".join(o["trouble"])[:300])
for k in ("got_in", "password_prompt", "linked"):
    if k in o: bits.append(f"{k}: {str(o[k])[:200]}")
print("; ".join(bits))
PY
)
  [[ -s $CCJ.err ]] && CCS+=" (stderr: $(tail -2 "$CCJ.err" | tr '\n' ' ' | cut -c1-200))"
  return $rc
}
ccok() { /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$CCJ" 2>/dev/null; }
# The Bridge's log: what came since a mark (the file may be new after a restart).
bmark() { BMARK=$(stat -f %z "$BLOG" 2>/dev/null || echo 0); }
bsince() { local s; s=$(stat -f %z "$BLOG" 2>/dev/null || echo 0); if (( s < ${BMARK:-0} )); then cat "$BLOG"; else tail -c +$(( ${BMARK:-0} + 1 )) "$BLOG"; fi 2>/dev/null; }
bproblems() {   # refusals and failed jobs since the mark, one line
  bsince | grep -E ': (4[0-9][0-9]|50[0-9])( |$)|unknown-vm|cannot reach|ended [1-9]' | tail -5 | sed 's/^.*omacvm-bridge: //' | tr '\n' '|'
}
guest_feature() { gssh "sed -n 's/^OMACVM_FEATURE_${1//-/_}=//p' /etc/omacvm/env | tail -1"; }
mac_feature() { tr ' ' '\n' < "$VMD/features" 2>/dev/null | sed -n "s/^$1=//p" | tail -1; }
bridge_start() {   # the test Bridge with its log here (as src/mac/install.sh starts it for the test identity)
  LC_ALL=C pkill -f "OmacVM Test Bridge.app/Contents/MacOS/" 2>/dev/null; sleep 1
  open -g -n --stdout "$BLOG" --stderr "$BLOG" "$BRIDGE_APP"
  local i; for ((i = 0; i < 20; i++)); do lsof -nP -iTCP:47931 -sTCP:LISTEN >/dev/null 2>&1 && { BSTART=$(stat -f %z "$BLOG" 2>/dev/null || echo 0); return 0; }; sleep 0.5; done
  return 1
}
gestures_start() {   # the test Gestures again (as src/mac/install.sh starts it for the test identity)
  open -g -n --stdout "$HOME/Library/Logs/omacvm-test-gestures.log" --stderr "$HOME/Library/Logs/omacvm-test-gestures.log" \
    "$APP/Contents/Helpers/OmacVM Test Gestures.app"
  local i; for ((i = 0; i < 20; i++)); do lsof -nP -iTCP:47930 -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}
# The Bridge takes at most 20 jobs an hour per VM (jobsPerHour, src/bridge/mac/control_policy.swift;
# it says "20 jobs in the last hour: try later"). One pass sends about 50. The count lives in the
# Bridge's memory: before a step would go over it, the test Bridge starts again (from 0).
jobs_sent() {   # jobs this Bridge took (202) since it started
  local s; s=$(stat -f %z "$BLOG" 2>/dev/null || echo 0)
  { if (( s < ${BSTART:-0} )); then cat "$BLOG"; else tail -c +$(( ${BSTART:-0} + 1 )) "$BLOG"; fi; } 2>/dev/null | grep -c 'POST /omacvm/jobs from relay.*: 202'
}
job_room() {   # [N]: room for N more jobs (default 3); else the test Bridge again, and the control centre on it
  local n=${1:-3} m i
  (( $(jobs_sent) + n <= 18 )) && return 0
  log "the Bridge's job limit (20 an hour per VM) is near: the test Bridge starts again"
  m=$(stat -f %z "$BLOG" 2>/dev/null || echo 0)
  bridge_start || { res bridge-again FAIL "the test Bridge does not listen on 47931 again ($BLOG)"; return 1; }
  # The control centre asks the Mac every 5 s: linked again once the new Bridge answered its status.
  for ((i = 0; i < 30; i++)); do
    tail -c +$(( m + 1 )) "$BLOG" 2>/dev/null | grep -qF "GET /omacvm/status from relay ($VM): 200" && { sleep 1; return 0; }
    sleep 2
  done
  res bridge-again FAIL "the control centre did not ask the new test Bridge in 60 s"
  return 1
}
start_vm() {
  local i
  for ((i = 0; i < 60; i++)); do [[ -z $(qemu_pid) ]] && break; sleep 1; done
  # Before every start: VM is a test VM in the test app's own VMs folder (test-vms.sh).
  (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") >/dev/null || return 1
  # The VM's clipboard on a pasteboard of its own, never the Mac's (STANDARDS 25).
  local hide=()
  (( HIDDEN )) && hide=(--env OMACVM_COCOA_HIDDEN=1 --env OMACVM_BACKGROUND=1)
  # A build that asks before a start (the fast network's service not ready, #215) takes its answer from a test hook.
  [[ -n ${OMACVM_E2E_FASTNET_ANSWER:-} ]] && hide+=(--env "OMACVM_TEST_FAST_NETWORK_ANSWER=$OMACVM_E2E_FASTNET_ANSWER")
  open -n -g --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e --env OMACVM_TEST_HELPERS_ANSWER=later ${hide[@]+"${hide[@]}"} "$APP" --args --start --vm "$VM"
  for ((i = 0; i < 40; i++)); do [[ -n $(qemu_pid) ]] && break; sleep 1; done
  [[ -n $(qemu_pid) ]] || return 1
  for ((i = 0; i < 90; i++)); do gssh "test -d /run/user/\$(id -u \$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env))/hypr" 2>/dev/null && { sleep 5; return 0; }; sleep 2; done
  return 1
}
stop_vm() {   # as the person: shut down in Omarchy; QEMU and the launcher go
  local p i; p=$(qemu_pid); [[ -n $p ]] || return 0
  gssh "systemctl poweroff" >/dev/null 2>&1
  for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && return 1
  for ((i = 0; i < 15; i++)); do [[ -z $(launcher_pid) ]] && break; sleep 1; done
  return 0
}
restart_vm() { stop_vm && start_vm && reachable 60 && cc start 120 && ccok; }
window() {   # the launcher's window on this VM (the VM must be stopped): its pid, or nothing
  local i p
  close_window   # a launcher from before keeps the VM it shows
  open -n -g --env OMACVM_TEST_HELPERS_ANSWER=later "$APP" --args --vm "$VM"
  for ((i = 0; i < 20; i++)); do
    p=$(launcher_pid)
    if [[ -n $p && $("$OUT/ax" "$p" dump 2>/dev/null | head -1) == "windows: "[1-9]* ]]; then
      # Never press anything in a window that shows another VM (a kept one of another test). The window
      # may still be filling in: up to 10 s for the VM's name.
      local k
      for ((k = 0; k < 10; k++)); do
        sleep 1
        "$OUT/ax" "$p" text 2>/dev/null | grep -qF "$VM" && { echo "$p"; return 0; }
      done
      "$OUT/ax" "$p" text > "$OUT/${PFX}window-other.txt" 2>&1
      echo "the window shows another VM ($OUT/${PFX}window-other.txt)" >&2; return 1
    fi
    sleep 1
  done
  return 1
}
close_window() { local p; p=$(launcher_pid); [[ -n $p ]] && kill "$p" 2>/dev/null; sleep 2; }
inside_app() {   # the pids whose executable is inside the test app (what its updater waits for)
  ps -axo pid=,comm= | awk -v a="$APP/" 'index(substr($0, index($0, $2)), a) == 1 {print $1}'
}
stop_inside_app() {   # the VM shut down first; then its helpers (they run from inside a test app)
  local i p
  [[ -n $(qemu_pid) ]] && { stop_vm || kill "$(qemu_pid)" 2>/dev/null; }
  for p in $(inside_app); do kill "$p" 2>/dev/null; done
  for ((i = 0; i < 15; i++)); do [[ -z $(inside_app) ]] && return 0; sleep 1; done
  echo "still inside the app: $(for p in $(inside_app); do ps -o comm= -p "$p"; done | tr '\n' ' ')" >&2
  return 1
}


# ---- the VM ----
appver() { cat "$APP/Contents/Resources/omacvm/src/VERSION" 2>/dev/null || cat "$APP/Contents/Resources/omacvm/VERSION" 2>/dev/null; }
# The fast network's service for this app: ok | old | down | missing | stopped (src/net/mac/install.sh).
netd() { "$APP/Contents/Resources/omacvm/src/net/mac/install.sh" --status --app "$APP" 2>/dev/null | head -1; }
# Switching it needs root only when the service is not there for this app; nobody types a password here.
netd_blocked() {
  local s f r
  # The person's own VMs on this Mac use the fast network: its service is theirs; the test leaves it alone.
  r=$(defaults read org.omacvm.app vmsRoot 2>/dev/null || echo "$HOME/OmacVM")
  for f in "$r"/*/fast-network "$HOME"/OmacVM/*/fast-network; do
    [[ -s $f ]] && { echo "the person's own VM ($(basename "$(dirname "$f")")) uses the fast network on this Mac: its service is not the test's to switch (run on a test Mac)"; return; }
  done
  s=$(netd)
  [[ $s == missing || $s == down ]] && ! sudo -n true 2>/dev/null && echo "omacvm-netd is $s for this app and nobody can type the administrator's password here: install it once (README)"
}
use_vm() {   # NAME [CLONE_FROM]: the VM of this pass (an APFS clone of a kept one, new name and SSH port)
  VM=$1; VMD=$ROOT/$VM; IP=""
  if [[ -n ${2:-} ]]; then
    local src=$2
    [[ $src == */* ]] || src=$ROOT/$src   # a name in the VMs folder, or a VM folder's path
    log "clone $src -> $VM"
    [[ -e $VMD ]] && die "$VMD exists"
    [[ -f $src/vm.env && -e $src/ready ]] || die "no finished VM at $src"
    LC_ALL=C pgrep -f "$(basename "$src")" | while read -r p; do ps -o args= -p "$p"; done | grep -qE "$QPAT" && die "$src runs: stop it first"
    cp -cR "$src" "$VMD" || die "clone failed"
    CLONES+=("$VMD")
    rm -f "$VMD/fast-network" "$VMD"/logs/*.pid
    local port=$(( 52500 + RANDOM % 400 ))
    # A test VM's size (STANDARDS: at most 8 GB / 6 CPUs), whatever the kept one had.
    sed -i '' "s/^NAME=.*/NAME='$VM'/; s/^SSH_PORT=.*/SSH_PORT=$port/; s/^CPUS=.*/CPUS=${OMACVM_E2E_CPUS:-6}/; s/^MEM_MB=.*/MEM_MB=${OMACVM_E2E_MEM_MB:-8192}/" "$VMD/vm.env"
    # The clone is the VM it was cloned from under a new name: set up from this Mac as that one was
    # (its remembered SSH host key). Without it, a pass with no Update VM (the update pass: a base the
    # release before made) has a VM that OmacVM never set up, and the Bridge refuses its control centre.
    local from pin
    from=$(sed -n "s/^NAME=//p" "$src/vm.env" | head -1); from=${from#\'}; from=${from%\'}
    if (source "$HERE/test-vms.sh" && e2e_clone_pin "$from" "$VM"); then
      [[ -s $(source "$HERE/test-vms.sh" && _e2e_pin "$VM") ]] && pin="host key of $from kept" || pin="$from has no host key here: not set up from this Mac"
    else pin="host key not copied"; fi
    res clone ok "$(basename "$src") -> $VM (APFS clone, SSH port $port, ${OMACVM_E2E_CPUS:-6} CPUs, ${OMACVM_E2E_MEM_MB:-8192} MB; $pin)"
  fi
  [[ -f $VMD/vm.env && -e $VMD/ready ]] || die "no finished VM $VM in $ROOT"
  [[ -n $(qemu_pid) ]] && die "$VM runs already: shut it down first"
  # One VM from the test app at a time (its launcher is one per Mac); other tests' QEMUs may run.
  LC_ALL=C pgrep -f "OmacVM Test.app/Contents/[A-Za-z/]*$QPAT" >/dev/null && die "another VM of the test app runs (one launcher per Mac)"
  return 0
}

update_vm_window() {   # Update VM in the app's window (VM stopped): 0 when the VM has this app's OmacVM
  local p t0 i v want rc
  want=$(appver); t0=$(date +%s)
  rm -f "$VMD/logs/update.log" "$VMD/update.log"
  if (( HIDDEN )); then   # the script the button runs, without the window
    mkdir -p "$VMD/logs"
    OMACVM_PROGRESS=1 tmo 1500 /bin/bash "$APP/Contents/Resources/scripts/update-vm.sh" "$VMD" > "$VMD/logs/update.log" 2>&1
    v=$(cat "$VMD/omacvm-version" 2>/dev/null)
    echo "update-vm.sh (hidden run, no window): $(tail -1 "$VMD/logs/update.log" | cut -c1-100); omacvm-version $v; $(( $(date +%s) - t0 )) s"
    [[ $v == "$want" ]]; return
  fi
  p=$(window) || { echo "no window on $VM"; return 1; }
  "$OUT/ax" "$p" press "Update VM" > "$OUT/ax-update-vm.txt" 2>&1; rc=$?
  # -25204 (cannot complete): the app's main thread was busy when the press came, e.g. right after
  # the app updated itself. The press may have gone through: Update VM writes its log at once.
  if (( rc )) && grep -q 'press failed: -25204' "$OUT/ax-update-vm.txt"; then
    for ((i = 0; i < 60; i += 2)); do [[ -s $VMD/logs/update.log || -s $VMD/update.log ]] && { rc=0; echo " (update.log written: the press went through)" >> "$OUT/ax-update-vm.txt"; break; }; sleep 2; done
  fi
  if (( rc )); then
    close_window
    v=$(cat "$VMD/omacvm-version" 2>/dev/null)
    if [[ -n $v && $(printf '%s\n%s\n' "$v" "$want" | sort -V | tail -1) == "$v" ]]; then
      echo "no Update VM button: the VM has $v already (this app: $want)"; return 0
    fi
    echo "no Update VM button ($(cat "$OUT/ax-update-vm.txt")); the VM has ${v:-nothing}, the app $want"; return 1
  fi
  for ((i = 0; i < 1500; i += 5)); do
    # 3.0.3 and older write update.log into the VM folder itself.
    { grep -q "^UPDATED " "$VMD/logs/update.log" 2>/dev/null || grep -q "^UPDATED " "$VMD/update.log" 2>/dev/null; } && [[ -z $(qemu_pid) ]] && break
    sleep 5
  done
  close_window
  v=$(cat "$VMD/omacvm-version" 2>/dev/null)
  echo "Update VM: $(tail -1 "$VMD/logs/update.log" 2>/dev/null || tail -1 "$VMD/update.log" 2>/dev/null | cut -c1-100); omacvm-version $v; $(( $(date +%s) - t0 )) s"
  [[ $v == "$want" ]]
}

feat() {   # FIELD NAME, from this pass's `omacvm features --json`
  /usr/bin/python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["features"]:
    if f["name"] == sys.argv[3]: print(str(f[sys.argv[2]]).lower() if isinstance(f[sys.argv[2]], bool) else f[sys.argv[2]])' "$OUT/${PFX}features.json" "$1" "$2"
}
read_features() {
  "$CLI" features --vm "$VM" --json > "$OUT/${PFX}features.json" 2> "$OUT/${PFX}features.err"
  names=$(/usr/bin/python3 -c 'import json,sys; print(" ".join(f["name"] for f in json.load(open(sys.argv[1]))["features"]))' "$OUT/${PFX}features.json" 2>/dev/null)
  [[ -n $names ]] || res features FAIL "omacvm features --json gave nothing: $(tail -2 "$OUT/${PFX}features.err")"
}
# Omanotch: the test identity's VMs reach only a test Omanotch on 47911 (never the person's).
test_omanotch() { lsof -nP -iTCP:47911 -sTCP:LISTEN >/dev/null 2>&1; }
# The VM's package list matches the mirrors: each package list (sync database) the VM has is
# the one its first mirror serves now. pkg-add never syncs, so a package the mirror has a newer
# version of is a 404. One package's file is not enough: in 3.2.3's gate jq's was still there,
# Mesa's build tools were not (src/tests/e2e-mirrors.sh). Prints why when it is not current.
mirrors_current() {
  gssh 'd=$(pacman-conf DBPath 2>/dev/null); d=${d:-/var/lib/pacman/}; d=${d%/}/sync; n=0; t=$(mktemp) || exit 1
    for db in "$d"/*.db; do
      [ -f "$db" ] || continue
      r=$(basename "$db" .db); s=$(pacman-conf -r "$r" Server 2>/dev/null | head -1)
      if [ -z "$s" ] || ! curl -fsL --max-time 60 -o "$t" "$s/$r.db"; then
        echo "$r: no answer from its mirror ${s:-(none)}"; rm -f "$t"; exit 1
      fi
      cmp -s "$t" "$db" || { echo "$r: the mirror has a newer list ($s)"; rm -f "$t"; exit 1; }
      n=$((n + 1))
    done
    rm -f "$t"; [ "$n" -gt 0 ] || { echo "no package lists in $d"; exit 1; }' 2>&1
}
prepare_system() {   # a kept VM older than the mirrors: OmacVM cannot install its packages (pkg-add refuses a partial update)
  local why
  why=$(mirrors_current) && return 0
  log "the VM's packages are older than the mirrors ($(tail -1 <<<"$why" | cut -c1-120)): omarchy update -y, then omacvm apply (limit 45 min)"
  local t0 rc
  t0=$(date +%s)
  # As the desktop user, as the control centre's "o" runs it; sudo without a password only meanwhile
  # (verifypw=any: its sudo -v too, as src/vm/omarchy-install.sh does). omarchy-update -y still asks
  # about orphaned packages (gum confirm, Omarchy 4.0.3): the default (no) after 5 s.
  gssh 'U=$(sed -n "s/^OMACVM_USER=//p" /etc/omacvm/env); printf "Defaults:%s verifypw=any\n%s ALL=(ALL) NOPASSWD: ALL\n" "$U" "$U" > /etc/sudoers.d/99-omacvm-e2e; chmod 440 /etc/sudoers.d/99-omacvm-e2e
    runuser -u "$U" -- env HOME="/home/$U" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" GUM_CONFIRM_TIMEOUT=5s bash -c "source /usr/share/omarchy/default/bash/env-bootstrap; omarchy-update -y" > /var/tmp/omacvm-e2e-update.log 2>&1 < /dev/null
    rc=$?; rm -f /etc/sudoers.d/99-omacvm-e2e; tail -3 /var/tmp/omacvm-e2e-update.log; exit $rc' > "$OUT/${PFX}omarchy-update.txt" 2>&1
  rc=$?
  if (( rc == 0 )) && tmo 1800 "$CLI" apply --vm "$VM" --yes > "$OUT/${PFX}apply.log" 2>&1; then
    # Textual comes with the control centre: a kept VM may have it off until features_as_new.
    SYSUPD="omarchy update -y + omacvm apply in $(( $(date +%s) - t0 )) s (a kept VM older than the mirrors)"
  else
    res system-update FAIL "omarchy update exit $rc; omacvm apply: $(tail -1 "$OUT/${PFX}apply.log" 2>/dev/null | cut -c1-120) ($OUT/${PFX}omarchy-update.txt, ${PFX}apply.log)"
  fi
}
system_update_done() {   # after features_as_new: the control centre's Textual is there now
  [[ -n ${SYSUPD:-} ]] || return 0
  # OmacVM's own Textual (src/control/vendor), as check.sh checks it.
  if tx=$(gssh "python3 -I /usr/local/share/omacvm/control/omacvm_cc/vendor.py --check" 2>&1); then res system-update ok "$SYSUPD; Textual there"
  else res system-update FAIL "$SYSUPD, but no Textual with the control centre on: $(tail -1 <<<"$tx" | cut -c1-120)"; fi
  SYSUPD=""
}
features_as_new() {   # what a new VM has on that this one has off (a clone of a kept VM): on, as a person would
  local need
  need=$(/usr/bin/python3 -c '
import json, sys
print(" ".join(f["name"] for f in json.load(open(sys.argv[1]))["features"]
               if str(f.get("default")).lower() in ("true", "on") and f.get("available") and not f.get("on")))' "$OUT/${PFX}features.json")
  if ! test_omanotch; then
    need=$(tr ' ' '\n' <<<"$need" | grep -vx omanotch | tr '\n' ' ')
    if [[ $(feat on omanotch) == true ]]; then
      tmo 600 "$CLI" disable omanotch --vm "$VM" --yes > "$OUT/${PFX}omanotch-off.log" 2>&1
      res omanotch skip "no test Omanotch on 47911 on this Mac (the person's is never used): Omanotch off for this VM"
    fi
  fi
  need=${need% }
  [[ -n $need ]] || return 0
  log "omacvm enable $need (limit 30 min)"
  # One feature name per word.
  # shellcheck disable=SC2086
  if tmo 1800 "$CLI" enable $need --vm "$VM" --yes > "$OUT/${PFX}enable.log" 2>&1; then res features-as-new ok "turned on as a new VM has them: $need"
  else res features-as-new FAIL "omacvm enable $need: $(tail -2 "$OUT/${PFX}enable.log" | tr '\n' ' ')"; fi
  read_features
}
start_pass() {   # start the VM, the control centre's driver into it, the features
  log "start $VM"
  if start_vm && reachable 90; then res start ok "running, reachable: $(vminfo)"
  else res start FAIL "the VM did not come up: $(vminfo)"; return 1; fi
  gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py" || res tools FAIL "could not copy guest-cc.py into the VM"
  read_features
  if want prepare; then
    local before; before=$(cat "$VMD/features" 2>/dev/null)
    prepare_system
    features_as_new
    system_update_done
    # What changed while it ran reaches the Mac from the next start (OmacVM.app's links): start it again.
    if [[ $(cat "$VMD/features" 2>/dev/null) != "$before" ]] || [[ -s $OUT/${PFX}omarchy-update.txt ]]; then
      log "start again (the switches set up while it ran apply from a start)"
      if stop_vm && start_vm && reachable 90; then res restart ok "$(vminfo)"
      else res restart FAIL "the VM did not come back: $(vminfo)"; return 1; fi
      gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py"
    fi
  fi
  BASE=$(cat "$VMD/features" 2>/dev/null)
}

baseline() {   # TAG: the control centre comes up linked; no row fails; the Mac reaches the VM
  local s bad env
  CC_UP=0
  cc start 120; s=$CCS
  if ccok; then
    CC_UP=1
    bad=$(/usr/bin/python3 -c '
import json, re, sys
o = json.load(open(sys.argv[1]))
if "\uf00c" not in o["screen"] and "\uf10c" not in o["screen"]:
    print("no status marks on the screen (ASCII?): failing rows cannot be read"); sys.exit(0)
bad = [l.strip(" \u2502")[:90] for l in o["screen"].splitlines() if re.search("\uf00d|\uf071", l)]
# Not the product: macOS short of memory (other work on this test Mac) is said on Graphics memory.
env = [b for b in bad if "Graphics memory" in b and "short of memory" in b]
print(" | ".join(b for b in bad if b not in env)[:600])
print(" ".join(env)[:200])' "$CCJ")
    env=$(sed -n 2p <<<"$bad"); bad=$(sed -n 1p <<<"$bad")
    [[ -z $bad ]] && res "baseline-$1" ok "$s${env:+; this Mac (not the product): $env}" || res "baseline-$1" FAIL "rows failing or needing a person: $bad"
  else
    res "baseline-$1" FAIL "$s"
  fi
  reachable 30 && res "reachable-$1" ok "$(vminfo)" || res "reachable-$1" FAIL "$(vminfo)"
}

switch_one() {   # NAME on|off: one press in the control centre, and every check
  local n=$1 to=$2 title s t0 b g m job why=""
  title=$(feat title "$n")
  job_room
  bmark; t0=$(date +%s)
  cc toggle "$title" "$to" 900; s=$CCS
  b=$(bproblems); g=$(guest_feature "$n"); m=$(mac_feature "$n")
  job=$(bsince | grep -E "job [^ ]+ \((enable|disable) [^)]*\b$n\b" | tail -1 | sed 's/^.*control: //')
  reachable 60 || why+="not reachable: $(vminfo); "
  [[ -n $b ]] && why+="Bridge: $b; "
  [[ $g == "$to" ]] || why+="the VM's /etc/omacvm/env says ${g:-nothing}; "
  [[ $m == "$to" ]] || why+="the VM folder's features says ${m:-nothing}; "
  [[ $s == *already* || $job == *"ended 0"* ]] || why+="no job ended 0 in the Bridge's log (${job:-none}); "
  # A Mac with a notch but no test Omanotch on 47911 (the person's own is never used): the switch
  # works, and the row rightly says notchcast has nothing to connect to.
  if ! ccok; then
    if [[ -z $why && $n == omanotch && $to == on && $s == *"notchcast is not connected"* ]] && ! test_omanotch; then
      res "switch-$n-$to" skip "switched (job ended 0), the row says failing: no test Omanotch on 47911 on this Mac (the person's is never used)"
      return 0
    fi
    why="cc: $s; $why"
  fi
  if [[ -z $why ]]; then res "switch-$n-$to" ok "$(( $(date +%s) - t0 )) s; $job"
  else res "switch-$n-$to" FAIL "$why(screen: $CCJ)"; fi
}

restore_base() {   # what a switch changed through its dependencies, back as before (through the cc too)
  local w n v now
  for w in $BASE; do
    n=${w%%=*}; v=${w#*=}
    case $n in fast-network|touch-id|thp-kernel|x86-apps|control-centre) continue ;; esac
    now=$(mac_feature "$n")
    [[ -n $now && $now != "$v" && $(feat available "$n") == true ]] && switch_one "$n" "$v"
  done
  return 0
}

step_switches() {
  log "switches (limit 90 min)"
  local n title s on other g rc
  for n in $names; do
    [[ -z $FEATS || $FEATS == *",$n,"* ]] || continue
    case $n in
      fast-network|touch-id|control-centre) continue ;;   # their own steps
      thp-kernel|x86-apps) (( SLOW )) || { res "switch-$n" skip "slow (a build in the VM): --slow"; continue; } ;;
    esac
    if [[ $(feat available "$n") != true ]]; then
      # Not for this Mac or VM: the row says so and Space changes nothing.
      title=$(feat title "$n")
      cc row "$title"; s=$CCS
      # The last job's toast can cover the row's line below the table for a few seconds: once more.
      [[ $s == *"row: "* ]] || { sleep 5; cc row "$title"; s=$CCS; }
      [[ $s == *"row: off, unavailable"* || $s == *"row: off, off"* || $s == *"no row"* ]] \
        && res "switch-$n" skip "not on this Mac ($(feat reason "$n")); ${s:0:120}" \
        || res "switch-$n" FAIL "unavailable here ($(feat reason "$n")) but the row says: $s"
      continue
    fi
    gate "switch-$n"
    on=$(mac_feature "$n"); [[ -n $on ]] || on=$(feat on "$n" | sed 's/true/on/; s/false/off/')
    other=$([[ $on == on ]] && echo off || echo on)
    switch_one "$n" "$other"
    switch_one "$n" "$on"
    restore_base
  done
  [[ -z $FEATS || $FEATS == *",control-centre,"* ]] || return 0
  # The control centre itself: off closes it (asked first); the Mac brings it back.
  job_room
  bmark
  cc toggle "OmacVM control centre" off 600; s=$CCS
  g=$(guest_feature control-centre)
  if [[ $g == off ]] && ! gssh "test -x /usr/local/bin/omacvm"; then res switch-control-centre-off ok "${s:0:160}"
  else res switch-control-centre-off FAIL "env ${g:-?}; $s"; fi
  tmo 900 "$CLI" enable control-centre --vm "$VM" --yes > "$OUT/${PFX}enable-cc.log" 2>&1; rc=$?
  gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py"
  if (( rc == 0 )); then baseline after-control-centre-back
  else res switch-control-centre-on FAIL "omacvm enable control-centre: exit $rc ($OUT/${PFX}enable-cc.log)"; fi
}

netcheck() { gssh "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://archlinux.org" 2>/dev/null; }
step_fastnet() {   # the fast network: while the VM runs, and after a restart
  log "fast network (limit 30 min)"
  local st blk to s why b net wantnet
  if [[ $(feat available fast-network) != true ]]; then res fastnet BLOCKED "not available here: $(feat reason fast-network)"; return; fi
  st=$(netd); blk=$(netd_blocked)
  if [[ -n $blk ]]; then res fastnet BLOCKED "$blk"; return; fi
  local q0
  for to in on off; do
    job_room
    bmark; q0=$(qemu_pid)
    cc toggle "Fast network" "$to" 600; s=$CCS
    sleep 10
    why=""
    ccok || why+="cc: $s; "
    [[ $(qemu_pid) == "$q0" ]] || why+="QEMU changed ($q0 -> $(qemu_pid)): the switch restarted the VM; "
    [[ $(mac_feature fast-network) == "$to" ]] || why+="the VM folder's features says $(mac_feature fast-network); "
    reachable 60 || why+="not reachable: $(vminfo); "
    [[ $(netcheck) == 200 ]] || why+="no internet in the VM; "
    b=$(bproblems); [[ -n $b ]] && why+="Bridge: $b; "
    if [[ -z $why ]]; then res "fastnet-running-$to" ok "${s:0:160}; network now: $(head -1 "$VMD/logs/network" 2>/dev/null)"
    else res "fastnet-running-$to" FAIL "${why}netd: $st"; fi
    bmark
    if restart_vm; then
      net=$(head -1 "$VMD/logs/network" 2>/dev/null)
      # The VM's network record (FastNetwork.swift): "vmnet", or "slirp off" when it is off by choice.
      wantnet=$([[ $to == on ]] && echo vmnet || echo "slirp off")
      why=""
      [[ $net == *"$wantnet"* ]] || why+="logs/network says '$net', want $wantnet; "
      [[ $(netcheck) == 200 ]] || why+="no internet in the VM; "
      b=$(bproblems); [[ -n $b ]] && why+="Bridge: $b; "
      [[ -z $why ]] && res "fastnet-restart-$to" ok "$net; $(vminfo)" || res "fastnet-restart-$to" FAIL "$why"
    else
      res "fastnet-restart-$to" FAIL "the VM or its control centre did not come back: $(vminfo)"
    fi
  done
}

step_touchid() {   # Touch ID: the test Bridge's stand-in answers (README)
  log "Touch ID (limit 20 min)"
  local s b
  if [[ $(feat available touch-id) != true ]]; then res touchid BLOCKED "not available here: $(feat reason touch-id)"; return; fi
  echo yes > "$BDIR/touchid-test"
  job_room
  bmark
  cc toggle "Touch ID" on 600; s=$CCS
  ccok && res touchid-on ok "${s:0:200}" || res touchid-on FAIL "after the switch, before a restart: $s"
  if restart_vm; then
    bmark; cc sudo yes 60; s=$CCS
    ccok && [[ $(bsince) == *"sudo yes (test stand-in"* ]] && res touchid-yes ok "${s:0:120}" \
      || res touchid-yes FAIL "$s; Bridge: $(bsince | grep -E 'touchid|unknown-vm' | tail -2 | tr '\n' '|')"
    echo no > "$BDIR/touchid-test"
    bmark; cc sudo no 60; s=$CCS
    ccok && res touchid-no ok "the password prompt: ${s:0:120}" || res touchid-no FAIL "$s; Bridge: $(bsince | grep touchid | tail -2 | tr '\n' '|')"
    echo yes > "$BDIR/touchid-test"
    # The first request right after a Bridge restart (enable touch-id restarts the installed Bridge).
    bmark; bridge_start; cc sudo yes 60; s=$CCS
    # Its Touch ID answers (other requests may get a 409 while the new Bridge lists the VMs: not this check).
    b=$(bsince | grep -E 'touchid' | tail -3 | tr '\n' '|')
    ccok && [[ $b == *"sudo yes"* && $b != *unknown-vm* && $b != *" 409"* ]] && res touchid-after-bridge-restart ok "${s:0:120}" \
      || res touchid-after-bridge-restart FAIL "$s; Bridge: $b"
  else
    res touchid-restart FAIL "the VM or its control centre did not come back after Touch ID on: $(vminfo)"
  fi
  job_room
  bmark
  cc toggle "Touch ID" off 600; s=$CCS
  ccok && res touchid-off ok "${s:0:160}" || res touchid-off FAIL "$s"
  if restart_vm; then
    cc sudo no 60; s=$CCS
    ccok && res touchid-off-password ok "off: the password as before" || res touchid-off-password FAIL "$s"
  else res touchid-off-restart FAIL "$(vminfo)"; fi
  echo no > "$BDIR/touchid-test"
}

graphics_mac() { "$CLI" graphics --vm "$VM" --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; o=json.load(sys.stdin); print(o.get("graphics"), o.get("next_start"), "|", o.get("this_start"))' 2>/dev/null; }
step_graphics() {   # each choice from the control centre; the Mac agrees; Vulkan after a restart
  log "Graphics (limit 40 min)"
  local g0 to s m b
  g0=$(graphics_mac | awk '{print $1}')
  for to in opengl vulkan auto; do
    job_room
    bmark
    cc graphics "$to" 1500; s=$CCS
    m=$(graphics_mac); b=$(bproblems)
    if ccok && [[ $m == "$to "* && -z $b ]] && reachable 30; then res "graphics-$to" ok "Mac: $m"
    else res "graphics-$to" FAIL "cc: ${s:0:200}; Mac: $m; Bridge: $b"; fi
    if [[ $to == vulkan ]]; then
      if restart_vm; then
        m=$(graphics_mac)
        [[ ${m#*|} == *"-> vulkan"* ]] && res graphics-vulkan-start ok "$m" || res graphics-vulkan-start FAIL "after a restart (this start should be Vulkan): $m"
      else res graphics-vulkan-start FAIL "the VM or its control centre did not come back: $(vminfo)"; fi
    fi
  done
  [[ -n $g0 && $g0 != auto ]] && { job_room; cc graphics "$g0" 1500; }
  return 0
}

step_updates() {   # the control centre's update check, and the Bridge's log
  log "update checks (limit 5 min)"
  local s b
  bmark
  cc updates 180; s=$CCS
  b=$(bsince | grep -E 'update check' | tail -1 | sed 's/^.*control: //')
  if ccok && [[ $b == *"update check: "*parts* ]]; then res updates-cc ok "Bridge: $b"
  else res updates-cc FAIL "cc: ${s:0:300}; Bridge: ${b:-no update check}"; fi
}

step_window() {   # the app's window (the VM stopped): update checks, the fast network button
  log "the app's window (limit 10 min)"
  local p e was now lbl k blk sw i
  if (( HIDDEN )); then res window skip "hidden run: the window steps need a screen nobody works on"; return; fi
  stop_vm || res window-stop FAIL "the VM did not shut down"
  if ! p=$(window); then res window FAIL "the app's window did not show $VM"; start_vm; return; fi
  "$OUT/ax" "$p" text > "$OUT/${PFX}window-before.txt" 2>&1
  "$OUT/ax" "$p" press "Check Now" > "$OUT/${PFX}ax-check.txt" 2>&1 && sleep 15
  "$OUT/ax" "$p" text > "$OUT/${PFX}window-check.txt" 2>&1
  e=$(grep -iE 'could not|failed|not signed|refused|error' "$OUT/${PFX}window-check.txt" | head -2 | tr '\n' '|')
  [[ -z $e && $(cat "$OUT/${PFX}ax-check.txt") == pressed* ]] && res window-check-now ok "$(grep -iE 'up to date|is ready|checked|newest' "$OUT/${PFX}window-check.txt" | head -1)" \
    || res window-check-now FAIL "$(cat "$OUT/${PFX}ax-check.txt"); $e"
  # The switch of the compact window (3.0.5), or the Turn On…/Turn Off… button before it.
  # The settings window (3.1.0) names the switch "Fast network", (experimental) beside it.
  sw=""; "$OUT/ax" "$p" has "Fast network (experimental)" > "$OUT/${PFX}ax-fastnet-has.txt" 2>&1 && sw="Fast network (experimental)"
  [[ -z $sw ]] && "$OUT/ax" "$p" has "Fast network" >> "$OUT/${PFX}ax-fastnet-has.txt" 2>&1 && sw="Fast network"
  if [[ -n $sw ]] || "$OUT/ax" "$p" has "Turn On…" >/dev/null 2>&1 || "$OUT/ax" "$p" has "Turn Off…" >/dev/null 2>&1; then
    blk=$(netd_blocked)
    if [[ -n $blk ]]; then
      res window-fastnet BLOCKED "$blk"
    else
      was=$([[ -s $VMD/fast-network ]] && echo on || echo off)
      for k in 1 2; do
        lbl=${sw:-$([[ -s $VMD/fast-network ]] && echo "Turn Off…" || echo "Turn On…")}
        "$OUT/ax" "$p" press "$lbl" > "$OUT/${PFX}ax-fastnet-$k.txt" 2>&1
        # The switch works off the main thread (the service check reads QEMU's signature): until the file
        # follows and the switch takes presses again (it is disabled meanwhile).
        for ((i = 0; i < 20; i++)); do [[ $([[ -s $VMD/fast-network ]] && echo on || echo off) != "$was" ]] && break; sleep 1; done
        for ((i = 0; i < 30; i++)); do "$OUT/ax" "$p" has "$lbl" >/dev/null 2>&1 && break; sleep 1; done
        sleep 1
        now=$([[ -s $VMD/fast-network ]] && echo on || echo off)
        [[ $now != "$was" && $(mac_feature fast-network) == "$now" ]] && res "window-fastnet-$now" ok "$lbl -> the VM's fast-network file and record: $now" \
          || res "window-fastnet-$k" FAIL "$lbl: file $now, record $(mac_feature fast-network) ($(cat "$OUT/${PFX}ax-fastnet-$k.txt"); $("$OUT/ax" "$p" text | grep -iE 'fast|password|could' | head -2 | tr '\n' '|'))"
        was=$now
      done
    fi
  else
    res window-fastnet FAIL "no fast network button in the window"
  fi
  close_window
  start_vm && reachable 60 || res window-start FAIL "$(vminfo)"
}

# A child harness ended (its rows are in): "ended RC" is a FAIL row of its own unless RC is what its
# rows say: 1 with a FAIL row, 5 (someone stayed) with a BLOCKED row. Its time limit (142) while it
# waited for someone at the Mac is BLOCKED; any other code (a crash, 3 for a setup error) is a FAIL.
child_end() {   # STEP SCRIPT RC SUMMARY LOG
  local step=$1 sc=$2 rc=$3 sum=$4 lg=$5
  (( rc == 0 )) && return 0
  (( rc == 1 )) && grep -q $'\tFAIL\t' "$sum" 2>/dev/null && return 0
  (( rc == 5 )) && grep -q $'\tBLOCKED\t' "$sum" 2>/dev/null && return 0
  if (( rc == 142 )) && grep -q 'PAUSE before' "$lg" 2>/dev/null; then
    res "$step" BLOCKED "$sc hit its time limit while it waited for someone at the Mac to leave: run it again on a quiet Mac"
  else res "$step" FAIL "$sc ended $rc: $(tail -2 "$lg" 2>/dev/null | tr '\n' '|')"; fi
}

# The VM's modifier keys from each event's flags (#412; modifier-keys.sh, on the running VM).
step_keys() {
  log "keys: modifier key cases into the VM (Universal Control's ways included)"
  # Its own time, and a wait for someone at the Mac between its cases (person.sh) on top.
  perl -e 'alarm shift; exec @ARGV' $(( 300 + PERSON_WAIT )) "$HERE/modifier-keys.sh" --vm "$VM" --out "$OUT/keys" > "$OUT/keys.log" 2>&1
  local rc=$?
  while IFS=$'\t' read -r st r d; do res "$st" "$r" "$d"; done < "$OUT/keys/summary.tsv" 2>/dev/null
  child_end keys modifier-keys.sh "$rc" "$OUT/keys/summary.tsv" "$OUT/keys.log"
}

# The VM's display unplugged under it, its window there (#402; display-unplug.sh, the VM stopped).
step_unplug() {
  if (( HIDDEN )); then res unplug skip "needs windows on this Mac's displays (--hidden)"; return; fi
  log "unplug: the display the VM's window is on unplugged, flapping, locked (limit 45 min)"
  perl -e 'alarm shift; exec @ARGV' $(( 2700 + PERSON_WAIT )) "$HERE/display-unplug.sh" --vm "$VM" --out "$OUT/unplug" > "$OUT/unplug.log" 2>&1
  local rc=$?
  while IFS=$'\t' read -r st r d; do res "$st" "$r" "$d"; done < "$OUT/unplug/summary.tsv" 2>/dev/null
  child_end unplug display-unplug.sh "$rc" "$OUT/unplug/summary.tsv" "$OUT/unplug.log"
}

steps() {   # every step on the running VM of this pass
  local st
  gate baseline; log "baseline"; baseline start   # every step below works through the control centre it starts
  for st in switches fastnet touchid graphics updates; do
    want "$st" || continue
    gate "$st"
    if [[ $CC_UP == 1 ]]; then "step_$st"
    else res "$st" FAIL "not run: the control centre did not come up (baseline-start)"; fi
  done
  want keys && { gate keys; step_keys; }
  want window && { gate window; step_window; }
  # While working on the test: the VM stays up this long first, to look at it (ssh, the cc's tmux).
  [[ ${OMACVM_E2E_HOLD:-} =~ ^[0-9]+$ ]] && { log "holding ${OMACVM_E2E_HOLD} s (OMACVM_E2E_HOLD), VM at ${IP:-?}"; sleep "$OMACVM_E2E_HOLD"; }
  stop_vm || res stop FAIL "the VM did not shut down"
  return 0
}

# Touch ID: the stand-in says no unless a step wants yes, so nothing ever shows macOS's dialog here.
mkdir -p "$BDIR"; echo no > "$BDIR/touchid-test"
bridge_start || res bridge FAIL "the test Bridge does not listen on 47931 ($BLOG)"

# ---- pass 1: this build, a VM brought to it with Update VM ----
if [[ $ONLY != ",update," ]]; then
  use_vm "$VM" "$CLONE"
  if want prepare; then
    gate prepare
    log "prepare: Update VM in the window (limit 25 min)"
    if d=$(update_vm_window); then res update-vm ok "$d"; else res update-vm FAIL "$d"; fi
  fi
  start_pass && steps
  want unplug && { gate unplug; step_unplug; }
  remove_clones
fi

# ---- pass 2: the release before -> this build through the app's updater, Update VM, every step again ----
if [[ -n $PREV ]] && want update; then
  gate update
  log "update path (limit 60 min, then every step again)"
  PFX=update-
  ORIG=$OUT/orig/OmacVM\ Test.app CAND=$OUT/candidate/OmacVM\ Test.app
  mkdir -p "$OUT/orig" "$OUT/candidate"; ditto "$APP" "$ORIG"; ditto "$APP" "$CAND"
  if [[ $PREV == latest ]]; then
    gh release download -R gillesgoetsch/OmacVM -p 'OmacVM-*.zip' -D "$OUT/prev" --clobber >/dev/null 2>&1 && PREV=$(ls "$OUT"/prev/OmacVM-*.zip | head -1)
  fi
  if [[ ! -f $PREV ]]; then res previous BLOCKED "no zip of the release before ($PREV)"
  elif ! "$HERE/relabel.sh" "$PREV" "$OUT/prev-app" > "$OUT/relabel.log" 2>&1; then res previous FAIL "relabel.sh: $OUT/relabel.log"
  else
    PV=$(plist "$OUT/prev-app/OmacVM Test.app" CFBundleShortVersionString)
    CV=$(plist "$CAND" CFBundleShortVersionString)
    if [[ $PV == "$CV" || $(printf '%s\n%s\n' "$PV" "$CV" | sort -V | tail -1) != "$CV" ]]; then
      # Before the release commit this build still says the version before: one patch above, for the updater only.
      CV=${PV%.*}.$(( ${PV##*.} + 1 ))
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CV" -c "Set :CFBundleVersion $CV" "$CAND/Contents/Info.plist"
      codesign --force --sign "${OMACVM_SIGN_ID:?OMACVM_SIGN_ID: the Developer ID to sign the candidate again}" --options runtime \
        --preserve-metadata=entitlements,identifier "$CAND" 2>> "$OUT/relabel.log"
      res version skip "this build says $PV like the release before: offered to the updater as $CV"
    fi
    # The release before, and a VM it set up as a person has it: Update VM in its window, the
    # features a new VM has (a kept VM has the Bridge and the control centre off), its control centre.
    PFX=previous-
    rm -rf "$APP"; ditto "$OUT/prev-app/OmacVM Test.app" "$APP"
    bridge_start
    if [[ -n $CLONE ]]; then use_vm "$VM-u" "$CLONE"; else use_vm "$VM"; fi
    if d=$(update_vm_window); then res update-vm ok "$PV: $d"; else res update-vm FAIL "$PV: $d"; fi
    ONLY=""   # its prepare too, whatever --only said
    start_pass && baseline start
    PFX=update-
    # A local feed, signed with a throwaway key (test builds take OMACVM_APPCAST_KEY).
    F=$OUT/feed; mkdir -p "$F"
    swift "$R/src/release/sign.swift" keygen "$F/key" > "$F/key.pub" 2>/dev/null
    (cd "$OUT/candidate" && ditto -c -k --keepParent "OmacVM Test.app" "$F/OmacVM-$CV.zip")
    TEAM=$(codesign -dv "$CAND" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    PORT=$(( 18800 + RANDOM % 400 ))
    printf '{"schema": 1, "kind": "app-feed", "version": "%s", "url": "http://127.0.0.1:%s/OmacVM-%s.zip", "length": %s, "sha256": "%s", "minimum_macos": "15.0", "devid_teams": ["%s"]}\n' \
      "$CV" "$PORT" "$CV" "$(stat -f %z "$F/OmacVM-$CV.zip")" "$(shasum -a 256 "$F/OmacVM-$CV.zip" | cut -d' ' -f1)" "$TEAM" > "$F/OmacVM-appcast.json"
    swift "$R/src/release/sign.swift" sign "$F/key" "$F/OmacVM-appcast.json" > "$F/OmacVM-appcast.json.sig"
    /usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$F" > "$OUT/feed-server.log" 2>&1 & SERVER=$!
    sleep 1
    # The app updates itself (as the window's "Update to X" does, without the window: --update-now).
    # The VM shuts down first, while its launcher runs: the launcher removes the VM's run marker when it
    # sees QEMU end cleanly. A launcher killed first leaves the marker, and the next Update VM and start
    # then ask "not shut down cleanly" in a modal alert (Update VM's press: -25204; the start never comes).
    # The release before removes the marker on that clean stop: a marker left here is a product failure.
    PFX=previous-
    if stop_vm; then
      for ((i = 0; i < 5; i++)); do [[ -e $VMD/running ]] || break; sleep 1; done
      if [[ -e $VMD/running ]]; then res stop FAIL "shut down from inside, but its run marker stays ($VMD/running)"
      else res stop ok "shut down from inside while its launcher ran; run marker gone"; fi
    else res stop FAIL "the VM of the release before did not shut down from inside"; fi
    PFX=update-
    close_window
    # The test Bridge and Gestures run from inside the app (a person's live outside it): the updater
    # would wait for them ("A VM runs from OmacVM Test" is any process inside the app).
    GESTURES_RAN=$(LC_ALL=C pgrep -f "OmacVM Test Gestures.app/Contents/MacOS/" | head -1)
    stop_inside_app
    # What the person set stays through the app's update: the app's settings (window places and
    # timing bookkeeping aside, by exact name), the update switch both the app and the control
    # centre read (settings.json: update_checks) and the VM folder's records.
    settings_snap() { defaults export "$APPID" - 2>/dev/null | /usr/bin/python3 -I -c 'import plistlib, re, sys
d = plistlib.loads(sys.stdin.buffer.read() or plistlib.dumps({}))
skip = re.compile(r"^(NSWindow |NSSplitView |NSToolbar |NSNavPanel|NSStatusItem |buildStepSeconds\.|FastNetworkServiceOK$)")
for k in sorted(d):
    if not skip.search(k): print("app", k, repr(d[k])[:200])'
      /usr/bin/python3 -I -c 'import json, os, sys
f = os.path.expanduser(os.environ.get("OMACVM_SETTINGS_DIR") or "~/Library/Application Support/omacvm") + "/settings.json"
try: o = json.load(open(f))
except FileNotFoundError: print("settings.json none"); sys.exit()
except ValueError: print("settings.json unreadable"); sys.exit()
for k in sorted(o): print("settings.json", k, json.dumps(o[k])[:200])'
      (cd "$VMD" && for f in vm.env features graphics fast-network omarchy; do [[ -f $f ]] && echo "$f $(shasum -a 256 "$f" | cut -c1-16)"; done); }
    SET_BEFORE=$(settings_snap)
    hide=(); (( HIDDEN )) && hide=(--env OMACVM_COCOA_HIDDEN=1)   # the updated app starts again: no window either
    open -n -g --env "OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json" --env "OMACVM_APPCAST_KEY=$(cat "$F/key.pub")" \
      ${hide[@]+"${hide[@]}"} "$APP" --args --update-now
    for ((i = 0; i < 300; i += 5)); do [[ $(plist "$APP" CFBundleShortVersionString) == "$CV" ]] && break; sleep 5; done
    sleep 10; close_window
    UPD=$(ls -dt "$HOME/Library/Application Support/OmacVM/Updates/$APPID"/*/ 2>/dev/null | head -1)
    if [[ $(plist "$APP" CFBundleShortVersionString) == "$CV" ]] && codesign --verify --deep --strict "$APP" 2>/dev/null; then
      res app-self-update ok "$PV -> $CV through the app's updater: $(grep 'result:' "$UPD/update.log" 2>/dev/null | tail -1)"
      printf '%s\n' "$SET_BEFORE" > "$OUT/settings-before.txt"; settings_snap > "$OUT/settings-after.txt"
      SET_DIFF=$(diff "$OUT/settings-before.txt" "$OUT/settings-after.txt" | grep '^<' | head -5 | tr '\n' ' ')
      if [[ -z $SET_DIFF ]]; then res settings-kept ok "$(wc -l <<<"$SET_BEFORE" | tr -d ' ') settings (app, settings.json) and VM records as before the update"
      else res settings-kept FAIL "changed or gone after the update: $SET_DIFF"; fi
      bridge_start   # this build's Bridge (an installed app restarts it when its helpers change)
      # A person's Gestures runs on through an update (it lives outside the app); the test one was stopped.
      [[ -n $GESTURES_RAN ]] && { gestures_start || res gestures-again FAIL "the test Gestures does not listen on 47930 again"; }
      if d=$(update_vm_window); then res update-vm ok "$d"; else res update-vm FAIL "$d"; fi
      ONLY=""   # every step again on the updated VM
      start_pass && steps
    else
      res app-self-update FAIL "still $(plist "$APP" CFBundleShortVersionString): $(tail -3 "$UPD/update.log" 2>/dev/null | tr '\n' '|')"
    fi
  fi
  remove_clones
fi
FINISHED=1
(( n_fail == 0 && n_blocked == 0 ))
