#!/bin/bash
# The move to Omarchy 4.5, end to end on a real Mac (3.4.0's release gate,
# src/release/release.sh step moves). One ROW at a time on an APFS clone of a
# 4.0 test VM (BASE, powered off): the clone is moved with the app's own
# scripts (move-vm.sh: backup, Update VM, the guest's omarchy-move.sh,
# restart), faults are put in at the step they name, and Resume or Undo must
# bring the VM back exactly (Undo: the disk's SHA-256 equals the one before
# the move). The clone is deleted after the row (KEEP=1 keeps it).
#
#   move-45.sh --app APP --base VM_DIR --row ROW --out DIR
#   move-45.sh --rows             the rows, one per line: NAME  what it proves
#   move-45.sh --paths            the files a result is tied to (release gate)
#   move-45.sh --summary DIR      DIR/rows/*.json -> DIR/result.json (the gate reads it)
#   move-45.sh --onscreen         exit 0 when the rows with the app's window may run now
#
# APP: a test identity build (org.omacvm.app.test) of the commit under test;
# its Contents/Resources/scripts run the move as the app does. BASE: a test VM
# folder (never one of the installed app's VMs folders; src/tests/e2e/test-vms.sh).
# The caller holds the Mac's VM lock and its memory gate (one VM at a time).
# Nothing visible: QEMU runs headless, no input. Only the row app-guards opens
# the test app's window (no input either; only when nobody uses the Mac: HID
# idle > 300 s and the screen unlocked, else that row is BLOCKED); it also
# needs OMACVM_SIGN_ID (the Developer ID, to sign the update it offers) and
# holds ~/.omacvm-test-identity.lock while the app runs.
# Each run of a row writes DIR/rows/ROW-<base>-<mac>-<time>.json: {row, base,
# mac, ended, pass, checks: [[name, ok, detail]], seconds}; logs DIR/logs/ the
# same name. A row stopped before its end (a signal, an error) fails ("row ran
# to its end"). Rows from the M1 go into the same DIR/rows (copy them over)
# before --summary.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)

ROWS="clean        a clean move: guest checks, a restart, then Omarchy's own second update keeps snapper, iwd and OmacVM
undo         Undo after a clean move: the disk and records exactly as before (SHA-256), the VM boots Omarchy 4.0
again        a move, Undo, and the move again: done both times
delete       Delete the old backup after a move: the folder goes, the space shown comes back
net-cut      the internet goes during the download (default route out in the VM): the move stops resumable, Resume finishes it
link-cut     the VM's network link goes for 90 s during the download (SSH too): the move goes on or resumes, then done
kill-early   QEMU killed (-9) before the package switch: interrupted, Resume finishes it
kill-commit  QEMU killed (-9) inside the package switch: Undo only, and Undo restores the disk exactly
app-quit     the app quits mid-move (SIGTERM to move-vm.sh): it stops at a step boundary, Resume finishes it
power-loss   move-vm.sh and QEMU killed (-9) together in the package switch (the Mac loses power): interrupted, Undo exact
power-backup move-vm.sh killed (-9) while it makes the backup: interrupted, Undo (or Resume) leaves the VM as before
app-crash    the app crashes mid-download (move-vm.sh killed -9, its headless QEMU runs on): Resume and Undo still work
disk-pending a disk change not finished (a shrink's journal, a grow): refused before anything changes, plan says why
busy         while the move runs: Update VM (omacvm apply / update), a second move, Undo and Delete are refused; the move goes on
app-guards   the app's window (on screen, no input): opened after a crash nothing starts; while the move runs an app update waits and Disk is locked; the update goes in after
guest-full   the VM's own disk nearly full: refused before the switch, Undo restores the disk exactly
mac-full     the Mac's drive nearly full (the VM on a small APFS disk image): refused before anything changes, plan says why
non-apfs     the VM on a Mac OS Extended (HFS+) disk image: refused before anything changes, plan says why"

# The files a result is tied to: a result for commit C counts for release M
# only while these are the same in C and M (src/release/release.sh step moves).
PATHS="app/scripts/move-vm.sh app/scripts/update-vm.sh app/scripts/apply-vm.sh src/guest/omarchy-move.sh
src/guest/keep-packages.txt src/guest/install.sh src/guest/system-update src/guest/pkg-add src/tests/e2e/move-45.sh"

usage() { sed -n '2,35s/^# \{0,1\}//p' "$0"; exit 2; }
# On screen (MACS-1030d): nobody at the Mac for 5 minutes and the screen unlocked.
hid_idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'; }
screen_locked() { [[ $(ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers.0.CGSSessionScreenIsLocked raw - 2>/dev/null) == true ]]; }
onscreen_ok() { (( $(hid_idle) > 300 )) && ! screen_locked; }
case ${1:-} in
  --rows) printf '%s\n' "$ROWS"; exit 0 ;;
  --paths) printf '%s\n' $PATHS; exit 0 ;;
  --summary) exec python3 -I "$HERE/move-45-result.py" summary "${2:?usage}" "$R" ;;
  --onscreen) onscreen_ok; exit ;;
esac

APP="" BASE="" ROW="" OUT=""
while (( $# )); do
  case $1 in
    --app) APP=$2; shift 2 ;;
    --base) BASE=${2%/}; shift 2 ;;
    --row) ROW=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $APP && -n $BASE && -n $ROW && -n $OUT ]] || usage
grep -q "^$ROW " <<<"$ROWS" || { echo "move-45.sh: unknown row $ROW (--rows)" >&2; exit 2; }
S=$APP/Contents/Resources/scripts
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null) == org.omacvm.app.test ]] ||
  { echo "move-45.sh: $APP is not the test identity (org.omacvm.app.test)" >&2; exit 2; }
[[ -x $S/move-vm.sh || -f $S/move-vm.sh ]] || { echo "move-45.sh: $APP has no scripts/move-vm.sh (not a 3.4.0 build)" >&2; exit 2; }
[[ -f $BASE/disk.img && -f $BASE/vm.env && -e $BASE/ready ]] || { echo "move-45.sh: $BASE is not a finished VM" >&2; exit 2; }
source "$R/src/lib/app.sh"
if app_prod_dir "$(dirname "$BASE")"; then
  echo "move-45.sh: $BASE is in a VMs folder of the installed OmacVM (the person's): never for tests" >&2; exit 2
fi
[[ $BASE == "$HOME/OmacVM/"* ]] && { echo "move-45.sh: $BASE is under ~/OmacVM: never for tests" >&2; exit 2; }
export OMACVM_TEST_IDENTITY=1 OMACVM_CREATE_NO_MAC=1 OMACVM_MOVE_NO_MAC=1   # never the Mac's helpers
MOVE45_COMMIT=$(/usr/libexec/PlistBuddy -c "Print :OmacVMCommit" "$APP/Contents/Info.plist" 2>/dev/null); export MOVE45_COMMIT
mkdir -p "$OUT/rows" "$OUT/logs"
MOVE45_MAC=${MOVE45_MAC:-$(hostname -s)}; export MOVE45_MAC
BN=$(basename "$BASE"); TAG="$ROW-${BN##* }-$MOVE45_MAC-$(date +%Y%m%d-%H%M%S)"
LOGF=$OUT/logs/$TAG.log
exec > >(tee -a "$LOGF") 2>&1
T0=$(date +%s)
CHECKS=() ROW_DONE=0 STOPPED=""
log() { echo "== $(date +%H:%M:%S) $*"; }
check() {   # NAME OK(0|1) DETAIL
  local ok=$2; CHECKS+=("$1"$'\t'"$ok"$'\t'"${3:-}")
  printf '%-4s %s: %s\n' "$( ((ok)) && echo ok || echo FAIL)" "$1" "${3:-}"
}
finish() {
  local f=$OUT/rows/$TAG.json
  # A row cut short (a signal, an error before its end) never passes, also with no check failed yet.
  (( ROW_DONE )) || check "row ran to its end" 0 "stopped early (${STOPPED:-exit $1}) after: $(grep -E '^== |^(ok|FAIL) ' "$LOGF" | tail -1 | cut -c1-200)"
  printf '%s\n' "${CHECKS[@]+"${CHECKS[@]}"}" | python3 -I "$HERE/move-45-result.py" row "$f" "$ROW" "$BN" $(( $(date +%s) - T0 ))
}

# ---------- the clone ----------
# Next to BASE (same volume: cp -c), named for the row; rows that need another
# volume make their own (mac-full, non-apfs).
VD="$(dirname "$BASE")/$BN mv-$ROW"
clone_to() {   # DIR [stand-in]: BASE's folder as a fresh VM at DIR (cp -c); stand-in: the disk's first 2 GiB only
  local d=$1 port
  rm -rf "$d"; mkdir -p "$d"
  if [[ ${2:-} == stand-in ]]; then dd if="$BASE/disk.img" of="$d/disk.img" bs=4m count=512 status=none || return 1
  else cp -c "$BASE/disk.img" "$d/disk.img" || return 1; fi
  local f; for f in efi-vars.fd vm.env features graphics omacvm-version guest-pointer ssh-key ssh-key.pub ready mac-setup fast-network; do
    [[ -e $BASE/$f ]] && cp -p "$BASE/$f" "$d/$f"
  done
  rm -rf "$d/logs" "$d/move-4.5" "$d/before-omarchy-4.5"
  port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  sed -i '' -e "s/^SSH_PORT=.*/SSH_PORT=$port/" -e "s/^NAME=.*/NAME='$(basename "$d")'/" "$d/vm.env"
}
cleanup() {
  app_clean 2>/dev/null
  # The guest's own logs, then the VM folder's (the clone goes after the row).
  if [[ -n $(qemu_pid) ]]; then
    g "tail -c 200000 /var/log/omacvm-system-update.log" > "$OUT/logs/$TAG.guest-system-update.log" 2>/dev/null
    g "cat /var/log/omacvm-move-45.log" > "$OUT/logs/$TAG.guest-move.log" 2>/dev/null
  fi
  vm_off || true
  [[ -d ${VD:-}/logs ]] && { rm -rf "$OUT/logs/$TAG.vm-logs"; cp -R "$VD/logs" "$OUT/logs/$TAG.vm-logs" 2>/dev/null; }
  [[ -n ${MNT:-} ]] && { hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -force -quiet "$MNT" 2>/dev/null; }
  if [[ ${KEEP:-0} != 1 && -n ${VD:-} && $VD == *" mv-$ROW" && -f $VD/vm.env ]]; then rm -rf "$VD"; fi
  [[ -n ${IMG:-} ]] && rm -f "$IMG"
}
trap 'rc=$?; cleanup; finish $rc' EXIT
trap 'STOPPED="SIGTERM"; exit 143' TERM
trap 'STOPPED="SIGINT"; exit 130' INT
trap 'STOPPED="SIGHUP"; exit 129' HUP

# ---------- the VM, as the app's scripts run it ----------
vmc() { ( set +u; source "$S/vm-common.sh" >/dev/null 2>&1; vm_load "$VD" >/dev/null; "$@" ); }
pidfile() { vmc eval 'echo "$PIDFILE"'; }
qmp_sock() { vmc eval 'echo "$QMP"'; }
qemu_pid() { LC_ALL=C pgrep -f "file=$VD/disk.img," | head -1; }
vm_on() {   # headless boot as update-vm.sh does it, then SSH
  vmc eval 'qemu_headless check "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0; wait_ssh 300'
}
vm_off() {
  local p; p=$(qemu_pid); [[ -n $p ]] || return 0
  g systemctl poweroff >/dev/null 2>&1 || true
  local i; for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || return 0; sleep 1; done
  kill "$p" 2>/dev/null; sleep 3; kill -9 "$p" 2>/dev/null; return 0
}
g() { vmc vssh "$@" < /dev/null; }
gmove() { g /usr/local/share/omacvm/guest/omarchy-move.sh "$@"; }
gstat() {   # KEY from the guest's status --json ("" when the VM does not answer)
  gmove status --json 2>/dev/null | python3 -I -c 'import json,sys
try: o = json.load(sys.stdin)
except Exception: sys.exit()
v = o.get(sys.argv[1], "")
print(json.dumps(v) if isinstance(v, (dict, list, bool)) else v)' "$1"
}
J() { sed -n "s/^$1=//p" "$VD/move-4.5" 2>/dev/null | tail -1; }   # the Mac-side journal
sha() {   # a disk: its content digest (holes as zeros, quick on 64 GB); small files: SHA-256
  if [[ $1 == *.img ]]; then python3 -I "$HERE/move-45-result.py" digest "$1"; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
records() { (cd "$VD" && for f in vm.env features graphics omacvm-version guest-pointer; do [[ -f $f ]] && printf '%s %s\n' "$f" "$(sha "$f")"; done) | sed "s/^vm.env .*/vm.env $(grep -v '^SSH_PORT=' "$VD/vm.env" | shasum -a 256 | cut -d' ' -f1)/"; }

# move-vm.sh as the app runs it (no answers on fd 3: the clones know their
# folder's SSH key), progress into the row's log.
MV_PID=""
mvm() { "$S/move-vm.sh" "$VD" "$@" 3< /dev/null >> "$OUT/logs/$TAG.move.log" 2>&1; }
mvm_bg() { mvm "$@" & MV_PID=$!; }
mvm_wait() { wait "$MV_PID"; local rc=$?; MV_PID=""; return $rc; }
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
power_off_all() {   # everything of this move at once, no traps (the Mac loses power): move-vm.sh, its children, QEMU
  local all; all="$MV_PID $(descendants "$MV_PID") $(qemu_pid)"
  kill -STOP $all 2>/dev/null; kill -9 $all 2>/dev/null
  wait "$MV_PID" 2>/dev/null; MV_PID=""
  # The power comes back: nothing of it runs any more (a killed process can take a moment to go).
  local i; for ((i = 0; i < 50; i++)); do [[ -z $(qemu_pid) ]] && ! kill -0 $all 2>/dev/null && break; sleep 0.2; done
}
mv_script_pid() { pgrep -P "$MV_PID" -f move-vm.sh | head -1; }   # move-vm.sh itself (MV_PID is its subshell)
wait_until() {   # SECONDS CMD...: poll CMD every 3 s
  local end=$(( $(date +%s) + $1 )); shift
  while (( $(date +%s) < end )); do "$@" && return 0; sleep 3; done; return 1
}
in_phase() { [[ $(gstat phase) == "$1" ]]; }
committing() { [[ $(gstat commit_started) == true ]]; }
pre_hash() { [[ -n ${PRE_FAILS+x} ]] || pre_fails; PRE_DISK=$(sha "$VD/disk.img"); PRE_EFI=$(sha "$VD/efi-vars.fd"); PRE_REC=$(records); log "before: disk $PRE_DISK"; }
same_as_before() {   # after Undo: disk, NVRAM and records exactly as before
  local d e r
  d=$(sha "$VD/disk.img"); e=$(sha "$VD/efi-vars.fd"); r=$(records)
  check "undo: disk.img content as before (digest)" $([[ $d == "$PRE_DISK" ]] && echo 1 || echo 0) "$d"
  check "undo: efi-vars.fd as before" $([[ $e == "$PRE_EFI" ]] && echo 1 || echo 0) "$e"
  check "undo: records (vm.env, features, graphics, omacvm-version) as before" $([[ $r == "$PRE_REC" ]] && echo 1 || echo 0) "$(diff <(echo "$PRE_REC") <(echo "$r") | tr '\n' ' ')"
  check "undo: no backup folder left" $([[ ! -e $VD/before-omarchy-4.5 ]] && echo 1 || echo 0) ""
}
boots_40() {
  vm_on || { check "after undo: boots" 0 "no SSH"; return; }
  local v; v=$(g "pacman -Q omarchy" | awk '{ print $2 }')
  check "after undo: boots Omarchy 4.0" $([[ $v == 4.0* ]] && echo 1 || echo 0) "omarchy $v"
  vm_off
}
journal_state() { check "journal: state $1" $([[ $(J state) == "$1" ]] && echo 1 || echo 0) "state=$(J state) step=$(J step) resumable=$(J resumable) reason=$(J reason)"; }

# After a fault, nothing goes on by itself: no QEMU, no move-vm.sh, the journal as it was, until
# a person presses Resume or Undo (SECONDS: how long to watch, default 30).
nothing_starts() {
  local j0 j1 i q=""; j0=$(shasum -a 256 "$VD/move-4.5" 2>/dev/null | cut -c1-16)
  for ((i = 0; i < ${1:-30}; i += 3)); do
    q=$(qemu_pid)$(LC_ALL=C pgrep -f "move-vm.sh $VD " | head -1)
    [[ -n $q ]] && break; sleep 3
  done
  j1=$(shasum -a 256 "$VD/move-4.5" 2>/dev/null | cut -c1-16)
  check "after the fault nothing starts by itself (no QEMU or move-vm.sh, journal unchanged ${1:-30} s)" \
    $([[ -z $q && $j0 == "$j1" ]] && echo 1 || echo 0) "pids '$q', journal $j0 -> $j1, state=$(J state)"
}

# ---------- the checks after a move (VM on) ----------
guest_fails() { g "u=\$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env); bash /usr/local/share/omacvm/guest/check.sh --user \"\$u\" --tsv 2>/dev/null | awk -F'\t' '\$1 == \"fail\" { print \$2 }'" | sort -u; }
pre_fails() {   # the guest check's FAIL lines on 4.0, headless: once per base (kept in OUT), before a move
  local c="$OUT/base-fails-${BN// /_}.txt"
  if [[ ! -f $c ]]; then
    vm_on || { PRE_FAILS=""; return; }
    guest_fails > "$c.new" && mv -f "$c.new" "$c"; vm_off
  fi
  PRE_FAILS=$(cat "$c" 2>/dev/null)
  log "4.0 headless guest check FAILs: $(echo $PRE_FAILS | tr '\n' ';' | head -c 200)"
}
moved_ok() {   # WHEN
  local w=$1 v pc pf fail
  v=$(g "pacman -Q omarchy" | awk '{ print $2 }')
  check "$w: omarchy 4.5 or later" $([[ $v =~ ^4\.([5-9]|[1-9][0-9]) || $v =~ ^[5-9]\. ]] && echo 1 || echo 0) "omarchy $v"
  pf=$(g 'p=$(command -v omarchy-hw-platform || echo /usr/share/omarchy/bin/omarchy-hw-platform); "$p"' 2>/dev/null)
  check "$w: platform aarch64" $([[ $pf == aarch64 ]] && echo 1 || echo 0) "$pf"
  pc=$(g "grep -nE 'asahi|aarch64-apple|omarchy-aarch64|TrustAll' /etc/pacman.conf /etc/pacman.d/mirrorlist" | head -3)
  check "$w: no omarchy-mac or asahi repos" $([[ -z $pc ]] && echo 1 || echo 0) "$pc"
  pc=$(g "grep -c 'pkgs.omarchy.org/stable/' /etc/pacman.conf; grep -c 'arm-stable-mirror.omarchy.org' /etc/pacman.d/mirrorlist")
  check "$w: official stable repos" $([[ $(echo $pc) == "1 1" ]] && echo 1 || echo 0) "$(echo $pc)"
  # A new pacman keyring (its own master key, not the 4.0 one an image's VMs shared), and every key in it
  # from Arch Linux ARM's, Arch's or Omarchy's keyring files: omarchy-mac's key is gone.
  pc=$(g 'pacman -Q omarchy-mac-keyring >/dev/null 2>&1 && echo "omarchy-mac-keyring installed"
    G=/etc/pacman.d/gnupg; m() { gpg --homedir "$1" --no-permission-warning --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: "\$1 == \"fpr\" { print \$10; exit }"; }
    [[ -d $G.omacvm-40 && $(m $G) != "$(m $G.omacvm-40)" ]] || echo "no new master key"
    ok=$( { for k in /usr/share/pacman/keyrings/{archlinuxarm,archlinux,omarchy}.gpg; do [[ -f $k ]] && gpg --batch --with-colons --show-keys "$k" 2>/dev/null; done; } |
      awk -F: "\$1 == \"fpr\" { print \$10 }" | sort -u; echo 40DFB630FF42BCFFB047046CF0134EE680CAC571; m $G)
    gpg --homedir $G --no-permission-warning --batch --with-colons --list-keys 2>/dev/null | awk -F: "\$1 == \"pub\" { p = 1; next } \$1 == \"fpr\" && p { print \$10; p = 0 }" |
      while read -r f; do grep -qx "$f" <<<"$ok" || echo "key $f from elsewhere"; done' 2>&1 | head -5)
  check "$w: a new pacman keyring, only Arch Linux ARM's, Arch's and Omarchy's keys" $([[ -z $pc ]] && echo 1 || echo 0) "$(echo $pc | head -c 300)"
  pc=$(g "for p in \$(grep -v '^#' /usr/local/share/omacvm/guest/keep-packages.txt 2>/dev/null); do pacman -Qq \$p >/dev/null 2>&1 || continue; r=\$(LC_ALL=C pacman -Qi \$p | sed -n 's/^Install Reason *: //p'); [[ \$r == Explicitly* ]] || echo \"\$p:\$r\"; done")
  check "$w: keep list installed explicitly (orphan step cannot take it)" $([[ -z $pc ]] && echo 1 || echo 0) "$(echo $pc | head -c 200)"
  pc=$(g "pacman -Qq snapper iwd 2>&1; snapper list-configs 2>/dev/null | grep -c root; ls /boot/grub/grub-btrfs.cfg 2>&1")
  check "$w: snapper and iwd there, root config, snapshots in GRUB" $([[ $pc != *"not found"* && $pc == *grub-btrfs.cfg* ]] && echo 1 || echo 0) "$(echo $pc)"
  fail=$(g "systemctl --failed --no-legend --plain | awk '{ print \$1 }'")
  check "$w: no failed units" $([[ -z $fail ]] && echo 1 || echo 0) "$(echo $fail)"
  # Headless nobody is logged in, so the desktop's lines fail before the move too: only new FAILs count.
  pc=$(guest_fails | grep -vxF -f <(printf '%s\n' "${PRE_FAILS:-}") | tr '\n' ';')
  check "$w: OmacVM's guest check: no FAIL that was not there on 4.0" $([[ -z $pc ]] && echo 1 || echo 0) "${pc:0:300}"
  pc=$(g "cat /usr/local/share/omacvm/VERSION")
  check "$w: OmacVM in the VM is the app's" $([[ $pc == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" ]] && echo 1 || echo 0) "$pc"
  if grep -q 'vulkan=on' "$VD/features" 2>/dev/null; then
    pc=$(g "pacman -Qq omacvm-vulkan-virtio 2>&1; pacman -Qo /usr/lib/libvulkan_virtio.so 2>&1 | awk '{ print \$(NF-1) }'")
    check "$w: Vulkan VM: omacvm-vulkan-virtio provides the driver" $([[ $pc == omacvm-vulkan-virtio*omacvm-vulkan-virtio* ]] && echo 1 || echo 0) "$(echo $pc)"
  fi
}

# ---------- rows ----------
row_clean() {
  pre_hash
  mvm run; local rc=$?
  check "move-vm.sh run" $((rc == 0)) "exit $rc"
  journal_state done
  check "backup folder there" $([[ -f $VD/before-omarchy-4.5/disk.img ]] && echo 1 || echo 0) ""
  vm_on || { check "boots after the move" 0 "no SSH"; return; }
  check "boots after the move" 1 ""
  moved_ok "after the move"
  local result; result=$(gstat result)
  log "result: $result"
  log "second update: Omarchy's own (orphan step included)"
  g "/usr/local/share/omacvm/guest/system-update" > "$OUT/logs/$TAG.update2.log" 2>&1; rc=$?
  check "second update (omarchy update -y)" $((rc == 0)) "exit $rc, $(tail -1 "$OUT/logs/$TAG.update2.log")"
  g "tail -c 100000 /var/log/omacvm-system-update.log" 2>/dev/null | sed -e $'s/\x1b\\[[0-9;]*[A-Za-z]//g' > "$OUT/logs/$TAG.guest-update2.log"
  g "systemctl reboot" >/dev/null 2>&1; sleep 15
  local ok=0; for _ in $(seq 60); do g true 2>/dev/null && { ok=1; break; }; sleep 5; done
  check "restart after the second update" $ok ""
  ((ok)) && moved_ok "after the second update"
  vm_off
}
row_undo() {
  pre_hash
  mvm run; local rc=$?
  check "move-vm.sh run" $((rc == 0)) "exit $rc"
  mvm undo; rc=$?
  check "move-vm.sh undo" $((rc == 0)) "exit $rc"
  journal_state undone
  same_as_before
  boots_40
}
row_again() {
  pre_hash
  mvm run; check "first move" $(( $? == 0 )) ""
  mvm undo; check "undo" $(( $? == 0 )) ""
  same_as_before
  mvm run; local rc=$?
  check "second move" $((rc == 0)) "exit $rc"
  journal_state done
  vm_on && { moved_ok "after the second move"; vm_off; } || check "boots after the second move" 0 ""
}
row_delete() {
  mvm run; check "move" $(( $? == 0 )) ""
  local size before after freed
  size=$(mv_status_size)
  before=$(df -k "$VD" | awk 'NR == 2 { print $4 }')
  mvm delete-backup; local rc=$?
  sync; sleep 5
  after=$(df -k "$VD" | awk 'NR == 2 { print $4 }')
  freed=$(( (after - before) * 1024 ))
  check "delete-backup" $((rc == 0)) "exit $rc"
  check "backup folder gone" $([[ ! -e $VD/before-omarchy-4.5 ]] && echo 1 || echo 0) ""
  journal_state done-final
  # The size the card shows vs what came back (other writers on the Mac make noise: within 5 % or 200 MB).
  local ok; ok=$(python3 -I -c 'import sys; s, f = int(sys.argv[1] or 0), int(sys.argv[2]); print(int(s > 0 and abs(f - s) <= max(0.05 * s, 200e6)))' "$size" "$freed")
  check "space shown = space freed" "$ok" "shown $size, freed $freed"
}
mv_status_size() {   # the backup's own bytes (what the card shows: blocks no longer shared with the live disk)
  local b=$VD/before-omarchy-4.5 n=0 f x
  for f in "$b"/*; do [[ -f $f ]] || continue; x=$(python3 -I "$HERE/move-45-result.py" privsize "$f") || return 1; n=$((n + x)); done
  echo "$n"
}
fault_then_resume() {   # the move must stop resumable, then Resume finishes it
  mvm_wait; local rc=$?
  check "stopped by the fault" $((rc != 0)) "exit $rc"
  check "journal: resumable" $([[ $(J resumable) == 1 ]] && echo 1 || echo 0) "state=$(J state) step=$(J step) reason=$(J reason)"
  vm_off
  nothing_starts
  mvm run; rc=$?
  check "Resume (run again)" $((rc == 0)) "exit $rc"
  journal_state done
  if (( rc == 0 )); then
    vm_on && { moved_ok "after Resume"; vm_off; } || check "boots after Resume" 0 ""
  else
    # What a person does next: Undo. It must give back the VM from before the move.
    vm_off; mvm undo; rc=$?
    check "Undo after the failed Resume" $((rc == 0)) "exit $rc"
    same_as_before
    boots_40
  fi
}
row_net_cut() {
  pre_hash
  mvm_bg run
  wait_until 2400 in_phase download || { check "reached download" 0 "phase $(gstat phase)"; mvm_wait; return; }
  g "ip route save > /run/omacvm-route; ip route del default; ip -6 route del default 2>/dev/null; true"
  log "internet cut in the VM"
  wait_until 900 eval '[[ $(gstat state) != running ]] || ! kill -0 $MV_PID 2>/dev/null'
  g "ip route restore < /run/omacvm-route 2>/dev/null; true"
  fault_then_resume
}
row_link_cut() {
  pre_hash
  mvm_bg run
  wait_until 2400 in_phase download || { check "reached download" 0 "phase $(gstat phase)"; mvm_wait; return; }
  local q; q=$(qmp_sock)
  printf '{"execute":"qmp_capabilities"}\n{"execute":"set_link","arguments":{"name":"net0","up":false}}\n' | nc -U -w 2 "$q" >/dev/null
  log "link down 90 s"; sleep 90
  printf '{"execute":"qmp_capabilities"}\n{"execute":"set_link","arguments":{"name":"net0","up":true}}\n' | nc -U -w 2 "$q" >/dev/null
  mvm_wait; local rc=$?
  if (( rc != 0 )); then
    check "link back: resumable when it stopped" $([[ $(J resumable) == 1 ]] && echo 1 || echo 0) "exit $rc, $(J reason)"
    vm_off; mvm run; rc=$?
  fi
  check "done after the link came back" $((rc == 0)) "exit $rc"
  journal_state done
}
row_kill_early() {
  pre_hash
  mvm_bg run
  wait_until 2400 eval '[[ $(gstat phase) == protect || $(gstat phase) == keyring || $(gstat phase) == repos || $(gstat phase) == download ]]' ||
    { check "reached a phase before the switch" 0 "phase $(gstat phase)"; mvm_wait; return; }
  local p; p=$(qemu_pid); log "kill -9 QEMU $p in $(gstat phase)"; kill -9 "$p"
  fault_then_resume
}
row_kill_commit() {
  pre_hash
  mvm_bg run
  wait_until 3600 committing || { check "reached the package switch" 0 "phase $(gstat phase)"; mvm_wait; return; }
  sleep 10
  local p ph; ph=$(gstat phase); p=$(qemu_pid); kill -9 "$p"; log "kill -9 QEMU $p in phase '$ph'"
  check "killed inside the package switch" $([[ $ph == commit ]] && echo 1 || echo 0) "phase $ph"
  mvm_wait; local rc=$?
  check "stopped" $((rc != 0)) "exit $rc"
  check "journal: Undo only (not resumable)" $([[ $(J resumable) == 0 ]] && echo 1 || echo 0) "state=$(J state) step=$(J step) resumable=$(J resumable)"
  nothing_starts
  mvm run; rc=$?
  check "Resume refused" $((rc != 0)) "exit $rc"
  mvm undo; rc=$?
  check "Undo" $((rc == 0)) "exit $rc"
  same_as_before
  boots_40
}
row_app_quit() {
  pre_hash
  mvm_bg run
  wait_until 2400 in_phase download || { check "reached download" 0 "phase $(gstat phase)"; mvm_wait; return; }
  local sp; sp=$(mv_script_pid)
  log "SIGTERM move-vm.sh $sp (the app quits)"; kill -TERM "$sp"
  local t=$(date +%s)
  fault_then_resume_after_quit "$t"
}
fault_then_resume_after_quit() {
  mvm_wait; local rc=$?
  check "stopped within 10 min (a step boundary)" $(( $(date +%s) - $1 < 600 )) "$(( $(date +%s) - $1 )) s, exit $rc"
  check "QEMU off after the stop" $([[ -z $(qemu_pid) ]] && echo 1 || echo 0) ""
  check "journal: interrupted or failed, resumable" $([[ $(J resumable) == 1 && $(J state) =~ ^(interrupted|failed)$ ]] && echo 1 || echo 0) "state=$(J state) resumable=$(J resumable)"
  nothing_starts
  mvm run; rc=$?
  check "Resume" $((rc == 0)) "exit $rc"
  journal_state done
  if (( rc != 0 )); then
    vm_off; mvm undo; rc=$?
    check "Undo after the failed Resume" $((rc == 0)) "exit $rc"
    same_as_before
  fi
}
row_power_loss() {
  pre_hash
  mvm_bg run
  wait_until 3600 committing || { check "reached the package switch" 0 ""; mvm_wait; return; }
  sleep 10
  local ph; ph=$(gstat phase)
  power_off_all
  log "power loss in phase '$ph': move-vm.sh, its children and QEMU killed (-9) at once"
  check "power lost inside the package switch" $([[ $ph == commit ]] && echo 1 || echo 0) "phase $ph"
  # Nobody wrote the journal: "running" with a dead pid, which the app shows as interrupted.
  local jp; jp=$(J pid)
  check "journal: running, its pid gone (the app shows interrupted)" $([[ $(J state) == running ]] && ! kill -0 "${jp:-0}" 2>/dev/null && echo 1 || echo 0) "state=$(J state) pid=$jp commit_started=$(J commit_started)"
  nothing_starts
  mvm run; local rr=$?
  check "Resume refused inside the switch" $((rr != 0)) "exit $rr"
  mvm undo; local rc=$?
  check "Undo" $((rc == 0)) "exit $rc"
  same_as_before
  boots_40
}
row_power_backup() {
  pre_hash
  mvm_bg run
  # As soon as the backup folder shows (the clone takes moments: the kill lands in it or right after).
  local i; for ((i = 0; i < 6000; i++)); do [[ -e $VD/before-omarchy-4.5 ]] && break; sleep 0.05; done
  power_off_all
  log "killed at step $(J step), backup_at '$(J backup_at)'"
  check "journal: running, its pid gone (the app shows interrupted)" $([[ $(J state) == running ]] && echo 1 || echo 0) "state=$(J state) step=$(J step)"
  nothing_starts
  mvm undo; local rc=$?
  check "Undo" $((rc == 0)) "exit $rc"
  same_as_before
}
row_app_crash() {
  pre_hash
  mvm_bg run
  wait_until 2400 in_phase download || { check "reached download" 0 "phase $(gstat phase)"; mvm_wait; return; }
  local q; q=$(qemu_pid)
  # The app and its script die; QEMU (a separate process) and the guest's move go on.
  local all; all="$MV_PID $(descendants "$MV_PID" | grep -vx "$q")"
  kill -9 $all 2>/dev/null; wait "$MV_PID" 2>/dev/null; MV_PID=""
  log "app crash: move-vm.sh tree killed, QEMU $q left running ($(kill -0 "$q" 2>/dev/null && echo alive || echo gone))"
  check "journal: running, its pid gone (the app shows interrupted)" $([[ $(J state) == running ]] && echo 1 || echo 0) "state=$(J state)"
  # The app opens again: Resume. It must find its own move VM and carry on (or stop it and resume), never ask the person to shut down a VM they cannot see.
  mvm run; local rc=$?
  check "Resume after the crash" $((rc == 0)) "exit $rc: $(J reason)"
  journal_state done
  [[ -z $(qemu_pid) ]] || vm_off
  if (( rc != 0 )); then
    mvm undo; rc=$?
    check "Undo after the crash" $((rc == 0)) "exit $rc: $(tail -1 "$OUT/logs/$TAG.move.log")"
    same_as_before
  fi
}
row_guest_full() {
  pre_hash
  vm_on || { check "boots" 0 ""; return; }
  # Leave about 3 GB free on / (the move wants 8).
  g "f=\$(df -B1 --output=avail / | tail -1); fallocate -l \$(( f - 3 * 1024 * 1024 * 1024 )) /var/omacvm-fill && sync; df -h / | tail -1"
  vm_off
  pre_hash   # the fill is the VM's state before the move
  mvm run; local rc=$?
  check "refused" $((rc != 0)) "exit $rc"
  check "journal: reason low-space" $([[ $(J reason)$(J code) == *low-space* || $(J reason) == *space* ]] && echo 1 || echo 0) "state=$(J state) reason=$(J reason)"
  if [[ -e $VD/before-omarchy-4.5 ]]; then mvm undo; check "Undo" $(( $? == 0 )) ""; fi
  same_as_before
}
mac_side_refusal() {   # FS GB WHY: the VM on a GB disk image of FS; the move refuses at once, nothing changes
  # The disk is a stand-in, the base disk's first 2 GiB: Mac OS Extended has no sparse files (a copy
  # would write all 64 GB), and the Mac's checks refuse before anything reads or clones it. APFS, 6 GB:
  # the move needs 2 GiB + 14 GB and finds about 4. HFS+, 20 GB: space enough, so only "not APFS" can
  # refuse it; OMACVM_TEST_MOVE_STOP=backup stops a run that wrongly goes on before any VM starts.
  IMG=$OUT/$TAG.sparseimage
  rm -f "$IMG"
  hdiutil create -quiet -type SPARSE -size "$2g" -fs "$1" -volname "mv-$ROW" "$OUT/$TAG" || { check "disk image" 0 ""; return; }
  MNT=$(hdiutil attach -nobrowse -noautoopen "$IMG" 2>/dev/null | awk -F'\t' 'END { print $NF }')
  [[ -d $MNT ]] || { check "disk image attached" 0 ""; return; }
  VD="$MNT/$BN mv-$ROW"
  clone_to "$VD" stand-in || { check "VM copied to the disk image" 0 ""; return; }
  log "free $(df -h "$MNT" | awk 'NR == 2 { print $4 }') on $1"
  PRE_FAILS=""   # a stand-in disk: never started
  pre_hash
  OMACVM_TEST_MOVE_STOP=backup mvm run; local rc=$?
  check "refused" $((rc != 0)) "exit $rc: $(J reason)"
  check "said why ($3)" $([[ $(J reason) == *"$3"* ]] && echo 1 || echo 0) "$(J reason)"
  check "nothing changed: disk.img" $([[ $(sha "$VD/disk.img") == "$PRE_DISK" ]] && echo 1 || echo 0) ""
  check "nothing changed: no backup" $([[ ! -e $VD/before-omarchy-4.5 ]] && echo 1 || echo 0) ""
  check "no QEMU started" $([[ -z $(qemu_pid) ]] && echo 1 || echo 0) ""
  local p; p=$("$S/move-vm.sh" "$VD" plan 2>/dev/null | sed -n 's/^problem=//p')
  check "plan says the same (the card's Blocked state)" $([[ $p == *"$3"* ]] && echo 1 || echo 0) "$p"
}
row_disk_pending() {   # the disk's size change not finished: the move waits for it, before anything changes
  PRE_FAILS=""   # never started: nothing to compare
  pre_hash
  local kind p rc
  for kind in shrink grow; do
    rm -f "$VD/disk-resize" "$VD/disk-jobs"
    case $kind in   # as DiskView.swift writes them (DiskSize.Resize, DiskSize.Job)
      shrink) printf 'step=shrink\nfrom=64\nto=48\n' > "$VD/disk-resize" ;;
      grow) echo grow > "$VD/disk-jobs" ;;
    esac
    p=$("$S/move-vm.sh" "$VD" plan 2>/dev/null | sed -n 's/^problem=//p')
    check "$kind pending: plan says why (the card's Blocked state)" $([[ -n $p ]] && echo 1 || echo 0) "$p"
    mvm run; rc=$?
    check "$kind pending: refused (exit 3)" $((rc == 3)) "exit $rc: $(J reason)"
    check "$kind pending: no QEMU started" $([[ -z $(qemu_pid) ]] && echo 1 || echo 0) ""
    check "$kind pending: no backup, no move under way" $([[ ! -e $VD/before-omarchy-4.5 && $(J state) != running ]] && echo 1 || echo 0) "state=$(J state)"
    check "$kind pending: disk.img as before" $([[ $(sha "$VD/disk.img") == "$PRE_DISK" ]] && echo 1 || echo 0) ""
  done
  rm -f "$VD/disk-resize" "$VD/disk-jobs"
}
row_busy() {   # while the move runs, whatever else could touch the VM is refused, and the move goes on
  pre_hash
  mvm_bg run
  wait_until 2400 in_phase download || { check "reached download" 0 "phase $(gstat phase)"; mvm_wait; return; }
  local cli="$APP/Contents/Resources/omacvm/omacvm" name; name=$(basename "$VD")
  local out rc
  # Update VM's own route (the app's Update VM and the control centre's jobs run apply); Mac side left alone.
  out=$("$cli" apply --vm "$name" --no-mac --yes 2>&1 < /dev/null); rc=$?
  check "omacvm apply refused (exit 3), nothing changed" $((rc == 3)) "exit $rc: $(tail -1 <<<"$out" | cut -c1-200)"
  out=$("$S/move-vm.sh" "$VD" run 2>&1 3< /dev/null); rc=$?
  check "a second move refused (exit 3)" $((rc == 3)) "exit $rc: $(tail -1 <<<"$out" | cut -c1-200)"
  out=$("$S/move-vm.sh" "$VD" undo 2>&1 3< /dev/null); rc=$?
  check "Undo refused while the move runs" $((rc != 0)) "exit $rc: $(tail -1 <<<"$out" | cut -c1-200)"
  out=$("$S/move-vm.sh" "$VD" delete-backup 2>&1 3< /dev/null); rc=$?
  check "Delete the old backup refused while the move runs" $((rc != 0)) "exit $rc: $(tail -1 <<<"$out" | cut -c1-200)"
  check "the backup is still there" $([[ -f $VD/before-omarchy-4.5/disk.img ]] && echo 1 || echo 0) ""
  check "the move still runs (journal, QEMU)" $([[ $(J state) == running && -n $(qemu_pid) ]] && echo 1 || echo 0) "state=$(J state)"
  mvm_wait; rc=$?
  check "the move finishes" $((rc == 0)) "exit $rc: $(J reason)"
  journal_state done
}

# ---------- the app's window (row app-guards) ----------
# The test app opened as a person opens it (open -n -g, its window on this Mac's screen, no input:
# Accessibility reads it), from one fixed copy per Mac that the move runs from too, so its updater
# sees the move (a new folder per run would ask macOS's Local Network question again: STANDARDS 34b).
UA=""; UPID=""; FEED_PID=""; ULOCK=$HOME/.omacvm-test-identity.lock; ULOCK_MINE=0; USAVED=""
app_clean() {
  [[ -n $UPID ]] && { kill "$UPID" 2>/dev/null; sleep 2; kill -9 "$UPID" 2>/dev/null; }
  [[ -n $FEED_PID ]] && kill "$FEED_PID" 2>/dev/null
  [[ -n $USAVED && -f $USAVED ]] && defaults import org.omacvm.app.test "$USAVED"
  (( ULOCK_MINE )) && rm -rf "$ULOCK" && echo "move-45 $(date +%H:%M) done" >> "$ULOCK.wait"
  UPID="" FEED_PID="" USAVED="" ULOCK_MINE=0
}
app_open() {   # [ARGS...]: the copy, with the local feed; UPID = its launcher
  local before; before=$(LC_ALL=C pgrep -f "$UA/Contents/MacOS/OmacVM" | tr '\n' ' ')
  open -n -g --env "OMACVM_APPCAST_URL=http://127.0.0.1:$FEED_PORT/OmacVM-appcast.json" --env "OMACVM_APPCAST_KEY=$(cat "$OUT/feed-$MOVE45_MAC/key.pub")" \
    "$UA" --args --vm "$(basename "$VD")" "$@"
  local i p; UPID=""
  for ((i = 0; i < 30; i++)); do
    for p in $(LC_ALL=C pgrep -f "$UA/Contents/MacOS/OmacVM( |$)"); do [[ $before == *" $p "* || $before == "$p "* ]] || UPID=$p; done
    [[ -n $UPID ]] && return 0; sleep 1
  done
  return 1
}
app_quit() { [[ -n $UPID ]] && { kill "$UPID" 2>/dev/null; local i; for ((i = 0; i < 15; i++)); do kill -0 "$UPID" 2>/dev/null || break; sleep 1; done; kill -9 "$UPID" 2>/dev/null; }; UPID=""; }
disk_locked() {   # WHEN: the Disk row's Change… is there and disabled (AX on the launcher's pid)
  local out rc; out=$("$OUT/ax" "$UPID" has "Change…" 2>&1); rc=$?
  check "$1: Disk › Change… locked in the window" $([[ $rc == 1 && $out == *disabled* ]] && echo 1 || echo 0) "ax rc $rc: $out"
}
upd_log() { local f; f=$(ls -t "$HOME/Library/Application Support/OmacVM/Updates/org.omacvm.app.test"/*/update.log 2>/dev/null | head -1); [[ -n $f ]] && tail -c 4000 "$f"; }
row_app_guards() {
  local why=""
  onscreen_ok || why="someone may be at this Mac (HID idle $(hid_idle) s$(screen_locked && echo ', screen locked'))"
  [[ -z $why && -z ${OMACVM_SIGN_ID:-} ]] && why="OMACVM_SIGN_ID is not set (the Developer ID signs the update on offer)"
  # One launcher per bundle id: a second one hands over to the first (and --update-now would ask that one to update).
  local other; other=$(LC_ALL=C pgrep -f "OmacVM Test\.app/Contents/MacOS/OmacVM( |$)" | head -3 | tr '\n' ' ')
  [[ -z $why && -n $other ]] && why="another test app launcher runs (pids $other)"
  if [[ -z $why ]]; then
    local i; for ((i = 0; i < 40; i++)); do mkdir "$ULOCK" 2>/dev/null && { ULOCK_MINE=1; break; }; sleep 30; done
    (( ULOCK_MINE )) && echo "move-45 app-guards $(date +%H:%M), pid $$" > "$ULOCK/owner" || why="$ULOCK held for 20 min ($(cat "$ULOCK/owner" 2>/dev/null))"
  fi
  [[ -z $why ]] && { swiftc -O -o "$OUT/ax" "$HERE/ax.swift" 2> "$OUT/logs/$TAG.ax-build.log" || why="ax.swift does not build"; }
  if [[ -n $why ]]; then check "BLOCKED: the app's window can be used here now" 0 "$why"; app_clean; return; fi
  USAVED=$OUT/logs/$TAG.app-settings.plist; defaults export org.omacvm.app.test "$USAVED" 2>/dev/null || : > "$USAVED"
  # The copy (the move runs from it), and the same build one version up, offered by a local feed (throwaway key).
  UA=${MOVE45_UPDATE_APP:-$HOME/omacvm-work/move45-app/OmacVM Test.app}
  mkdir -p "$(dirname "$UA")"; rm -rf "$UA"; ditto "$APP" "$UA"
  S=$UA/Contents/Resources/scripts
  local pv cv F="$OUT/feed-$MOVE45_MAC"; pv=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UA/Contents/Info.plist")
  cv=${pv%.*}.$(( ${pv##*.} + 1 ))
  rm -rf "$F"; mkdir -p "$F/c"; ditto "$APP" "$F/c/OmacVM Test.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $cv" -c "Set :CFBundleVersion $cv" "$F/c/OmacVM Test.app/Contents/Info.plist"
  codesign --force --sign "$OMACVM_SIGN_ID" --options runtime --preserve-metadata=entitlements,identifier "$F/c/OmacVM Test.app" 2> "$F/sign.log" ||
    { check "the update on offer signed" 0 "$(tail -1 "$F/sign.log")"; app_clean; return; }
  swiftc -O -o "$F/sign" "$R/src/release/sign.swift" 2>/dev/null && "$F/sign" keygen "$F/key" > "$F/key.pub" ||
    { check "a throwaway feed key" 0 ""; app_clean; return; }
  (cd "$F/c" && ditto -c -k --keepParent "OmacVM Test.app" "$F/OmacVM-$cv.zip")
  FEED_PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  printf '{"schema": 1, "kind": "app-feed", "version": "%s", "url": "http://127.0.0.1:%s/OmacVM-%s.zip", "length": %s, "sha256": "%s", "minimum_macos": "15.0", "devid_teams": ["%s"]}\n' \
    "$cv" "$FEED_PORT" "$cv" "$(stat -f %z "$F/OmacVM-$cv.zip")" "$(shasum -a 256 "$F/OmacVM-$cv.zip" | cut -d' ' -f1)" \
    "$(codesign -dv "$F/c/OmacVM Test.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')" > "$F/OmacVM-appcast.json"
  "$F/sign" sign "$F/key" "$F/OmacVM-appcast.json" > "$F/OmacVM-appcast.json.sig"
  /usr/bin/python3 -m http.server "$FEED_PORT" --bind 127.0.0.1 --directory "$F" > "$F/server.log" 2>&1 & FEED_PID=$!
  pre_hash
  # 1. The Mac crashes early in the move (QEMU killed): interrupted.
  mvm_bg run
  wait_until 2400 eval '[[ $(gstat phase) =~ ^(protect|initramfs|keyring|repos|download)$ ]]' ||
    { check "reached a phase before the switch" 0 "phase $(gstat phase)"; mvm_wait; app_clean; return; }
  kill -9 "$(qemu_pid)"; mvm_wait
  log "app-guards: QEMU killed in $(gstat phase 2>/dev/null)$(J step): state=$(J state)"
  # 2. The app opens again (as after the Mac's restart): nothing starts, the journal stays, Disk is locked.
  local j0; j0=$(shasum -a 256 "$VD/move-4.5" | cut -c1-16)
  app_open || { check "the app opens" 0 ""; app_clean; return; }
  sleep 45
  check "app opened after the crash: no QEMU started" $([[ -z $(qemu_pid) ]] && echo 1 || echo 0) ""
  check "app opened after the crash: the journal as it was" $([[ $(shasum -a 256 "$VD/move-4.5" | cut -c1-16) == "$j0" ]] && echo 1 || echo 0) "state=$(J state)"
  disk_locked "after the crash"
  app_quit
  # 3. Resume (from the copy, as its window would); while it downloads, the app opens with an update on offer.
  mvm_bg run
  wait_until 2400 in_phase download || { check "Resume reached download" 0 "phase $(gstat phase)"; mvm_wait; app_clean; return; }
  app_open --update-now || { check "the app opens with --update-now" 0 ""; app_clean; return; }
  local i; for ((i = 0; i < 40; i++)); do kill -0 "$UPID" 2>/dev/null || break; sleep 3; done   # it quits once it decided
  UPID=""
  local ul; ul=$(upd_log)
  check "update on offer during the move: not installed" $([[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UA/Contents/Info.plist") == "$pv" ]] && echo 1 || echo 0) "$(grep -E 'deferred|install|update-now' <<<"$ul" | tail -2 | tr '\n' ' ' | cut -c1-240)"
  check "update on offer during the move: deferred (update.log)" $([[ $ul == *"deferred"* ]] && echo 1 || echo 0) "$(grep -E 'deferred' <<<"$ul" | tail -1 | cut -c1-200)"
  check "the move goes on (journal running, QEMU)" $([[ $(J state) == running && -n $(qemu_pid) ]] && echo 1 || echo 0) "state=$(J state)"
  app_open || { check "the app opens during the move" 0 ""; app_clean; return; }
  sleep 20; disk_locked "while the move runs"; app_quit
  mvm_wait; local rc=$?
  check "the move finishes" $((rc == 0)) "exit $rc: $(J reason)"
  journal_state done
  # 4. The app opens after the move: the update waiting from step 3 goes in now.
  app_open || { check "the app opens after the move" 0 ""; app_clean; return; }
  for ((i = 0; i < 100; i++)); do [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UA/Contents/Info.plist" 2>/dev/null) == "$cv" ]] && break; sleep 3; done
  check "after the move the waiting update goes in" $([[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UA/Contents/Info.plist" 2>/dev/null) == "$cv" ]] && echo 1 || echo 0) "$(upd_log | grep -E 'install|swap|result' | tail -2 | tr '\n' ' ' | cut -c1-240)"
  sleep 5
  local p; for p in $(LC_ALL=C pgrep -f "$UA/Contents/MacOS/OmacVM( |$)"); do kill "$p" 2>/dev/null; done
  UPID=""
  check "no QEMU after all of it" $([[ -z $(qemu_pid) ]] && echo 1 || echo 0) ""
  app_clean
}
row_mac_full() { mac_side_refusal APFS 6 "Not enough free space"; }
row_non_apfs() { mac_side_refusal HFS+ 20 "APFS"; }

log "row $ROW on $BN (app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :OmacVMCommit' "$APP/Contents/Info.plist" | tr '\n' ' '))"
case $ROW in
  mac-full|non-apfs) ;;
  *) clone_to "$VD" || { check "clone" 0 ""; exit 1; } ;;
esac
"row_${ROW//-/_}"
ROW_DONE=1
