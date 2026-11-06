#!/bin/bash
# OmacVM.app's "Move to Omarchy 4.5" (app/scripts/move-vm.sh) without a VM:
# a stand-in QEMU, ssh (the guest's omarchy-move.sh as work/v340/contract.md
# has it) and apply in a fixture app, a VM folder with a small disk.img.
# The Mac's checks, the backup (APFS clones and the records), a move to the
# end, Delete the backup, Undo (the disk byte for byte as before), a network
# failure and its Resume, a refusal, a failure inside the package switch
# (Undo only), Stop and Quit and its Resume, a killed run (power cut) and
# its Resume, Keep This Disk, and src/lib/omarchy-move.sh (apply and update
# leave a VM in the middle of its move alone; the guest's record line).
#   src/tests/app-move-vm.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
VMID() { printf '%s' "$1" | shasum | cut -c1-8; }
cleanup() {
  [[ -f $T/qemu.pid ]] && kill "$(cat "$T/qemu.pid")" 2>/dev/null
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
for s in running failed interrupted done kept undone done-final; do
  printf 'format=1\nstate=%s\n' "$s" > "$T/lib/move-4.5"
  case $s in running|failed|interrupted) want=open ;; *) want=over ;; esac
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
: > "$console"
while :; do sleep 1; done
QEMU
cat > "$T/bin/ssh" <<'SSH'
#!/bin/bash
# Stand-in ssh: the VM, and in it omarchy-move.sh as the contract has it.
# Its state is in $FAKE_DIR/guest/ (it survives the VM's restarts, as a disk does).
G=$FAKE_DIR/guest
kill -0 "$(cat "$FAKE_DIR/qemu.pid" 2>/dev/null)" 2>/dev/null || exit 255
cmd=${*: -1}
echo "$cmd" >> "$FAKE_DIR/ssh.log"
phases=(preflight protect initramfs keyring repos download commit platform mpv vulkan kernel update report)
json() {   # state phase index commit resumable code reason
  printf '{"format":1,"state":"%s","phase":"%s","phase_index":%s,"phases":[],"commit_started":%s,"resumable":%s,"started":"","finished":"","code":"%s","reason":"%s","omarchy":"4.0.3rc4","lane":"omarchy-mac","channel":"rc","log":"/var/log/omacvm-move-45.log","result":null}\n' "$@"
}
case $cmd in
  true)
    # Once after a reboot: the old system is gone for a moment.
    if [[ -e $G/rebooting ]]; then rm -f "$G/rebooting"; exit 255; fi
    exit 0 ;;
  "systemctl poweroff") (sleep 1; kill "$(cat "$FAKE_DIR/qemu.pid")") & exit 0 ;;
  "systemctl reboot") : > "$G/rebooting"; exit 0 ;;
  "test -x "*omarchy-move.sh) [[ $FAKE_MODE == guest-old ]] && exit 1; exit 0 ;;
  *"systemctl --failed"*) echo 0; exit 0 ;;
  "cat /var/log/omacvm-move-45.log") echo "guest log"; exit 0 ;;
  *"omarchy-move.sh preflight --json")
    case $FAKE_MODE in
      net) printf '{"format":1,"ok":false,"code":"repos-unreachable","reason":"pkgs.omarchy.org did not answer."}\n'; exit 4 ;;
      refuse) printf '{"format":1,"ok":false,"code":"apple-platform","reason":"This VM says it is an Apple machine."}\n'; exit 3 ;;
      moved) printf '{"format":1,"ok":false,"code":"already-moved","reason":"On 4.5 already."}\n'; exit 3 ;;
    esac
    printf '{"format":1,"ok":true,"code":"","reason":"","omarchy":"4.0.3rc4","lane":"omarchy-mac","channel":"rc","target":{"omarchy":"4.5.0","channel":"stable"},"checks":[]}\n'
    exit 0 ;;
  *"omarchy-move.sh start")
    [[ -f $G/state ]] && [[ $(cat "$G/state") == done ]] && exit 0
    echo running > "$G/state"; rm -f "$G/stop"; [[ -f $G/i ]] || echo 0 > "$G/i"
    exit 0 ;;
  *"omarchy-move.sh stop") : > "$G/stop"; exit 0 ;;
  *"omarchy-move.sh record")
    [[ $(cat "$G/state" 2>/dev/null) == done ]] && echo "4.5.0 aarch64 stable" || echo "4.0.3rc4 omarchy-mac rc"; exit 0 ;;
  *"omarchy-move.sh status --json")
    st=$(cat "$G/state" 2>/dev/null || echo none); i=$(cat "$G/i" 2>/dev/null || echo 0)
    c=false; (( i >= 6 )) && c=true
    if [[ $st == running ]]; then
      ph=${phases[$i]}
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
    json "$st" report 13 $c true "" ""
    exit 0 ;;
esac
exit 0
SSH
cat > "$A/scripts/apply-vm.sh" <<'APPLY'
#!/bin/bash
echo "${OMACVM_KERNEL_NEW:-unset} ${OMACVM_MOVE_RUN:-unset}" >> "$FAKE_DIR/apply.log"
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
  rm -f "$T/qemu.pid"
  env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_VM="$V" FAKE_MODE="$mode" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= OMACVM_MOVE_POLL=0.2 "$@" \
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
expect "run: the guest's parts said as they come" "yes" "$(grep -q '==> downloading packages (part 6 of 13)' "$T/out" && grep -q "==> switching the packages" "$T/out" && echo yes)"
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
expect "Keep This Disk: kept, the backup stays" "0 kept there" "$rc $(jget state) $([[ -d $V/before-omarchy-4.5 ]] && echo there)"
mv_run ok delete-backup; rc=$?
expect "... then Delete the backup" "0 done-final" "$rc $(jget state)"

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
for ((i = 0; i < 100; i++)); do grep -q 'downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
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
for ((i = 0; i < 100; i++)); do grep -q 'downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
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
for ((i = 0; i < 100; i++)); do grep -q 'downloading packages' "$T/out" 2>/dev/null && break; sleep 0.2; done
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

# ---------- a guest without omarchy-move.sh ----------
fresh
mv_run guest-old run; rc=$?
expect "a guest without the move: failed at step 4, Resume" "1 failed 4 guest-old" "$rc $(jget state) $(jget failed_step) $(jget code)"
mv_run ok status >/dev/null; expect "status prints the journal" "yes" "$(grep -q '^state=failed' "$T/out" && echo yes)"

exit $fail
