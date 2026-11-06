#!/bin/bash
# Move an OmacVM.app VM from Omarchy 4.0 (omarchy-mac) to Omarchy 4.5 on the
# official aarch64 repos, with a backup first: "Move to Omarchy 4.5" in the
# VM window (OmarchyMoveCard.swift; rules in OmacVMWindow/OmarchyMove.swift).
#   move-vm.sh VM_DIR plan           the Mac's checks: need=, free=, apfs=, problem= (exit 3: blocked)
#   move-vm.sh VM_DIR run            the move, or its resume (the VM off)
#   move-vm.sh VM_DIR undo           the backup's disk back (the VM off); the moved disk goes
#   move-vm.sh VM_DIR delete-backup  the backup goes (after a move); Undo is no longer possible
#   move-vm.sh VM_DIR keep           a stopped move: keep this disk as it is (the backup stays)
#   move-vm.sh VM_DIR status         the journal and the backup's size
# The journal is VM_DIR/move-4.5 (key=value, format=1); the backup is
# VM_DIR/before-omarchy-4.5/ (APFS clones of disk.img and efi-vars.fd, copies
# of the small records, README.txt). A file VM_DIR/move-4.5.stop asks a run
# to stop at the next safe point (the app's Stop and Quit); the guest never
# stops inside its package switch. Progress lines as update-vm.sh ("STEP
# n/8", "==>"); SSH that turns the folder's key down: "FIX ssh-key" with the
# app's answer on stdin, as update-vm.sh. The guest side is
# /usr/local/share/omacvm/guest/omarchy-move.sh (work/v340/contract.md).
# Exit: 0 done, 1 failed (the journal says why and whether Resume works),
# 2 usage, 3 refused (nothing changed). OMACVM_MOVE_NO_MAC=1 (test rows): the
# Mac's helpers are left as they are (apply-vm.sh --no-mac).
set -euo pipefail
exec 3<&0 < /dev/null
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"

[[ $# -eq 2 ]] || { echo "usage: move-vm.sh VM_DIR plan|run|undo|delete-backup|keep|status" >&2; exit 2; }
CMD=$2
case $CMD in plan|run|undo|delete-backup|keep|status) ;; *) echo "move-vm.sh: unknown command $CMD" >&2; exit 2 ;; esac
vm_load "$1"
J=$VM_DIR/move-4.5
B=$VM_DIR/before-omarchy-4.5
STOP=$VM_DIR/move-4.5.stop
G=/usr/local/share/omacvm/guest/omarchy-move.sh
STEPS=8
# The records the backup keeps beside the disk (Undo puts them back).
RECORDS=(vm.env features graphics omacvm-version guest-pointer omarchy)

# ---------- the journal ----------
jget() { [[ -f $J ]] && sed -n "s/^$1=//p" "$J" | head -1 || true; }
jset() {   # jset KEY VALUE [KEY VALUE ...]: one write, never half written
  local tmp=$J.new k v
  [[ -f $J ]] && cp "$J" "$tmp" || echo "format=1" > "$tmp"
  while (( $# >= 2 )); do
    k=$1 v=${2//$'\n'/ }; shift 2
    v=${v:0:400}
    if grep -q "^$k=" "$tmp"; then
      awk -v k="$k" -v v="$v" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
    else
      printf '%s=%s\n' "$k" "$v" >> "$tmp"
    fi
  done
  mv -f "$tmp" "$J"
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The Mac's start time: a pid from before a restart is someone else's now.
boot_time() { sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p'; }
alive() {
  local p b; p=$(jget pid); b=$(jget boot)
  [[ $p =~ ^[0-9]+$ ]] && (( p > 1 && p != $$ )) && kill -0 "$p" 2>/dev/null || return 1
  [[ -z $b || $b == "$(boot_time)" ]]
}

in_use() {   # a QEMU (this app's, another copy's, omacvm start's) has the disk open
  ps -x -U "$(id -u)" -o args= | grep -v grep | grep -qF -- "file=$(qe "$VM_DIR/disk.img")," && return 0
  # Spotlight and backup readers open a new file for a moment: only a VM counts.
  /usr/sbin/lsof -F c -- "$VM_DIR/disk.img" 2>/dev/null | grep -qiE '^c(OmacVM|qemu)'
}
in_use_who() {   # for the log: which process has the disk
  { ps -x -U "$(id -u)" -o pid=,comm= -o args= | grep -v grep | grep -F -- "file=$(qe "$VM_DIR/disk.img"),"
    /usr/sbin/lsof -F pc -- "$VM_DIR/disk.img" 2>/dev/null | paste -sd' ' -; } | cut -c1-120 | head -2 | tr '\n' ' '
}
alloc_bytes() { echo $(( $(stat -f %b "$1") * 512 )); }
free_bytes() { echo $(( $(df -k "$VM_DIR" | awk 'NR==2 { print $4 }') * 1024 )); }
clones_ok() {   # the VM folder's volume is APFS: cp -c makes clones there (elsewhere it copies, rc 0)
  local dev t=$VM_DIR/.move-clone-test ok=1
  dev=$(df "$VM_DIR" | awk 'NR == 2 { print $1 }')
  [[ -n $dev ]] && /sbin/mount | awk -v d="$dev" '$1 == d' | grep -q '(apfs[,)]' || return 1
  rm -f "$t" "$t.c"; echo x > "$t"
  cp -c "$t" "$t.c" 2>/dev/null || ok=0
  rm -f "$t" "$t.c"; (( ok ))
}
gb() { awk -v b="$1" 'BEGIN { g = b / 1073741824; if (g >= 10) printf "%d GB", g + 0.5; else printf "%.1f GB", g }'; }

# The Mac's checks (OmarchyMove.problem says the same in the window).
mac_problem() {
  in_use && { echo "$NAME runs: shut it down first. ($(in_use_who))"; return; }
  clones_ok || { echo "The backup needs the VM on a Mac-formatted (APFS) drive. Move the VM to one under Storage first."; return; }
  [[ -f $VM_DIR/disk-resize ]] && { echo "A change of the disk's size is not finished. Start the VM once (or go back) first."; return; }
  grep -qx grow "$VM_DIR/disk-jobs" 2>/dev/null && { echo "Omarchy grows into the disk's new size at the next start. Start the VM once first."; return; }
  # A backup made already (a resume) holds its blocks: the downloads and the reserve are what is left to find.
  local need free
  if [[ -f $B/disk.img ]]; then need=$(( (10 + 4) << 30 )); else need=$(( $(alloc_bytes "$VM_DIR/disk.img") + ((10 + 4) << 30) )); fi
  free=$(free_bytes)
  (( free >= need )) || { echo "Not enough free space: the move needs $(gb "$need") free on this drive, it has $(gb "$free")."; return; }
  return 0
}

# ---------- plan, status, keep, delete-backup, undo ----------
case $CMD in
plan)
  a=$(alloc_bytes "$VM_DIR/disk.img"); f=$(free_bytes)
  c=1; clones_ok || c=0
  p=$(mac_problem)
  printf 'need=%s\nfree=%s\napfs=%s\nproblem=%s\n' $(( a + ((10 + 4) << 30) )) "$f" "$c" "$p"
  [[ -z $p ]] || exit 3
  exit 0 ;;
status)
  [[ -f $J ]] && cat "$J" || echo "state=none"
  if [[ -d $B ]]; then echo "backup=$B"; fi
  exit 0 ;;
keep)
  [[ -f $J ]] || { echo "no move to keep" >&2; exit 3; }
  case $(jget state) in running|failed|interrupted) ;; *) echo "the move is not stopped" >&2; exit 3 ;; esac
  alive && { echo "the move still runs" >&2; exit 3; }
  jset state kept finished "$(now_iso)"
  echo "KEPT $NAME"; exit 0 ;;
delete-backup)
  [[ -d $B ]] || { jset state done-final; echo "no backup"; exit 0; }
  case $(jget state) in done|kept|undone|done-final|"") ;; *) die "Undo the move or keep this disk first, then delete the backup" ;; esac
  alive && die "the move still runs"
  rm -rf "$B"
  [[ ! -e $B ]] || die "could not delete $B"
  jset state done-final
  echo "DELETED $B"; exit 0 ;;
undo)
  alive && die "$NAME is being moved: stop it first"
  in_use && die "$NAME runs: shut it down, then undo the move"
  if [[ -f $B/disk.img ]]; then
    # The backup's files back in place: rename() replaces the moved ones at once.
    mv -f "$B/disk.img" "$VM_DIR/disk.img"
    [[ -f $B/efi-vars.fd ]] && mv -f "$B/efi-vars.fd" "$VM_DIR/efi-vars.fd"
    for r in "${RECORDS[@]}"; do
      [[ $r == vm.env ]] && continue
      if [[ -f $B/$r ]]; then cp -p "$B/$r" "$VM_DIR/$r"; else rm -f "$VM_DIR/$r"; fi
    done
    # Only the disk's size of vm.env (CPUs or memory changed since stay).
    gbk=$(sed -n 's/^DISK_GB=//p' "$B/vm.env" 2>/dev/null | head -1)
    if [[ $gbk =~ ^[0-9]+$ ]]; then
      sed -i '' "s/^DISK_GB=.*/DISK_GB=$gbk/" "$VM_DIR/vm.env"
    fi
    rm -rf "$B"
    log "the disk from before the move is back"
  elif [[ -d $B ]]; then
    rm -rf "$B"   # a backup cut short: the disk was never changed
  fi
  rm -f "$STOP"
  jset state undone finished "$(now_iso)"
  echo "UNDONE $NAME"; exit 0 ;;
esac

# ---------- run ----------
[[ -f $VM_DIR/disk.img && -f $VM_DIR/efi-vars.fd && -e $VM_DIR/ready ]] || die "$NAME is not a finished VM"
LOCKD=$RUN_DIR/$VM_ID.move.lock
mkdir "$LOCKD" 2>/dev/null || { alive && die "$NAME is being moved already"; rm -rf "$LOCKD"; mkdir "$LOCKD"; }
state=$(jget state)
case $state in
  done|kept|done-final) rm -rf "$LOCKD"; echo "move-vm.sh: $NAME was moved already" >&2; exit 3 ;;
  running) alive && { rm -rf "$LOCKD"; die "$NAME is being moved already"; } ;;
esac
if [[ $state == running || $state == failed || $state == interrupted ]] && [[ $(jget commit_started) == 1 && $(jget resumable) == 0 ]]; then
  rm -rf "$LOCKD"
  die "The move stopped while Omarchy's packages were being switched, so it cannot go on. Undo brings the disk from before the move back."
fi
if [[ -z $state || $state == undone ]]; then
  rm -f "$J"
  jset state running step 0 started "$(now_iso)" finished "" failed_step 0 reason "" code "" resumable 1 commit_started 0 \
    from_omacvm "$(cat "$VM_DIR/omacvm-version" 2>/dev/null || true)" \
    from_disk_gb "$(sed -n 's/^DISK_GB=//p' "$VM_DIR/vm.env" | head -1)" backup_at ""
fi
jset state running pid $$ boot "$(boot_time)" reason "" code "" failed_step 0
rm -f "$STOP"

AGENT=$RUN_DIR/$VM_ID.qga
WATCH=""
OUTCOME=""   # done | failed | stopped
STARTED=0    # only a QEMU this run started is ever stopped
stop_vm() {
  (( STARTED )) && qemu_running || return 0
  # The guest's move unit stops at its next safe point on a shutdown (up to
  # 15 minutes inside the package switch): never cut that off early.
  if vssh "systemctl poweroff" < /dev/null 2>/dev/null; then qemu_wait_exit 960 || qemu_quit
  else qmp system_powerdown || true; qemu_wait_exit 120 || qemu_quit; fi
}
finish() {
  local rc=$?
  set +e
  [[ -z $WATCH ]] || kill "$WATCH" 2>/dev/null || true
  guest_log
  stop_vm
  rm -f "$AGENT" "$STOP"
  rm -rf "$LOCKD"
  if [[ $(jget state) == running ]]; then
    # Ended without a word (an error in this script, a signal): stopped, not failed.
    jset state interrupted pid 0 reason "${OUTCOME:-The move stopped (exit $rc).}"
  else
    jset pid 0
  fi
}
trap finish EXIT
trap 'touch "$STOP"' TERM INT HUP
# The app gone (crashed, killed): a write to its pipe fails instead of killing
# this script without its EXIT trap, so the VM still stops at a safe point and
# the journal says where (the window offers Resume or Undo at the next open).
trap '' PIPE
PARENT=$PPID   # the app; gone (crashed, killed): stop at the next safe point

step() { jset step "$1"; echo "STEP $1/$STEPS $2"; }
# The guest's own log beside the app's (logs/move-4.5.log), while the VM runs.
guest_log() {
  (( STARTED )) && qemu_running || return 0
  local f
  # The move's log, and Omarchy's own update's (its last part runs omarchy update).
  for f in omacvm-move-45:move-4.5 omacvm-system-update:move-system-update; do
    if vssh "cat /var/log/${f%%:*}.log" < /dev/null 2>/dev/null | printable > "$LOG/${f#*:}.log.new"; then
      mv -f "$LOG/${f#*:}.log.new" "$LOG/${f#*:}.log"
    else
      rm -f "$LOG/${f#*:}.log.new"
    fi
  done
}
fail() {   # fail STEP REASON [resumable 0|1] [code]
  jset state failed failed_step "$1" reason "$2" resumable "${3:-1}" code "${4:-}" finished ""
  OUTCOME=failed
  die "$2"
}
stopped() {   # a stop asked for (Stop and Quit): Resume or Undo at the next open
  jset state interrupted reason "Stopped at step $(jget step) of $STEPS (OmacVM quit)."
  OUTCOME=stopped
  echo "STOPPED $NAME"
  exit 1
}
stop_asked() { [[ -e $STOP ]]; }

step 1 "Check this Mac"
p=$(mac_problem) || true
[[ -z $p ]] || fail 1 "$p" 1 mac
stop_asked && stopped

step 2 "Shut down the VM"
in_use && fail 2 "$NAME runs: shut it down, then move it. ($(in_use_who))" 1 runs
log "$NAME is shut down"

step 3 "Back up the disk"
if [[ -n $(jget backup_at) && -f $B/disk.img ]]; then
  log "the backup from $(jget backup_at) is kept"
else
  # Checked again right before: on another file system cp -c copies the whole disk.
  clones_ok || fail 3 "The backup needs the VM on a Mac-formatted (APFS) drive. Move the VM to one under Storage first." 1 mac
  rm -rf "$B"; mkdir -p "$B"
  # clonefile: no copy of the data, the two share every block until one changes.
  cp -c "$VM_DIR/disk.img" "$B/disk.img" || { rm -rf "$B"; fail 3 "Could not back up disk.img (APFS clone failed)." 1 backup; }
  cp -c "$VM_DIR/efi-vars.fd" "$B/efi-vars.fd" || { rm -rf "$B"; fail 3 "Could not back up efi-vars.fd." 1 backup; }
  for r in "${RECORDS[@]}"; do [[ ! -f $VM_DIR/$r ]] || cp -p "$VM_DIR/$r" "$B/$r"; done
  cat > "$B/README.txt" <<EOF
$NAME as it was before the move to Omarchy 4.5 ($(date '+%Y-%m-%d %H:%M')).
OmacVM keeps it until you click "Delete the old backup" in the VM's window.
"Undo move" puts this disk back. Do not start a VM from this folder.
EOF
  sync
  jset backup_at "$(now_iso)"
  log "disk.img and its records are backed up in $(basename "$B")"
fi
[[ ${OMACVM_TEST_MOVE_STOP:-} == backup ]] && stopped   # src/tests/app-move-vm.sh: no VM there
stop_asked && stopped

# ---------- the VM, without a window ----------
REASON=$LOG/move-stopped
rm -f "$REASON"
watch_disk() {
  local line
  while qemu_running; do
    if line=$(disk_error "$LOG/move-console.log"); then printf 'disk %s\n' "$line" > "$REASON"; qemu_quit; return; fi
    sleep 3
  done
}
vm_up() {
  rm -f "$AGENT"
  qemu_headless move "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 \
    -device virtio-serial-pci,id=vser0 -chardev "socket,id=qga0,path=$(qe "$AGENT"),server=on,wait=off" \
    -device virtserialport,bus=vser0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0
  STARTED=1
  watch_disk &
  WATCH=$!
}
disk_why() {
  local r; r=$(cat "$REASON" 2>/dev/null) || r=""
  [[ $r == disk* ]] && echo "$NAME's disk has errors (the VM says: ${r#disk }). Undo brings the disk from before the move back." && return 0
  return 1
}

step 4 "Update OmacVM in the VM"
vm_up
rc=0; wait_ssh 300 refused || rc=$?
if (( rc == 2 )); then
  log "$NAME doesn't know this VM folder's SSH key: adding it"
  echo "FIX ssh-key"
  fix=""; read -r -t "${OMACVM_FIX_SECONDS:-180}" -u 3 fix || fix=""
  rc=2
  if [[ $fix == added || $fix == present ]]; then rc=0; wait_ssh 60 refused || rc=$?; fi
  (( rc == 0 )) || { echo "SSHKEY refused"; fail 4 "$NAME doesn't let this Mac in over SSH. Click Update VM, then move it again." 1 ssh; }
elif (( rc != 0 )); then
  w=$(disk_why) || w="$NAME did not come up within 5 minutes (log: $LOG/move-console.log)."
  fail 4 "$w" 1 boot
fi
exec 3<&-
export OMACVM_KERNEL_NEW=keep OMACVM_MOVE_RUN=1
# Test rows: the Mac's helpers left as they are (as create-vm.sh's OMACVM_CREATE_NO_MAC).
APPLY_ARGS=(); [[ ${OMACVM_MOVE_NO_MAC:-} == 1 ]] && APPLY_ARGS=(--no-mac)
run_logged "$LOG/move-apply.log" "$HERE/apply-vm.sh" "$VM_DIR" ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"} ||
  fail 4 "$(disk_why || echo "OmacVM did not update in the VM (log: $LOG/move-apply.log). Nothing of Omarchy was changed.")" 1 apply
vssh "test -x $G" < /dev/null || fail 4 "This VM's OmacVM has no Omarchy move (log: $LOG/move-apply.log)." 1 guest-old
stop_asked && stopped

# The phases' names (contract.md "phases") in plain words.
phase_text() {
  case $1 in
    preflight) echo "checking the VM" ;; protect) echo "keeping OmacVM's packages" ;; initramfs) echo "boot image settings" ;;
    keyring) echo "new package keys" ;; repos) echo "Omarchy 4.5's package sources" ;; download) echo "downloading packages" ;;
    commit) echo "switching the packages" ;; platform) echo "checking the platform" ;; mpv) echo "video player settings" ;;
    vulkan) echo "the Vulkan driver" ;; kernel) echo "the kernel" ;; update) echo "Omarchy's own update" ;; report) echo "the report" ;;
    *) echo "$1" ;;
  esac
}
res_now() { [[ $(jget commit_started) == 1 ]] && echo 0 || echo 1; }

step 5 "Move to Omarchy 4.5"
# What the guest says is data: one JSON object, read with plutil, cut short.
jv() { plutil -extract "$1" raw -o - -- "$2" 2>/dev/null | printable | head -1 | cut -c1-300 || true; }
PF=$LOG/move-preflight.json ST=$LOG/move-status.json
moved_already=0
if [[ $(jget commit_started) != 1 ]]; then
  prc=0; vssh "$G preflight --json" < /dev/null > "$PF" 2>> "$LOG/move-apply.log" || prc=$?
  code=$(jv code "$PF"); why=$(jv reason "$PF")
  if [[ $code == already-moved ]]; then
    moved_already=1
    log "Omarchy in $NAME is 4.5 already"
  elif (( prc == 4 )); then
    [[ -n $why ]] || why="Omarchy's package servers did not answer."
    fail 5 "$why Check the Mac's network, then Resume." 1 "${code:-repos-unreachable}"
  elif (( prc == 3 )); then
    [[ -n $why ]] || why="The VM cannot be moved ($code)."
    fail 5 "$why Undo brings the disk from before back." 0 "$code"
  elif (( prc != 0 )); then
    fail 5 "The VM's check before the move failed (exit $prc, log: $LOG/move-preflight.json)." 1 preflight
  else
    log "$(jv omarchy "$PF") ($(jv lane "$PF") $(jv channel "$PF")) to $(jv target.omarchy "$PF") (stable)"
  fi
fi
if (( ! moved_already )); then
  # start checks again (resume-aware) and answers like preflight when it will not.
  src=0; vssh "$G start" < /dev/null > "$ST" 2>> "$LOG/move-apply.log" || src=$?
  if (( src == 3 )); then
    fail 5 "$(jv reason "$ST" | grep . || echo "The VM refused the move.") Undo brings the disk from before back." 0 "$(jv code "$ST")"
  elif (( src == 4 )); then
    fail 5 "$(jv reason "$ST" | grep . || echo "Omarchy's package servers did not answer.") Check the Mac's network, then Resume." 1 "$(jv code "$ST")"
  elif (( src != 0 )); then
    fail 5 "The move did not start in the VM (exit $src)." 1 start
  fi
  last="" since=$(date +%s) lost=0 asked_stop=0
  while :; do
    sleep "${OMACVM_MOVE_POLL:-8}"
    kill -0 "$PARENT" 2>/dev/null || touch "$STOP"
    if ! qemu_running; then
      fail 5 "$(disk_why || echo "The VM stopped during the move (log: $LOG/move-console.log).")" "$(res_now)" vm-stopped
    fi
    if ! vssh "$G status --json" < /dev/null > "$ST.new" 2>/dev/null; then
      lost=$((lost + 1))
      (( lost < 40 )) || fail 5 "The VM stopped answering during the move." "$(res_now)" no-answer
      continue
    fi
    lost=0; mv -f "$ST.new" "$ST"
    gs=$(jv state "$ST"); ph=$(jv phase "$ST"); pi=$(jv phase_index "$ST")
    [[ $(jv commit_started "$ST") == true ]] && jset commit_started 1
    [[ $(jv resumable "$ST") == false ]] && jset resumable 0 || jset resumable 1
    if [[ $ph != "$last" && -n $ph ]]; then
      log "$(phase_text "$ph") (part ${pi:-?} of 13)"
      last=$ph since=$(date +%s)
    fi
    case $gs in
      done) break ;;
      failed|refused)
        res=1; [[ $(jv resumable "$ST") == false ]] && res=0
        fail 5 "$(jv reason "$ST" | grep . || echo "The move failed in the VM.") (log: $LOG/move-4.5.log)" "$res" "$(jv code "$ST")" ;;
      stopped)
        stopped ;;
      interrupted)   # the guest's unit ended without a word (killed): as its journal says
        res=1; [[ $(jv resumable "$ST") == false ]] && res=0
        fail 5 "The move stopped in the VM without finishing (log: $LOG/move-4.5.log)." "$res" interrupted ;;
      running|none) ;;   # none: the unit has not written its first state yet
      *) fail 5 "The VM says the move is '$gs'." 1 state ;;
    esac
    if stop_asked && (( ! asked_stop )); then
      # Stops at the next phase boundary, never inside the package switch.
      vssh "$G stop" < /dev/null >/dev/null 2>&1 || true
      asked_stop=1
      log "stopping after this part"
    fi
    # Per part: downloads and the switch may take long, the rest not.
    lim=1800; [[ $ph == download || $ph == commit || $ph == update ]] && lim=5400
    if (( $(date +%s) - since > ${OMACVM_MOVE_PART_SECONDS:-$lim} )) && (( ! asked_stop )); then
      vssh "$G stop" < /dev/null >/dev/null 2>&1 || true
      asked_stop=1
      jset reason "Part '$ph' took too long."
      touch "$STOP"
    fi
  done
fi
# The guest's result for the window's details.
vssh "$G status --json" < /dev/null > "$ST" 2>/dev/null || true
jset commit_started 1
stop_asked && stopped

step 6 "Update OmacVM again"
run_logged "$LOG/move-apply.log" "$HERE/apply-vm.sh" "$VM_DIR" ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"} ||
  fail 6 "$(disk_why || echo "OmacVM did not update after the move (log: $LOG/move-apply.log). Resume tries again.")" 1 apply-after

step 7 "Restart and check"
vssh "systemctl reboot" < /dev/null >/dev/null 2>&1 || true
for ((i = 0; i < 60; i++)); do vssh true < /dev/null >/dev/null 2>&1 || break; sleep 2; done
wait_ssh 300 || fail 7 "$(disk_why || echo "$NAME did not come back after the restart (log: $LOG/move-console.log). Undo brings the disk from before back.")" 1 restart
gst=$(vssh "$G status --json" < /dev/null 2>/dev/null > "$ST" && jv state "$ST") || gst=""
[[ $gst == done ]] || fail 7 "After the restart the VM says the move is '${gst:-unknown}'." 1 check
rec=$(vssh "$G record" < /dev/null 2>/dev/null | printable | head -1 | cut -c1-80) || rec=""
[[ $rec =~ ^4\.([5-9]|[1-9][0-9])[.0-9a-z]*\ [a-z0-9-]+ ]] || fail 7 "After the restart the VM says Omarchy is '${rec:-unknown}', not 4.5." 1 check
echo "$rec" > "$VM_DIR/omarchy"
failed_units=$(vssh "systemctl --failed --no-legend --plain | wc -l" < /dev/null 2>/dev/null | tr -dc 0-9) || failed_units=""
[[ -z $failed_units || $failed_units == 0 ]] || log "note: $failed_units system unit(s) failed after the restart (systemctl --failed in the VM)"
log "Omarchy $rec"

step 8 "Shut down"
guest_log
stop_vm
jset state done step 8 finished "$(now_iso)" resumable 1
OUTCOME=done
echo "MOVED $NAME"
