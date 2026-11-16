#!/bin/bash
# The VM's modifier keys follow each event's flags (#412). Part of the release
# gate (cc-switches.sh, step "keys"); also alone on a test Mac. Key events with
# exact flags go into the running VM's QEMU (CGEventPostToPid: only that
# process gets them, so it works with the Mac's screen locked and nobody else's
# keys move); the guest's virtio keyboard is read back over SSH and must show
# exactly the keys of each case:
#   mac-shift2        Shift+2 as the Mac's own keyboard sends it
#   uc-*              Shift's flagsChanged twice, or an event without flags
#                     right after it (with and without the left/right key
#                     bits): Universal Control; 3.1.8 typed 2 here
#   right-shift-twice, both-shifts, option-*, control-*, caps-lock, held-repeat
#   command-nocap-*   Command while the VM does not have the keyboard: nothing
#
#   src/tests/e2e/modifier-keys.sh --vm NAME [--out DIR]
#     --out DIR     summary.tsv and each case's guest trace (default ~/omacvm-e2e/keys-<time>)
# Needs: NAME running from ~/Applications/"OmacVM Test.app" (org.omacvm.app.test),
# clang (builds keyseq.c). Between cases it waits while someone is at the Mac
# (person.sh: input not ours; an idle remote session does not count): a key of
# theirs can move the timing the cases check. A case that failed while
# someone came and went gets a BLOCKED "person" row. Our own events are stamped
# (person_posted), so they never count as someone's.
# Exit 0 only when every case passed; 1 a case failed; 2 a wrong call; 3 it could
# not run (no VM, no SSH, no tool); 5 someone stayed at the Mac (BLOCKED rows).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/person.sh"

VM=""; OUT=""
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "usage: modifier-keys.sh --vm NAME [--out DIR]" >&2; exit 2 ;;
  esac
done
[[ -n $VM ]] || { echo "modifier-keys: --vm NAME (a test VM)" >&2; exit 2; }

export OMACVM_TEST_IDENTITY=1
APPID=org.omacvm.app.test
KEY=$HOME/.ssh/omacvm
OUT=${OUT:-$HOME/omacvm-e2e/keys-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
: > "$OUT/summary.tsv"
n_fail=0; n_blocked=0
res() {   # STEP ok|FAIL|BLOCKED|skip DETAIL
  printf '%s\t%s\t%s\n' "keys-$1" "$2" "$3" >> "$OUT/summary.tsv"
  printf '%-34s %-7s %s\n' "keys-$1" "$2" "$3"
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
# The trap first: a run stopped right after the watcher started leaves no watcher folder behind.
trap 'person_watch_stop' EXIT
person_watch_start

VMD=$( (source "$HERE/test-vms.sh" && e2e_vm_guard "$APPID" "$VM") 2>&1) || { echo "modifier-keys: $VMD" >&2; exit 2; }
QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
PID=$(LC_ALL=C pgrep -f "$QPAT $VM( |$)" | head -1)
[[ -n $PID ]] || { echo "modifier-keys: $VM does not run" >&2; exit 3; }
port() { sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'"; }
gssh() { ssh -i "$VMD/ssh-key" -i "$KEY" -p "$(port)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"; }

KS="$OUT/keyseq"
clang -O1 -framework ApplicationServices "$HERE/keyseq.c" -o "$KS" > "$OUT/build-tool.log" 2>&1 ||
  { echo "modifier-keys: could not build keyseq ($OUT/build-tool.log)" >&2; exit 3; }
# The guest's reader: the virtio keyboard's key events (ms code value) for N seconds.
gssh "cat > /root/omacvm-evread.py" <<'EOF' || { echo "modifier-keys: no SSH to $VM" >&2; exit 3; }
import os, select, struct, sys, time
dev = None
for block in open('/proc/bus/input/devices').read().split('\n\n'):
    if 'QEMU Virtio Keyboard' in block:
        for l in block.splitlines():
            if l.startswith('H: Handlers='):
                dev = '/dev/input/' + [h for h in l.split('=')[1].split() if h.startswith('event')][0]
if not dev:
    sys.exit('no QEMU Virtio Keyboard')
fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
end = time.time() + float(sys.argv[1])
print('ready', dev, flush=True)
fmt = 'llHHi'; size = struct.calcsize(fmt)
while time.time() < end:
    if not select.select([fd], [], [], 0.2)[0]:
        continue
    data = os.read(fd, size * 64)
    for i in range(0, len(data) - size + 1, size):
        sec, usec, typ, code, val = struct.unpack(fmt, data[i:i + size])
        if typ == 1:
            print('%d %d %d' % (sec * 1000 + usec // 1000, code, val), flush=True)
EOF

# name | events (keyseq) | the guest's keys (Linux code:value; repeats left out):
# 42 LShift, 54 RShift, 29 LCtrl, 97 RCtrl, 56 LAlt, 100 RAlt, 58 Caps Lock, 3 the 2 key, 183 F13
CASES='mac-shift2|fc:0x38:0x20102 kd:0x13:0x20102 ku:0x13:0x20102 fc:0x38:0x100|42:1 3:1 3:0 42:0
uc-twice|fc:0x38:0x20102 fc:0x38:0x20102 wait:300 kd:0x13:0x20102 ku:0x13:0x20102 fc:0x38:0x100|42:1 3:1 3:0 42:0
uc-flagless|fc:0x38:0x20102 ptr:0x0 wait:300 kd:0x13:0x20102 ku:0x13:0x20102 fc:0x38:0x100|42:1 42:0 42:1 3:1 3:0 42:0
uc-twice-nobits|fc:0x38:0x20000 fc:0x38:0x20000 kd:0x13:0x20000 ku:0x13:0x20000 fc:0x38:0x0|42:1 3:1 3:0 42:0
uc-flagless-nobits|fc:0x38:0x20000 ptr:0x0 kd:0x13:0x20000 ku:0x13:0x20000 fc:0x38:0x0|42:1 42:0 42:1 3:1 3:0 42:0
right-shift-twice|fc:0x3c:0x20104 fc:0x3c:0x20104 kd:0x13:0x20104 ku:0x13:0x20104 fc:0x3c:0x100|54:1 3:1 3:0 54:0
both-shifts|fc:0x38:0x20102 fc:0x3c:0x20106 fc:0x3c:0x20102 kd:0x13:0x20102 ku:0x13:0x20102 fc:0x38:0x100|42:1 54:1 54:0 3:1 3:0 42:0
option-left|fc:0x3a:0x80120 kd:0x69:0x80120 ku:0x69:0x80120 fc:0x3a:0x100|56:1 183:1 183:0 56:0
option-right|fc:0x3d:0x80140 kd:0x69:0x80140 ku:0x69:0x80140 fc:0x3d:0x100|100:1 183:1 183:0 100:0
control-left|fc:0x3b:0x40101 kd:0x69:0x40101 ku:0x69:0x40101 fc:0x3b:0x100|29:1 183:1 183:0 29:0
control-right|fc:0x3e:0x42100 kd:0x69:0x42100 ku:0x69:0x42100 fc:0x3e:0x100|97:1 183:1 183:0 97:0
command-nocap-left|fc:0x37:0x100108 kd:0x69:0x100108 ku:0x69:0x100108 fc:0x37:0x100|
command-nocap-right|fc:0x36:0x100110 kd:0x69:0x100110 ku:0x69:0x100110 fc:0x36:0x100|
caps-lock|fc:0x39:0x10100 wait:300 fc:0x39:0x100|58:1 58:0 58:1 58:0
held-repeat|fc:0x38:0x20102 kd:0x13:0x20102 kd:0x13:0x20102 kd:0x13:0x20102 ku:0x13:0x20102 fc:0x38:0x100|42:1 3:1 3:0 42:0'

# Command reaches the VM only while it has the keyboard: the nocap cases need it in the background.
front=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
while IFS='|' read -r name evs want; do
  [[ -n $PERSON_WHY ]] && { res "$name" BLOCKED "not run: $PERSON_WHY"; continue; }
  person_gate "keys-$name" || { res "$name" BLOCKED "not run: $PERSON_WHY"; continue; }
  GATE_LINE=$(wc -l < "$OUT/summary.tsv" | tr -d ' ')
  if [[ $name == command-nocap-* && $front == "$PID" ]]; then
    res "$name" skip "the VM has the keyboard (in front)"; continue
  fi
  f="$OUT/$name.txt"
  gssh "python3 /root/omacvm-evread.py 5" < /dev/null > "$f" 2>&1 &
  rp=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '^ready' "$f" 2>/dev/null && break; sleep 0.3; done
  # shellcheck disable=SC2086  # one word per event
  person_posted 3; "$KS" --pid "$PID" $evs; person_posted 2
  wait $rp
  got=$(awk '$1 ~ /^[0-9]+$/ && $3 != 2 {printf "%s%s:%s", (n++ ? " " : ""), $2, $3}' "$f")
  times=$(awk '$1 ~ /^[0-9]+$/ && $3 != 2 {if (!t0) t0 = $1; printf "%s%s:%s@%d", (n++ ? " " : ""), $2, $3, $1 - t0}' "$f")
  if [[ $got == "$want" ]]; then res "$name" ok "${times:-nothing}"
  else res "$name" FAIL "got [${times:-nothing}] want [${want:-nothing}]"; fi
done <<< "$CASES"
# Nothing at all would also pass the nocap cases: the others must have arrived.
ev=$(_person_new | _person_events); [[ -n $ev ]] && person_overlap "$ev" end
if ! grep -q $'^keys-mac-shift2\tok' "$OUT/summary.tsv"; then
  if grep -q $'^keys-mac-shift2\tBLOCKED' "$OUT/summary.tsv"; then res delivery BLOCKED "not checked: mac-shift2 did not run"
  else res delivery FAIL "no key reached the VM"; fi
fi
gssh "rm -f /root/omacvm-evread.py" < /dev/null
(( n_fail > 0 )) && exit 1
(( n_blocked > 0 )) && exit 5
exit 0
