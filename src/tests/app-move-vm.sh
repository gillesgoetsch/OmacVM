#!/bin/bash
# OmacVM.app's "Move to Omarchy 4.5" (app/scripts/move-vm.sh) without a VM:
# a stand-in QEMU, ssh (the guest's omarchy-move.sh as work/v340/contract.md
# has it) and apply in a fixture app, a VM folder with a small disk.img.
# The Mac's checks, the backup (APFS clones and the records), a move to the
# end, Delete the backup, Undo (the disk byte for byte as before), a network
# failure and its Resume, a refusal, a failure inside the package switch
# (Undo only), Stop and Quit and its Resume, a killed run (power cut) and
# its Resume, the move's script killed with its VM left running (an app
# crash: found, shut down, then Resume, Undo or Keep), a VM that is still
# going away (Undo waits) or runs elsewhere (refused, no process lines in
# the reason), Keep This Disk, and src/lib/omarchy-move.sh (apply and update
# leave a VM in the middle of its move alone; the guest's record line).
#   src/tests/app-move-vm.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
VMID() { printf '%s' "$1" | shasum | cut -c1-8; }
cleanup() {
  [[ -f $T/qemu.pid ]] && kill "$(cat "$T/qemu.pid")" 2>/dev/null
  [[ -n ${oq:-} ]] && kill "$oq" 2>/dev/null
  [[ -n ${dying:-} ]] && kill "$dying" 2>/dev/null
  [[ -n ${other:-} ]] && kill "$other" 2>/dev/null
  [[ -n ${BG:-} ]] && kill "$BG" 2>/dev/null
  pkill -f "$T/app/runtime/bin/OmacVM" 2>/dev/null   # only this test's stand-in QEMUs
  rm -rf "$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(VMID "$T/VMs/Old")".*
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# ---------- src/lib/omarchy-move.sh ----------
source "$R/src/lib/omarchy-move.sh"
mkdir -p "$T/lib"
for s in running failed interrupted undoing done kept undone done-final; do
  printf 'format=1\nstate=%s\n' "$s" > "$T/lib/move-4.5"
  case $s in running|failed|interrupted|undoing) want=open ;; *) want=over ;; esac
  expect "move_open: $s is $want" "$want" "$(move_open "$T/lib" && echo open || echo over)"
done
printf 'format=1\nstate=running\n' > "$T/lib/move-4.5"
expect "move_open: the move's own apply (OMACVM_MOVE_RUN=1) goes on" "over" "$(OMACVM_MOVE_RUN=1 move_open "$T/lib" && echo open || echo over)"
expect "move_open: no journal" "over" "$(move_open "$T/none" && echo open || echo over)"
expect "move_record: 4.5" "4.5.0 aarch64 stable" "$(move_record "4.5.0 aarch64 stable")"
expect "move_record: 4.0 with rc" "4.0.3rc4 omarchy-mac rc" "$(move_record $'4.0.3rc4 omarchy-mac rc\nsecond line')"
expect "move_record: none" "none" "$(move_record none)"
expect "move_record: control characters dropped" "4.5.0 aarch64 stable" "$(move_record $'4.5.0\033[31m aarch64 stable')"
expect "move_record: not a version: refused" "refused" "$(move_record '$(reboot) x' || echo refused)"
expect "move_record: empty: refused" "refused" "$(move_record '' || echo refused)"
expect "apply refuses a VM in the middle of its move (exit 3)" "yes" \
  "$(grep -q 'move_open "$md"' "$R/src/cmd/apply.sh" && grep -A2 'move_open "$md"' "$R/src/cmd/apply.sh" | grep -q 'exit 3' && echo yes)"
expect "update refuses it with --vm and skips it otherwise" "2" "$(grep -c 'move_open "$d"' "$R/src/cmd/update.sh")"
# A disk the person kept (Keep This Disk, or its backup deleted after it): apply tells the VM.
for s in kept done-final done failed running undone; do
  printf 'format=1\nstate=%s\n' "$s" > "$T/lib/move-4.5"
  case $s in kept|done-final) want=kept ;; *) want=no ;; esac
  expect "move_kept: $s is $want" "$want" "$(move_kept "$T/lib" && echo kept || echo no)"
done
expect "move_kept: no journal" "no" "$(move_kept "$T/none" && echo kept || echo no)"
# apply and a move whose switch is not done in the VM (guest omarchy-move.sh pending), whatever
# the Mac's journal says (a disk kept by an older app): exit 3 before anything changes; the
# move's own apply goes on. And a kept disk: the VM is told (omarchy-move.sh keep) once its copy is in.
ap=$R/src/cmd/apply.sh
pblk=$(awk '/^# An OmacVM.app VM whose move to Omarchy 4.5 began/ { on = 1 } on { print } on && /^fi$/ { exit }' "$ap")
kblk=$(awk '/^# A disk the person kept in OmacVM.app after its move stopped/ { on = 1 } on { print } on && /^fi$/ { exit }' "$ap")
ga() {   # PENDING(0|1) STATE [VAR=VALUE]: what apply's two checks do (stand-in gssh, the VM's answer)
  mkdir -p "$T/ap"; printf 'format=1\nstate=%s\n' "$2" > "$T/ap/move-4.5"; : > "$T/ap/calls"
  env "${@:3}" bash -c 'source "$1"; TYPE=app NAMED=1 VM=Old IP=127.0.0.1:52998 T=$2 PEND=$3
    gssh() { echo "gssh ${*: -1}" >> "$T/ap/calls"; [[ ${*: -1} == *pending ]] && { echo "the move to Omarchy 4.5 is not finished in this VM"; return $PEND; }; return 0; }
    info() { echo "info $*" >> "$T/ap/calls"; }; failed_part() { echo "failed $2" >> "$T/ap/calls"; }
    app_dir() { echo "$T/ap"; }'$'\n'"$pblk"$'\n'"$kblk"$'\n''echo "went on" >> "$T/ap/calls"' ga "$R/src/lib/omarchy-move.sh" "$T" "$1"
  echo "rc=$? $(grep -c 'went on' "$T/ap/calls") $(grep -c ' keep$' "$T/ap/calls")"
}
expect "apply on a VM whose move's switch is not done: exit 3 at once, says so, the VM not told to keep" "rc=3 0 0 1" \
  "$(ga 0 failed) $(grep -c "^failed 'Old' is in the middle of its move to Omarchy 4.5: resume or undo it in OmacVM.app first; nothing was changed" "$T/ap/calls")"
expect "... also when the Mac's journal says kept (an older app kept it)" "rc=3 0 0" "$(ga 0 kept)"
expect "... the move's own apply (OMACVM_MOVE_RUN=1) goes on, never asks" "rc=0 1 0 0" "$(ga 0 running OMACVM_MOVE_RUN=1) $(grep -c pending "$T/ap/calls")"
expect "apply on a kept disk past its switch: goes on, the VM told (omarchy-move.sh keep)" "rc=0 1 1" "$(ga 1 kept)"
expect "... the backup deleted after it (done-final): told too" "rc=0 1 1" "$(ga 1 done-final)"
expect "apply after a finished move, or with no move: goes on, nothing to tell" "rc=0 1 0 | rc=0 1 0" "$(ga 1 done) | $(ga 1 undone)"
cl=$(grep -n '^step copy ' "$ap" | cut -d: -f1); pl=$(grep -n '^# An OmacVM.app VM whose move to Omarchy 4.5 began' "$ap" | cut -d: -f1)
kl=$(grep -n '^# A disk the person kept in OmacVM.app after its move stopped' "$ap" | cut -d: -f1); ml=$(grep -n '^# ---------- the Mac side ----------' "$ap" | cut -d: -f1)
expect "apply: the pending check comes before the Mac side and the copy, the keep after the copy" "yes yes" \
  "$( (( pl > 0 && pl < cl && pl < ${ml:-99999} )) && echo yes) $( (( kl > cl )) && echo yes)"
# The app (Swift; OmarchyMove's rules are in window-tests): a disk change and the disk jobs at a start
# wait while the move is not over; the app's own update waits while one runs (also between its VM starts).
dv=$R/app/app/Sources/OmacVM/DiskView.swift
expect "VMDisk.change refuses while the move is not over" "yes" "$(awk '/static func change\(/,/^    }/' "$dv" | grep -q 'MoveFiles.openWhy(c)' && echo yes)"
expect "the disk jobs at a VM start wait while the move is not over" "yes" "$(awk '/static func runJobs\(/,/^    }/' "$dv" | grep -q 'MoveFiles.journal(c)?.open == true' && echo yes)"
expect "the app's own update waits while a move runs (busyReason, restartBlocker)" "2" "$(grep -c 'MoveFiles.running(VMConfig.all())' "$R/app/app/Sources/OmacVM/main.swift")"

# ---------- a fixture app ----------
A=$T/app; mkdir -p "$A/scripts" "$A/runtime/bin" "$A/firmware" "$A/omacvm" "$T/bin" "$T/guest"
cp "$R"/app/scripts/*.sh "$A/scripts/"
ln -s "$R/src" "$A/omacvm/src"
: > "$A/firmware/edk2-aarch64-code.fd"
cat > "$A/runtime/bin/OmacVM" <<'QEMU'
#!/bin/bash
# Stand-in QEMU: runs until killed.
echo $$ > "$FAKE_DIR/qemu.pid"
while [[ $# -gt 0 ]]; do
  [[ $1 == -serial ]] && console=${2#file:}
  if [[ $1 == -chardev && $2 == socket,id=qga0,* ]]; then p=${2#*path=}; p=${p%%,server=*}; : > "$p"; fi
  shift
done
: > "$console"; echo "$console" > "$FAKE_DIR/qemu.console"
# A new boot: the guest's first word over SSH gets in (FAKE_FLAKY counts from there).
[[ -d $FAKE_DIR/guest ]] && { : > "$FAKE_DIR/guest/boot-new"; echo $(( $(cat "$FAKE_DIR/guest/boots" 2>/dev/null || echo 0) + 1 )) > "$FAKE_DIR/guest/boots"; }
# grub: a VM whose boot files were lost (a cut-off before they were on disk) stops at GRUB's prompt.
[[ ${FAKE_MODE:-} == grub ]] && printf 'GNU GRUB  version 2:2.16-1\r\n\r\ngrub> ' > "$console"
# guest/offat (epoch): the guest shuts itself down then (its switch over), whatever the Mac does.
while :; do
  if [[ -f $FAKE_DIR/guest/offat ]] && (( $(date +%s) >= $(cat "$FAKE_DIR/guest/offat") )); then
    rm -f "$FAKE_DIR/guest/offat"; echo "off-self" >> "$FAKE_DIR/power.log"; exit 0
  fi
  sleep 1
done
QEMU
cat > "$T/bin/ssh" <<'SSH'
#!/bin/bash
# Stand-in ssh: the VM, and in it omarchy-move.sh as the contract has it.
# Its state is in $FAKE_DIR/guest/ (it survives the VM's restarts, as a disk does).
G=$FAKE_DIR/guest
kill -0 "$(cat "$FAKE_DIR/qemu.pid" 2>/dev/null)" 2>/dev/null || exit 255
[[ $FAKE_MODE == grub || -e $G/grubbed ]] && exit 255   # no system came up
# silent: the guest no longer answers over SSH (it may still run its move).
[[ -e $G/silent ]] && { echo "kex_exchange_identification: read: Connection reset by peer" >&2; exit 255; }
cmd=${*: -1}
echo "$cmd" >> "$FAKE_DIR/ssh.log"
# FAKE_FLAKY=N: after each boot the guest's first word gets in, the next N do not (sshd up, then its
# firewall or network starting, or sshd turning the Mac away for a while: v340-m2 kill-pre).
# (A shutdown still gets through: the stand-in for ACPI, which needs no network; this QEMU has no QMP.)
if [[ -n ${FAKE_FLAKY:-} && ! -e $G/rebooting && $cmd != "systemctl poweroff" ]]; then
  if [[ -e $G/boot-new ]]; then
    rm -f "$G/boot-new"; echo "$FAKE_FLAKY" > "$G/flaky-left"
  elif (( $(cat "$G/flaky-left" 2>/dev/null || echo 0) > 0 )); then
    echo $(( $(cat "$G/flaky-left") - 1 )) > "$G/flaky-left"
    echo "Connection closed by 127.0.0.1 port 52998" >&2; exit 255
  fi
fi
phases=(preflight protect initramfs keyring repos download commit platform mpv vulkan kernel update report)
json() {   # state phase index commit resumable code reason (switch: $SW, contract v5)
  printf '{"format":1,"state":"%s","phase":"%s","phase_index":%s,"phases":[],"commit_started":%s,"switch":"%s","resumable":%s,"started":"","finished":"","code":"%s","reason":"%s","omarchy":"4.0.3rc4","lane":"omarchy-mac","channel":"rc","log":"/var/log/omacvm-move-45.log","result":null}\n' \
    "$1" "$2" "$3" "$4" "${SW:-none}" "$5" "$6" "$7"
}
case $cmd in
  true)
    # Once after a reboot: the old system is gone for a moment.
    if [[ -e $G/rebooting ]]; then rm -f "$G/rebooting"; exit 255; fi
    exit 0 ;;
  "systemctl poweroff")
    # What the guest's move did when the shutdown came (inside the switch it must not be running).
    echo "poweroff $(cat "$G/state" 2>/dev/null || echo none) ${phases[$(cat "$G/i" 2>/dev/null || echo 0)]}" >> "$FAKE_DIR/power.log"
    # FAKE_STUBBORN=1: a VM that does not shut down (OmacVM must end it after a while).
    [[ ${FAKE_STUBBORN:-} == 1 ]] || (sleep 1; kill "$(cat "$FAKE_DIR/qemu.pid")") & exit 0 ;;
  "systemctl reboot")
    : > "$G/rebooting"; : > "$G/boot-new"; echo $(( $(cat "$G/boots" 2>/dev/null || echo 0) + 1 )) > "$G/boots"
    # grub-restart: the restart stops at GRUB's prompt (its boot files lost).
    if [[ $FAKE_MODE == grub-restart ]]; then
      : > "$G/grubbed"
      printf 'GNU GRUB  version 2:2.16-1\r\n\r\ngrub> ' >> "$(cat "$FAKE_DIR/qemu.console")"
    fi
    exit 0 ;;
  "cat /proc/sys/kernel/random/boot_id") printf '00000000-0000-0000-0000-%012d\n' "$(cat "$G/boots" 2>/dev/null || echo 0)"; exit 0 ;;
  "test -x "*omarchy-move.sh) [[ $FAKE_MODE == guest-old ]] && exit 1; exit 0 ;;
  *"systemctl --failed"*) echo 0; exit 0 ;;
  "cat /var/log/omacvm-move-45.log") echo "guest log"; exit 0 ;;
  *"omarchy-move.sh preflight --json")
    case $FAKE_MODE in
      net) printf '{"format":1,"ok":false,"code":"repos-unreachable","reason":"pkgs.omarchy.org did not answer."}\n'; exit 4 ;;
      busy) printf '{"format":1,"ok":false,"code":"pacman-busy","reason":"Another pacman runs in the VM."}\n'; exit 4 ;;
      busy-first) printf '{"format":1,"ok":false,"code":"pacman-busy","reason":"Another pacman runs in the VM."}\n'; exit 3 ;;
      refuse) printf '{"format":1,"ok":false,"code":"apple-platform","reason":"This VM says it is an Apple machine."}\n'; exit 3 ;;
      moved) printf '{"format":1,"ok":false,"code":"already-moved","reason":"On 4.5 already."}\n'; exit 3 ;;
    esac
    printf '{"format":1,"ok":true,"code":"","reason":"","omarchy":"4.0.3rc4","lane":"omarchy-mac","channel":"rc","target":{"omarchy":"4.5.0","channel":"stable"},"checks":[]}\n'
    exit 0 ;;
  *"omarchy-move.sh start")
    [[ -f $G/state ]] && [[ $(cat "$G/state") == done ]] && exit 0
    [[ $FAKE_MODE == busy-start ]] && { printf '{"format":1,"ok":false,"code":"pacman-busy","reason":"Another pacman runs in the VM."}\n'; exit 4; }
    [[ $FAKE_MODE == busy-start-first ]] && { printf '{"format":1,"ok":false,"code":"pacman-busy","reason":"Another pacman runs in the VM."}\n'; exit 3; }
    if [[ -e $G/inswitch ]]; then
      printf '{"format":1,"ok":false,"code":"undo-only","reason":"The package switch was cut off; Undo puts the VM back as it was before the move."}\n'; exit 3
    fi
    echo running > "$G/state"; rm -f "$G/stop"; [[ -f $G/i ]] || echo 0 > "$G/i"
    exit 0 ;;
  *"omarchy-move.sh stop") : > "$G/stop"; exit 0 ;;
  *"omarchy-move.sh record")
    [[ $(cat "$G/state" 2>/dev/null) == done ]] && echo "4.5.0 aarch64 stable" || echo "4.0.3rc4 omarchy-mac rc"; exit 0 ;;
  *"omarchy-move.sh status --json")
    st=$(cat "$G/state" 2>/dev/null || echo none); i=$(cat "$G/i" 2>/dev/null || echo 0)
    c=false; (( i >= 6 )) && c=true
    # The switch (commit is phase 7, index 6): running in it, done after it; failed or cut off in it: half.
    SW=none; (( i == 6 )) && SW=running; (( i > 6 )) && SW=done
    [[ $FAKE_MODE == fail-commit ]] && (( i == 6 )) && SW=half
    [[ -e $G/inswitch ]] && SW=half
    if [[ $st == running ]]; then
      ph=${phases[$i]}
      if [[ $ph == commit && $FAKE_MODE == slow-commit ]]; then
        # A long switch: 8 answers inside it (a stop waits for its end), then on.
        n=$(( $(cat "$G/cn" 2>/dev/null || echo 0) + 1 )); echo $n > "$G/cn"
        if (( n <= 8 )); then json running commit 7 true false "" ""; exit 0; fi
        echo 7 > "$G/i"; json running platform 8 true true "" ""; exit 0
      fi
      if [[ $ph == commit && ( $FAKE_MODE == cut-after-switch || $FAKE_MODE == cut-in-switch ) ]]; then
        # The Mac's last word from the guest: inside the switch. Then the VM is cut off (QEMU -9): right
        # after the switch was done (its journal synced: resumable again), or inside it.
        if [[ ! -e $G/cut ]]; then : > "$G/cut"; json running commit 7 true false "" ""; exit 0; fi
        echo interrupted > "$G/state"
        if [[ $FAKE_MODE == cut-after-switch ]]; then echo 7 > "$G/i"; else : > "$G/inswitch"; fi
        kill -9 "$(cat "$FAKE_DIR/qemu.pid")"; exit 255
      fi
      if [[ $FAKE_MODE == fail-commit && $ph == commit ]]; then echo failed > "$G/state"; json failed commit 7 true false commit "pacman failed in the switch."; exit 0; fi
      if [[ $FAKE_MODE == net-download && $ph == download ]]; then echo failed > "$G/state"; json failed download 6 false true repos-unreachable "Downloads stopped."; exit 0; fi
      # slow: stays at download (until a stop)
      if [[ $FAKE_MODE == slow && $ph == download && ! -e $G/stop ]]; then json running download 6 false true "" ""; exit 0; fi
      if [[ -e $G/stop && $ph != commit ]]; then echo stopped > "$G/state"; json stopped "$ph" $((i + 1)) $c true "" "stopped"; exit 0; fi
      # The switch writes to the disk (Undo must bring the old bytes back).
      [[ $ph == commit ]] && printf 'MOVED' | dd of="$FAKE_VM/disk.img" bs=1 seek=4096 conv=notrunc 2>/dev/null
      json running "$ph" $((i + 1)) $c true "" ""
      i=$((i + 1)); echo $i > "$G/i"
      (( i >= ${#phases[@]} )) && echo done > "$G/state"
      exit 0
    fi
    r=true; [[ -e $G/inswitch ]] && r=false
    json "$st" "${phases[$i]:-report}" $((i + 1)) $c $r "" ""
    exit 0 ;;
esac
exit 0
SSH
cat > "$A/scripts/apply-vm.sh" <<'APPLY'
#!/bin/bash
echo "${OMACVM_KERNEL_NEW:-unset} ${OMACVM_MOVE_RUN:-unset}" >> "$FAKE_DIR/apply.log"
echo "${OMACVM_APPLY_SSH_SECONDS:-unset}" >> "$FAKE_DIR/apply-env.log"
# apply4-ssh: the first apply cannot reach the VM (apply-vm.sh's own error line).
if [[ $FAKE_MODE == apply4-ssh && $(wc -l < "$FAKE_DIR/apply.log") -eq 1 ]]; then
  echo "ERROR: Old does not answer over SSH (127.0.0.1:52998): SSH closed the connection."; exit 1
fi
echo "(apply)" >> "$FAKE_DIR/ssh.log"   # in order with what the move asked the VM
# apply6-fail: the apply after the move (the second one) fails once.
if [[ $FAKE_MODE == apply6-fail && $(wc -l < "$FAKE_DIR/apply.log") -eq 2 ]]; then echo "error: the VM side failed"; exit 1; fi
echo "==> OmacVM applied"
APPLY
chmod +x "$A/runtime/bin/OmacVM" "$T/bin/ssh" "$A/scripts/apply-vm.sh"
: > "$T/key"

V=$T/VMs/Old
fresh() {   # a 4.0 VM folder, its guest's move not begun
  rm -rf "$V" "$T/guest" "$T/apply.log" "$T/ssh.log"; mkdir -p "$V" "$T/guest"
  printf "NAME='Old'\nCPUS=2\nMEM_MB=4096\nDISK_GB=64\nSSH_PORT=52998\nVM_USER='me'\nKEYBOARD='us'\n" > "$V/vm.env"
  dd if=/dev/urandom of="$V/disk.img" bs=1k count=256 2>/dev/null
  printf 'efi' > "$V/efi-vars.fd"; : > "$V/ready"
  echo "bridge=on gestures=on" > "$V/features"; echo 3.3.0 > "$V/omacvm-version"; echo vulkan > "$V/graphics"
  echo "4.0.3rc4 omarchy-mac rc" > "$V/omarchy"
}
mv_run() {   # MODE CMD [VAR=VALUE...]: exit status; output in $T/out
  local mode=$1 cmd=$2; shift 2
  # A stand-in QEMU left running (an app crash) keeps its pid file: the stand-in ssh reaches it.
  kill -0 "$(cat "$T/qemu.pid" 2>/dev/null)" 2>/dev/null || rm -f "$T/qemu.pid"
  env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_VM="$V" FAKE_MODE="$mode" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= OMACVM_MOVE_POLL=0.2 OMACVM_SSH_PAUSE=0.2 "$@" \
    /bin/bash "$A/scripts/move-vm.sh" "$V" "$cmd" > "$T/out" 2>&1
}
jget() { sed -n "s/^$1=//p" "$V/move-4.5" | head -1; }
qemu_gone() { kill -0 "$(cat "$T/qemu.pid" 2>/dev/null)" 2>/dev/null && echo runs || echo gone; }

fresh
probe=$T/clone-probe; echo x > "$probe"
if ! cp -c "$probe" "$probe.c" 2>/dev/null; then
  echo "skip: $T makes no APFS clones"
  exit $fail
fi

# ---------- plan: the Mac's checks ----------
mv_run ok plan; rc=$?
expect "plan: a VM on APFS with room: exit 0" "0" "$rc"
expect "plan: says APFS" "apfs=1" "$(grep '^apfs=' "$T/out")"
expect "plan: need = allocated + 10 GB + 4 GB" "yes" "$(n=$(sed -n 's/^need=//p' "$T/out"); (( n >= 14 << 30 && n < (14 << 30) + (1 << 20) )) && echo yes || echo "$n")"
echo grow > "$V/disk-jobs"
mv_run ok plan; rc=$?
expect "plan: a disk grow not done yet: refused (exit 3)" "3" "$rc"
expect "plan: ... says why" "yes" "$(grep -q '^problem=Omarchy grows' "$T/out" && echo yes)"
mv_run ok run; rc=$?
expect "run: refused by the Mac's check, step 1" "1 failed 1" "$rc $(jget state) $(jget failed_step)"
expect "run: ... no backup made" "none" "$([[ -d $V/before-omarchy-4.5 ]] && echo made || echo none)"
rm -f "$V/disk-jobs" "$V/move-4.5"

# ---------- a move to the end, then Delete the backup ----------
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run ok run; rc=$?
expect "run: a move to the end exits 0" "0" "$rc"
expect "run: says MOVED" "MOVED Old" "$(grep '^MOVED' "$T/out")"
expect "run: the 8 steps in order" "1 2 3 4 5 6 7 8" "$(sed -n 's/^STEP \([0-9]\)\/8 .*/\1/p' "$T/out" | tr '\n' ' ' | sed 's/ $//')"
expect "run: the guest's parts said as they come" "yes" "$(grep -q '==> Downloading packages (part 6 of 13)' "$T/out" && grep -q "==> Switching the packages" "$T/out" && echo yes)"
expect "run: journal done at step 8" "done 8 1" "$(jget state) $(jget step) $(jget commit_started)"
expect "run: journal knows where it came from" "3.3.0 64" "$(jget from_omacvm) $(jget from_disk_gb)"
expect "run: the backup: disk, EFI vars, records, README" "disk.img efi-vars.fd features graphics omacvm-version omarchy README.txt vm.env" \
  "$(ls "$V/before-omarchy-4.5" | sort -f | tr '\n' ' ' | sed 's/ $//')"
expect "run: the backup is the disk from before" "$sum0" "$(shasum "$V/before-omarchy-4.5/disk.img" | cut -c1-40)"
expect "run: the disk moved on" "changed" "$([[ $(shasum "$V/disk.img" | cut -c1-40) != "$sum0" ]] && echo changed)"
expect "run: the Omarchy record says 4.5" "4.5.0 aarch64 stable" "$(cat "$V/omarchy")"
expect "run: OmacVM applied twice, kernel kept, as the move's own apply" $'keep 1\nkeep 1' "$(cat "$T/apply.log")"
expect "run: preflight, start, status, record, restart" "yes" \
  "$(grep -q 'preflight --json' "$T/ssh.log" && grep -q 'omarchy-move.sh start' "$T/ssh.log" && grep -q 'systemctl reboot' "$T/ssh.log" && grep -q 'record' "$T/ssh.log" && echo yes)"
expect "run: the guest's log copied" "guest log" "$(cat "$V/logs/move-4.5.log" 2>/dev/null)"
expect "run: QEMU is gone" "gone" "$(qemu_gone)"
mv_run ok run; rc=$?
expect "run again after a move: refused (exit 3)" "3" "$rc"
mv_run ok delete-backup; rc=$?
expect "delete-backup: exit 0, the backup is gone" "0 gone" "$rc $([[ -e $V/before-omarchy-4.5 ]] && echo there || echo gone)"
expect "delete-backup: the journal is final" "done-final" "$(jget state)"

# ---------- Undo after a move: the disk as it was ----------
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run ok run; rc=$?
expect "undo: (the move first)" "0" "$rc"
sed -i '' 's/^DISK_GB=.*/DISK_GB=96/; s/^CPUS=.*/CPUS=4/' "$V/vm.env"   # grown, and more CPUs, since
mv_run ok undo; rc=$?
expect "undo: exit 0" "0" "$rc"
expect "undo: disk.img byte for byte as before the move" "$sum0" "$(shasum "$V/disk.img" | cut -c1-40)"
expect "undo: the records back (Omarchy 4.0, OmacVM 3.3.0)" "4.0.3rc4 omarchy-mac rc 3.3.0" "$(cat "$V/omarchy") $(cat "$V/omacvm-version")"
expect "undo: the disk's size back, the CPUs as set since" "64 4" "$(sed -n 's/^DISK_GB=//p' "$V/vm.env") $(sed -n 's/^CPUS=//p' "$V/vm.env")"
expect "undo: the backup folder is gone, the journal says undone" "gone undone" "$([[ -e $V/before-omarchy-4.5 ]] && echo there || echo gone) $(jget state)"
expect "undo: no reason left in the journal (the undoing one is over)" "" "$(jget reason)"

# ---------- no network: Resume ----------
fresh
mv_run net run; rc=$?
expect "network down at the check: exit 1, failed at step 5, Resume" "1 failed 5 1" "$rc $(jget state) $(jget failed_step) $(jget resumable)"
expect "... the reason says to check the network" "yes" "$(jget reason | grep -q 'did not answer. Check the Mac' && echo yes)"
expect "... QEMU is gone" "gone" "$(qemu_gone)"
mv_run ok run; rc=$?
expect "Resume: goes to the end" "0 done" "$rc $(jget state)"
expect "Resume: keeps the first backup" "yes" "$(grep -q 'the backup from .* is kept' "$T/out" && echo yes)"
fresh
mv_run net-download run; rc=$?
expect "network lost in the download: failed, Resume" "1 failed 1 0" "$rc $(jget state) $(jget resumable) $(jget commit_started)"
mv_run ok run; rc=$?
expect "Resume after the download: to the end" "0 done" "$rc $(jget state)"

# ---------- another pacman in the VM (contract v5, #722 round 2: pacman-busy, exit 4): Resume, not the network ----------
fresh
mv_run busy run; rc=$?
expect "preflight: another pacman runs: failed at step 5, Resume, pacman-busy" "1 failed 5 1 pacman-busy" "$rc $(jget state) $(jget failed_step) $(jget resumable) $(jget code)"
expect "... the reason does not send the person to the Mac's network" "yes" "$(r=$(jget reason); [[ $r == *"Another pacman"* && $r != *network* && $r == *Resume* ]] && echo yes || echo "'$r'")"
mv_run net-download run
mv_run busy-start run; rc=$?
expect "start on a Resume: another pacman runs: Resume, pacman-busy, not the network" "1 1 pacman-busy yes" \
  "$rc $(jget resumable) $(jget code) $(r=$(jget reason); [[ $r != *network* ]] && echo yes || echo "'$r'")"
mv_run ok run; rc=$?
expect "... Resume then: to the end" "0 done" "$rc $(jget state)"
# A first run (contract v5: preflight and start say pacman-busy with exit 3 there, 4 on a Resume):
# Resume all the same, never Undo only, and not the network.
fresh
mv_run busy-first run; rc=$?
expect "first run, preflight: another pacman runs (exit 3): Resume, pacman-busy, not the network" "1 failed 5 1 pacman-busy yes" \
  "$rc $(jget state) $(jget failed_step) $(jget resumable) $(jget code) $(r=$(jget reason); [[ $r == *"Another pacman"* && $r != *network* && $r != *Undo* && $r == *Resume* ]] && echo yes || echo "'$r'")"
fresh
mv_run busy-start-first run; rc=$?
expect "first run, start: another pacman runs (exit 3): Resume, pacman-busy, not the network" "1 1 pacman-busy yes" \
  "$rc $(jget resumable) $(jget code) $(r=$(jget reason); [[ $r != *network* && $r != *Undo* ]] && echo yes || echo "'$r'")"
mv_run ok run; rc=$?
expect "... Resume then: to the end (first run)" "0 done" "$rc $(jget state)"

# ---------- refused by the guest; failed inside the switch ----------
fresh
mv_run refuse run; rc=$?
expect "refused by the guest: failed, Undo only" "1 failed 0 apple-platform" "$rc $(jget state) $(jget resumable) $(jget code)"
mv_run refuse undo; rc=$?
expect "undo after a refusal: the disk is as before" "0 undone" "$rc $(jget state)"
fresh
mv_run fail-commit run; rc=$?
expect "failed inside the package switch: Undo only" "1 failed 0 1" "$rc $(jget state) $(jget resumable) $(jget commit_started)"
mv_run ok run; rc=$?
expect "... run again is refused (no half transaction resumed)" "yes" "$(grep -q 'cannot go on' "$T/out" && echo "yes")"
mv_run ok delete-backup; rc=$?
expect "... Delete the backup is refused while it is not undone or kept" "1 there" "$rc $([[ -d $V/before-omarchy-4.5 ]] && echo there)"
mv_run ok keep; rc=$?
expect "Keep This Disk after a switch that failed half way: refused (exit 3: Undo), the move still open" "3 failed half" "$rc $(jget state) $(jget guest_switch)"
# Keep only once the guest said its switch is done (v340-fix4 review: a kept switch not done stayed
# pending in the VM for good). A failure after the switch: Keep, then Delete the backup.
fresh
mv_run apply6-fail run; rc=$?
expect "failed after the switch (the apply after it): Resume, the guest said its switch is done" "1 failed 6 1 done" \
  "$rc $(jget state) $(jget failed_step) $(jget resumable) $(jget guest_switch)"
mv_run ok keep; rc=$?
expect "Keep This Disk: kept, the backup stays" "0 kept there" "$rc $(jget state) $([[ -d $V/before-omarchy-4.5 ]] && echo there)"
mv_run ok delete-backup; rc=$?
expect "... then Delete the backup" "0 done-final" "$rc $(jget state)"
# After Keep and Delete the Mac's record still says 4.0 (step 7 did not run): the card offers the
# move again, and it goes on to the end (the guest says it is done: steps 6 and 7).
mv_run ok run; rc=$?
expect "kept, backup deleted, the record still 4.0: the move runs again to the end" "0 done 4.5.0 aarch64 stable" "$rc $(jget state) $(cat "$V/omarchy")"
# Keep before Omarchy's packages began to change: refused (the disk is 4.0 as it was; Resume or Undo).
fresh
mv_run net run
mv_run ok keep; rc=$?
expect "Keep before the switch began: refused (exit 3), the move still open" "3 failed" "$rc $(jget state)"
# The VM cut off inside the switch (the last word: running in it): Keep refused; Resume asks the VM.
fresh
mv_run cut-in-switch run
mv_run ok keep; rc=$?
expect "Keep after a cut-off inside the switch: refused, Resume asks the VM" "3 1 running" "$rc $(jget ask_guest) $(jget guest_switch)"

# ---------- Undo cut off, then Undo again; Undo after a backup cut short ----------
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run ok run
mv "$V/before-omarchy-4.5/disk.img" "$V/disk.img"   # where an Undo that renamed the disk first was cut off
mv_run ok undo; rc=$?
expect "Undo after an Undo cut off past the disk: undone, the records from before back (4.0, not 4.5)" \
  "0 undone 4.0.3rc4 omarchy-mac rc gone $sum0" "$rc $(jget state) $(cat "$V/omarchy") $([[ -e $V/before-omarchy-4.5 ]] && echo there || echo gone) $(shasum "$V/disk.img" | cut -c1-40)"
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run ok run
mv_run ok undo OMACVM_TEST_UNDO_STOP=disk; rc=$?
expect "Undo cut off before the disk: not undone yet (undoing: only Undo), the records already back" "1 undoing 4.0.3rc4 omarchy-mac rc" "$rc $(jget state) $(cat "$V/omarchy")"
mv_run ok undo; rc=$?
expect "... Undo again: the disk from before, undone, the backup gone" "0 undone $sum0 gone" \
  "$rc $(jget state) $(shasum "$V/disk.img" | cut -c1-40) $([[ -e $V/before-omarchy-4.5 ]] && echo there || echo gone)"
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mkdir -p "$V/before-omarchy-4.5"; cp -c "$V/disk.img" "$V/before-omarchy-4.5/disk.img"   # step 3 cut short: no records, no backup_at
printf 'format=1\nstate=interrupted\nstep=3\nbackup_at=\ncommit_started=0\nresumable=1\n' > "$V/move-4.5"
mv_run ok undo; rc=$?
expect "Undo after a backup cut short: undone, the VM's records all kept, the disk as it was" \
  "0 undone features graphics omacvm-version omarchy $sum0" \
  "$rc $(jget state) $(cd "$V" && ls features graphics omacvm-version omarchy 2>/dev/null | tr '\n' ' ')$(shasum "$V/disk.img" | cut -c1-40)"

# ---------- the apply after the move fails: Resume skips the finished guest move ----------
fresh
mv_run apply6-fail run; rc=$?
expect "apply after the move fails: failed at step 6, Resume" "1 failed 6 1" "$rc $(jget state) $(jget failed_step) $(jget resumable)"
expect "... the VM restarted before that apply (the new kernel)" "yes" "$(grep -c 'systemctl reboot' "$T/ssh.log" | grep -q '^1$' && echo yes)"
mv_run ok run; rc=$?
expect "Resume: the guest's move is done, steps 6-8, to the end" "0 done" "$rc $(jget state)"
expect "... no second start of the guest's move" "1" "$(grep -c 'omarchy-move.sh start' "$T/ssh.log")"

# ---------- Stop and Quit, then Resume ----------
fresh; : > "$T/out"
( mv_run slow run ) & BG=$!
for ((i = 0; i < 100; i++)); do grep -q 'Downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
: > "$V/move-4.5.stop"
wait "$BG"; rc=$?; BG=""
expect "Stop and Quit: stops (exit 1), interrupted at step 5" "1 interrupted 5" "$rc $(jget state) $(jget step)"
expect "... the guest was asked to stop" "yes" "$(grep -q 'omarchy-move.sh stop' "$T/ssh.log" && echo yes)"
expect "... the stop file is gone, QEMU too" "gone gone" "$([[ -e $V/move-4.5.stop ]] && echo there || echo gone) $(qemu_gone)"
mv_run ok run; rc=$?
expect "Resume after Stop: to the end" "0 done" "$rc $(jget state)"

# ---------- a killed run (power cut), then Resume ----------
fresh; : > "$T/out"
( mv_run slow run ) & BG=$!
for ((i = 0; i < 100; i++)); do grep -q 'Downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
pid=$(jget pid); qpid=$(cat "$T/qemu.pid")
[[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) || { echo "FAIL the killed run: no pid in the journal"; exit 1; }
expect "while it runs: undo is refused" "1" "$(mv_run ok undo; echo $?)"
kill -9 "$pid"; kill "$qpid" 2>/dev/null; wait "$BG" 2>/dev/null; BG=""
expect "killed: the journal still says running, its pid is gone" "running gone" "$(jget state) $(kill -0 "$pid" 2>/dev/null && echo runs || echo gone)"
mv_run ok run; rc=$?
expect "Resume after the kill: to the end" "0 done" "$rc $(jget state)"

# ---------- the app gone mid-move (killed): the move still stops at a safe point ----------
fresh; : > "$T/out"
( env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_VM="$V" FAKE_MODE=slow OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= OMACVM_MOVE_POLL=0.2 \
    /bin/bash -c '/bin/bash "$1" "$2" run < /dev/null 2>&1 | tee "$3" > /dev/null' app "$A/scripts/move-vm.sh" "$V" "$T/out" ) &
BG=$!
for ((i = 0; i < 100; i++)); do grep -q 'Downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
app=$(pgrep -f "^/bin/bash -c /bin/bash" | head -1); kill -9 "$app" 2>/dev/null
for ((i = 0; i < 150; i++)); do [[ $(jget state) != running && $(jget pid) == 0 ]] && break; sleep 0.2; done
wait "$BG" 2>/dev/null; BG=""
expect "the app killed mid-move: the move stops (interrupted, Resume), QEMU gone" "interrupted 1 gone" "$(jget state) $(jget resumable) $(qemu_gone)"
expect "... the guest was asked to stop" "yes" "$(grep -q 'omarchy-move.sh stop' "$T/ssh.log" && echo yes)"
mv_run ok run; rc=$?
expect "... Resume after that: to the end" "0 done" "$rc $(jget state)"

# ---------- a pid from before the Mac's restart is not a running move ----------
fresh
sleep 600 & live=$!
bt=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
printf 'format=1\nstate=running\nstep=5\npid=%s\nboot=%s\n' "$live" "$bt" > "$V/move-4.5"
mv_run ok undo; rc=$?
expect "a live pid of this boot: undo refused" "1" "$rc"
printf 'format=1\nstate=running\nstep=5\npid=%s\nboot=12345\n' "$live" > "$V/move-4.5"
mv_run ok undo; rc=$?
expect "the same pid from before a restart: not the move, undo goes on" "0 undone" "$rc $(jget state)"
kill "$live" 2>/dev/null

# ---------- a VM on Mac OS Extended (cp -c copies there, rc 0): refused ----------
H=$T/hfs
if hdiutil create -quiet -size 40m -fs HFS+ -volname omacvm-move-test "$T/hfs.dmg" 2>/dev/null && mkdir -p "$H" &&
   hdiutil attach -quiet -nobrowse -mountpoint "$H" "$T/hfs.dmg" 2>/dev/null; then
  Vs=$V; V=$H/Old; mkdir -p "$V"
  cp "$Vs/vm.env" "$Vs/efi-vars.fd" "$Vs/ready" "$V/"; dd if=/dev/urandom of="$V/disk.img" bs=1k count=64 2>/dev/null
  mv_run ok plan; rc=$?
  expect "HFS+: plan refuses (exit 3), apfs=0" "3 apfs=0" "$rc $(grep '^apfs=' "$T/out")"
  mv_run ok run; rc=$?
  expect "HFS+: run fails at step 1, no backup" "1 1 none" "$rc $(jget failed_step) $([[ -d $V/before-omarchy-4.5 ]] && echo made || echo none)"
  rm -rf "$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(VMID "$V")".*
  V=$Vs
  hdiutil detach -quiet "$H" 2>/dev/null || hdiutil detach -quiet -force "$H"
else
  echo "skip: no HFS+ disk image here"
fi

# ---------- the move's script killed, its VM left running (an app crash) ----------
crash_mid() {   # a slow move, its script killed -9 in the download: its QEMU runs on
  fresh; : > "$T/out"; rm -f "$T/power.log"
  ( mv_run slow run ) & BG=$!
  for ((i = 0; i < 100; i++)); do grep -q 'Downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
  local p; p=$(jget pid)
  [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill -9 "$p"
  wait "$BG" 2>/dev/null; BG=""
  oq=$(cat "$T/qemu.pid")
}
no_process_line() { [[ $1 == *runs* && $1 != */* && ! $1 =~ [0-9]{3,} ]] && echo clean || echo "'$1'"; }
crash_mid
expect "crash: the journal says running, the script is gone, its VM runs" "running gone runs" "$(jget state) $(kill -0 "$(jget pid)" 2>/dev/null && echo runs || echo gone) $(qemu_gone)"
expect "crash: the journal names the move's QEMU" "$oq" "$(jget qemu_pid)"
mv_run ok settle; rc=$?
oq_gone() { kill -0 "$oq" 2>/dev/null && echo runs || echo gone; }
expect "settle: exit 0, the VM the move left is shut down" "0 gone" "$rc $(oq_gone)"
expect "settle: asked the guest to stop at a safe point, then shut it down" "yes" "$(grep -q 'omarchy-move.sh stop' "$T/ssh.log" && grep -q poweroff "$T/power.log" 2>/dev/null && echo yes)"
expect "settle: the journal says interrupted, Resume, no QEMU" "interrupted 1 0" "$(jget state) $(jget resumable) $(jget qemu_pid)"
expect "settle: the reason names no process" "yes" "$(r=$(jget reason); [[ -n $r && $r != */* && ! $r =~ [0-9]{3,} ]] && echo yes || echo "'$r'")"
mv_run ok settle; rc=$?
expect "settle again: nothing left, exit 0" "0" "$rc"
mv_run ok run; rc=$?
expect "settle, then Resume: to the end" "0 done" "$rc $(jget state)"

crash_mid
mv_run ok run; rc=$?
expect "crash, then Resume at once: the old VM stopped first, the move to the end" "0 done gone" \
  "$rc $(jget state) $(kill -0 "$oq" 2>/dev/null && echo runs || echo gone)"
expect "... the reason never says 'shut it down'" "no" "$(grep -q 'shut it down' "$T/out" && echo yes || echo no)"

crash_mid
sum1=$(shasum "$V/before-omarchy-4.5/disk.img" | cut -c1-40)
mv_run ok undo; rc=$?
expect "crash, then Undo: the old VM stopped first, undone, the disk from before" "0 undone gone $sum1" \
  "$rc $(jget state) $(kill -0 "$oq" 2>/dev/null && echo runs || echo gone) $(shasum "$V/disk.img" | cut -c1-40)"

crash_mid
mv_run slow keep; rc=$?
expect "crash in the download, then Keep This Disk: the old VM stopped first (in the download), Keep refused (no switch yet)" "3 interrupted gone" \
  "$rc $(jget state) $(kill -0 "$oq" 2>/dev/null && echo runs || echo gone)"
crash_mid
mv_run ok keep; rc=$?
expect "crash, then Keep This Disk: the old VM went on past its switch before it stopped (settle): kept" "0 kept gone done" \
  "$rc $(jget state) $(kill -0 "$oq" 2>/dev/null && echo runs || echo gone) $(jget guest_switch)"

crash_mid
mv_run ok settle FAKE_STUBBORN=1 OMACVM_MOVE_SETTLE_SECONDS=2; rc=$?
expect "a left VM that does not shut down: ended after the wait, exit 0" "0 gone interrupted" "$rc $(oq_gone) $(jget state)"

# ---------- an app crash inside the package switch: the guest's own last word decides ----------
# (v340-m2 crash-commit: settle powered the VM off while the guest switched packages, and the
# guest's "resumable" after it never reached the Mac.)
fresh; : > "$T/out"; rm -f "$T/power.log"
( mv_run slow-commit run ) & BG=$!
for ((i = 0; i < 150; i++)); do grep -q 'Switching the packages' "$T/out" 2>/dev/null && break; sleep 0.1; done
p=$(jget pid); [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill -9 "$p"
wait "$BG" 2>/dev/null; BG=""; oq=$(cat "$T/qemu.pid")
expect "crash in the switch: the Mac's last poll said inside it (commit, not resumable)" "running 1 0" "$(jget state) $(jget commit_started) $(jget resumable)"
mv_run slow-commit settle; rc=$?
expect "settle in the switch: exit 0, the VM is off" "0 gone" "$rc $(kill -0 "$oq" 2>/dev/null && echo runs || echo gone)"
expect "settle in the switch: no shutdown while the guest's move ran (it stopped at its safe point first)" "poweroff stopped platform" "$(cat "$T/power.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
expect "settle in the switch: the guest's last word wins (switched, resumable)" "interrupted 1 1 none" \
  "$(jget state) $(jget commit_started) $(jget resumable) $(jget ask_guest | grep -v '^0$' | grep . || echo none)"
mv_run ok run; rc=$?
expect "... then Resume: to the end" "0 done" "$rc $(jget state)"

# ---------- the VM cut off right after the switch; the Mac's last poll said inside it ----------
# (v340-m2 kpost: every Resume refused although the guest had finished its switch.)
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run cut-after-switch run; rc=$?
expect "cut off after the switch: failed, Undo only for now, but the VM is to be asked (ask_guest)" "1 failed 0 1 1" \
  "$rc $(jget state) $(jget resumable) $(jget commit_started) $(jget ask_guest)"
expect "... the reason says Resume asks the VM" "yes" "$(jget reason | grep -q 'Resume asks' && echo yes)"
echo "-- resume" >> "$T/ssh.log"
mv_run ok run; rc=$?
expect "Resume: the VM is asked first, says the switch is done: to the end" "0 done" "$rc $(jget state)"
expect "... it asked the VM before OmacVM's update in it" "status" \
  "$(sed -n '/^-- resume$/,$p' "$T/ssh.log" | grep -m1 -E 'status --json|^\(apply\)' | grep -q status && echo status)"
expect "... the journal no longer asks" "none" "$(jget ask_guest | grep -v '^0$' | grep . || echo none)"

# ---------- cut off inside the switch: the VM says so, Undo only (nothing else touched) ----------
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40)
mv_run cut-in-switch run; rc=$?
expect "cut off inside the switch: failed, to be asked" "1 failed 0 1" "$rc $(jget state) $(jget resumable) $(jget ask_guest)"
n_apply=$(wc -l < "$T/apply.log" | tr -d ' ')
mv_run ok run; rc=$?
expect "Resume: the VM says its switch was cut off: Undo only, decided" "1 failed 0 undo-only none" \
  "$rc $(jget state) $(jget resumable) $(jget code) $(jget ask_guest | grep -v '^0$' | grep . || echo none)"
expect "... OmacVM was not updated in that VM, the VM is off" "$n_apply gone" "$(wc -l < "$T/apply.log" | tr -d ' ') $(qemu_gone)"
mv_run ok run; rc=$?
expect "... Resume again: refused at once (no VM start)" "1 yes" "$rc $(grep -q 'cannot go on' "$T/out" && echo yes)"
mv_run ok undo; rc=$?
expect "... Undo: the disk from before" "0 undone $sum0" "$rc $(jget state) $(shasum "$V/disk.img" | cut -c1-40)"

# ---------- a VM stopped at GRUB's prompt: no 5 minutes of waiting, Undo ----------
fresh
mv_run cut-after-switch run
t0=$(date +%s)
mv_run grub run OMACVM_MOVE_BOOT_SECONDS=40; rc=$?
expect "Resume, the VM stops at GRUB's prompt: failed at once at step 4, Undo only" "1 failed 4 0 no-boot" \
  "$rc $(jget state) $(jget failed_step) $(jget resumable) $(jget code)"
expect "... within seconds, not the boot wait" "1" "$(( $(date +%s) - t0 < 30 ))"
expect "... the reason says Undo, QEMU is gone" "yes gone" "$(jget reason | grep -q Undo && echo yes) $(qemu_gone)"
fresh
mv_run net run
mv_run grub run OMACVM_MOVE_BOOT_SECONDS=40; rc=$?
expect "a Resume before the switch, the VM at GRUB's prompt: failed, Undo only" "1 4 0 no-boot" "$rc $(jget failed_step) $(jget resumable) $(jget code)"

# ---------- a VM still going away (Undo waits); one that runs on (refused, plainly) ----------
fresh
/bin/bash -c 'sleep 3; true' "-drive" "if=none,file=$V/disk.img,format=raw" & dying=$!
mv_run ok undo; rc=$?
expect "a VM on its way out (killed, not gone yet): Undo waits for it" "0 undone" "$rc $(jget state)"
kill "$dying" 2>/dev/null
fresh
/bin/bash -c 'sleep 600; true' "-drive" "if=none,file=$V/disk.img,format=raw" & other=$!
mv_run ok undo OMACVM_MOVE_GONE_SECONDS=2; rc=$?
expect "a VM that runs on (not the move's): Undo refused" "1" "$rc"
expect "... its reason names no process" "clean" "$(no_process_line "$(sed -n 's/^ERROR: //p' "$T/out" | tail -1)")"
expect "... and that VM is left alone" "runs" "$(kill -0 "$other" 2>/dev/null && echo runs || echo gone)"
mv_run ok run OMACVM_MOVE_GONE_SECONDS=2; rc=$?
expect "... a move refused at step 1, its reason names no process" "1 1 clean" "$rc $(jget failed_step) $(no_process_line "$(jget reason)")"
mv_run ok plan OMACVM_MOVE_GONE_SECONDS=2; rc=$?
expect "... plan's problem names no process" "3 clean" "$rc $(no_process_line "$(sed -n 's/^problem=//p' "$T/out")")"
kill "$other" 2>/dev/null

# ---------- a guest without omarchy-move.sh ----------
fresh
mv_run guest-old run; rc=$?
expect "a guest without the move: failed at step 4, Resume" "1 failed 4 guest-old" "$rc $(jget state) $(jget failed_step) $(jget code)"
mv_run ok status >/dev/null; expect "status prints the journal" "yes" "$(grep -q '^state=failed' "$T/out" && echo yes)"

# ---------- SSH after a boot or a restart: tried again, for a while ----------
# (v340-m2 kill-pre: three Resumes failed with no cut-off: SSH let the Mac in once after the
# VM's boot, then not for a moment, and the next single call failed with a wrong reason.)
ssh_ready_try() {   # FLAKY SECONDS: ssh_ready's exit and SSH_WHY against the stand-in VM
  ( export PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_VM="$V" FAKE_MODE=ok FAKE_FLAKY="$1" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= OMACVM_SSH_PAUSE=0.2
    source "$A/scripts/vm-common.sh"; vm_load "$V" > /dev/null 2>&1
    "$A/runtime/bin/OmacVM" -serial "file:$T/ready-console.log" & q=$!
    sleep 0.5
    vssh true < /dev/null 2>/dev/null   # the VM's first word after its boot
    rc=0; ssh_ready "$2" 2>/dev/null || rc=$?
    echo "$rc ${SSH_WHY:-}"
    kill "$q" 2>/dev/null )
}
fresh
expect "ssh_ready: SSH back after 3 refusals: in (apply-vm.sh's first SSH)" "0 " "$(ssh_ready_try 3 30)"
expect "ssh_ready: never back: exit 1 within its time, ssh's own reason" "1 SSH closed the connection" "$(ssh_ready_try 9999 1 | cut -c1-27)"
expect "ssh_ready: no time given: one try, as before" "1" "$(ssh_ready_try 3 0 | cut -c1)"
expect "apply-vm.sh's first SSH uses it, with the time the caller gives" "yes" \
  "$(grep -q 'ssh_ready "${OMACVM_APPLY_SSH_SECONDS:-0}"' "$R/app/scripts/apply-vm.sh" && echo yes)"

fresh; rm -f "$T/apply-env.log"
mv_run ok run FAKE_FLAKY=3; rc=$?
expect "a VM whose SSH drops for a moment after each boot: the move goes to the end" "0 done" "$rc $(jget state)"
expect "... the move's apply waits for SSH too (120 s)" "120 120" "$(paste -sd' ' "$T/apply-env.log")"
fresh
mv_run cut-after-switch run
mv_run ok run FAKE_FLAKY=3; rc=$?
expect "a Resume that asks the VM, its SSH dropping after the boot: goes on to the end" "0 done" "$rc $(jget state)"
fresh
mv_run ok run FAKE_FLAKY=9999 OMACVM_MOVE_SSH_SECONDS=2; rc=$?
expect "SSH never back after the boot: failed at step 4, Resume, code ssh" "1 failed 4 1 ssh" "$rc $(jget state) $(jget failed_step) $(jget resumable) $(jget code)"
expect "... the reason is the real one (SSH), not 'no Omarchy move'" "yes" \
  "$(r=$(jget reason); [[ $r == *"does not answer over SSH"*"closed the connection"* && $r != *"no Omarchy move"* ]] && echo yes || echo "'$r'")"
mv_run ok run; rc=$?
expect "... Resume then: to the end" "0 done" "$rc $(jget state)"
fresh
mv_run cut-after-switch run
mv_run ok run FAKE_FLAKY=9999 OMACVM_MOVE_SSH_SECONDS=2; rc=$?
expect "a Resume, the VM silent after its boot: not decided (Resume asks again), the reason says SSH" "1 failed 4 1 yes" \
  "$rc $(jget state) $(jget failed_step) $(jget ask_guest) $(jget reason | grep -q 'over SSH' && echo yes)"
fresh
mv_run apply4-ssh run; rc=$?
expect "apply cannot reach the VM: its own words in the reason" "1 4 yes" \
  "$rc $(jget failed_step) $(jget reason | grep -q '^OmacVM did not update in the VM: Old does not answer over SSH' && echo yes || jget reason)"
fresh
t0=$(date +%s)
mv_run grub-restart run OMACVM_MOVE_BOOT_SECONDS=60; rc=$?
expect "the restart after the switch stops at GRUB's prompt: failed at step 6 at once, Undo only" "1 6 0 no-boot" \
  "$rc $(jget failed_step) $(jget resumable) $(jget code)"
expect "... within seconds" "1" "$(( $(date +%s) - t0 < 30 ))"

# ---------- Undo cut off: Undo again, never Resume ----------
# (the #725 review: an Undo cut off after the EFI vars went back left the journal at failed or
# interrupted, so Resume was offered on a backup without its efi-vars.fd.)
fresh
sum0=$(shasum "$V/disk.img" | cut -c1-40); efi0=$(cat "$V/efi-vars.fd")
mv_run net-download run
printf 'efi-moved' > "$V/efi-vars.fd"   # the move's VM changed the EFI vars
mv_run ok undo OMACVM_TEST_UNDO_STOP=disk; rc=$?
expect "Undo cut off before the disk (EFI vars back): the journal says undoing" "1 undoing" "$rc $(jget state)"
n_apply=$(wc -l < "$T/apply.log" | tr -d ' ')
mv_run ok run; rc=$?
expect "... Resume is refused at once (exit 3), no VM started, says Undo" "3 undoing $n_apply gone yes" \
  "$rc $(jget state) $(wc -l < "$T/apply.log" | tr -d ' ') $(qemu_gone) $(grep -q 'Undo' "$T/out" && echo yes)"
mv_run ok keep; rc=$?
expect "... Keep is refused" "3 undoing" "$rc $(jget state)"
mv_run ok delete-backup; rc=$?
expect "... Delete the backup is refused" "1 there" "$rc $([[ -d $V/before-omarchy-4.5 ]] && echo there)"
mv_run ok undo; rc=$?
expect "... Undo again: undone, the disk and the EFI vars from before" "0 undone $sum0 $efi0 gone" \
  "$rc $(jget state) $(shasum "$V/disk.img" | cut -c1-40) $(cat "$V/efi-vars.fd") $([[ -e $V/before-omarchy-4.5 ]] && echo there || echo gone)"
fresh
mv_run ok run
mv_run ok undo OMACVM_TEST_UNDO_STOP=disk; rc=$?
expect "Undo after a finished move, cut off: undoing (not 'done' with the records of 4.0)" "1 undoing" "$rc $(jget state)"
mv_run ok undo; rc=$?
expect "... Undo again: undone" "0 undone" "$rc $(jget state)"

# ---------- settle with a silent guest: the guest's own time for its switch ----------
# (the #725 review: a guest that did not answer got 180 s, then QEMU was ended: a switch
# still running is cut half way.)
crash_mid
: > "$T/guest/silent"; echo $(( $(date +%s) + 20 )) > "$T/guest/offat"   # the old ending came after ~12 s
t0=$(date +%s)
mv_run ok settle OMACVM_MOVE_SETTLE_SECONDS=1 OMACVM_MOVE_SWITCH_SECONDS=40; rc=$?
expect "settle, the guest silent from step 5 on: waits for its own shutdown, never ends it" "0 gone off-self" \
  "$rc $(oq_gone) $(grep -o off-self "$T/power.log" 2>/dev/null | head -1)"
expect "... the journal: interrupted, Resume asks the VM first" "interrupted 1" "$(jget state) $(jget ask_guest)"
crash_mid
: > "$T/guest/silent"; echo $(( $(date +%s) + 35 )) > "$T/guest/offat"
sed -i '' 's/^step=.*/step=4/; /^guest_state=/d; /^guest_phase=/d' "$V/move-4.5"
t0=$(date +%s)
mv_run ok settle OMACVM_MOVE_SETTLE_SECONDS=1 OMACVM_MOVE_SWITCH_SECONDS=40; rc=$?
expect "settle, silent before the guest's move began (step 4): the short wait, then ended" "0 gone none 1" \
  "$rc $(oq_gone) $(grep -o off-self "$T/power.log" 2>/dev/null | head -1 | grep . || echo none) $(( $(date +%s) - t0 < 30 ))"
rm -f "$T/guest/offat"
# A Resume whose script dies right after it sent start, before its first poll: the journal's
# guest_state is the earlier run's ("failed"), not this run's (the #725 review of 731897ad).
# The guest went on (into the switch) and is silent: settle must give it its own time.
fresh
mv_run net-download run
expect "stale state: the earlier run's last word is in the journal" "failed failed" "$(jget state) $(jget guest_state)"
: > "$T/out"; : > "$T/ssh.log"; rm -f "$T/power.log"
( mv_run ok run OMACVM_MOVE_POLL=30 ) & BG=$!
for ((i = 0; i < 300; i++)); do grep -q 'omarchy-move.sh start' "$T/ssh.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.5; p=$(jget pid); [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )) && kill -9 "$p"
wait "$BG" 2>/dev/null; BG=""; oq=$(cat "$T/qemu.pid")
expect "... killed right after start: step 5, no word of this run's guest in the journal" "5 -" "$(jget step) $(jget guest_state | grep . || echo -)"
: > "$T/guest/silent"; echo $(( $(date +%s) + 20 )) > "$T/guest/offat"
mv_run ok settle OMACVM_MOVE_SETTLE_SECONDS=1 OMACVM_MOVE_SWITCH_SECONDS=40; rc=$?
expect "... settle, the guest silent: waits for its own shutdown (never ends it), Resume asks the VM" "0 gone off-self 1" \
  "$rc $(oq_gone) $(grep -o off-self "$T/power.log" 2>/dev/null | head -1) $(jget ask_guest)"
rm -f "$T/guest/offat" "$T/guest/silent"

exit $fail
