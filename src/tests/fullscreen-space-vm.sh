#!/bin/bash
# Live check: OmacVM.app's QEMU in full screen has a Space of its own on each
# display, and the escape combo's move out of it stays out (no jump back).
# Two virtual displays (the Mac's own displays are left alone), a copy of a
# VM, real macOS full screen on both (main window on the first, Virtual-2 on
# the second). Then:
#   1. each display's current Space is a full-screen Space (type 4) holding the
#      VM's window and no other app's window;
#   2. what OmacVM Gestures does for Ctrl+Option+Esc (macOS's "Move left a
#      space", marked, on the main window's display) moves that display off
#      the VM's Space, and for 3 s it stays off (before the fix: back at once).
# The real combo cannot be posted (Gestures ignores posted combos on purpose):
# the move is posted as Gestures posts it. Needs a Mac whose "Displays have
# separate Spaces" is on, the shell's Accessibility (to post keys), a VM with
# the guest's display agent (OmacVM.app VM), and the VM lock of the Mac it
# runs on. Not on a Mac someone is working at: it shows the VM and moves the
# pointer for a moment.
#   src/tests/fullscreen-space-vm.sh --runtime DIR --firmware FD --vm DIR --ssh-port N [--qemu PATH]
# --qemu: start QEMU by this path, e.g. an app's Contents/MacOS/OmacVM-VM, as
# OmacVM.app starts it since 3.0.1 (QEMU then counts as the app, one Dock icon).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
RT=""; VMD=""; PORT=""; FW=""; QEXE=""
while (( $# )); do
  case $1 in
    --runtime) RT=$2; shift 2 ;;
    --firmware) FW=$2; shift 2 ;;
    --vm) VMD=$2; shift 2 ;;
    --ssh-port) PORT=$2; shift 2 ;;
    --qemu) QEXE=$2; shift 2 ;;
    *) sed -n '18,20s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
QEMU=$RT/bin/qemu-system-aarch64; [[ -x $QEMU ]] || QEMU=$RT/bin/OmacVM
[[ -n $QEXE ]] && QEMU=$QEXE
[[ -x $QEMU && -f $VMD/disk.img && -f $VMD/efi-vars.fd && $PORT =~ ^[0-9]+$ && -f $FW ]] ||
  { sed -n '18,20s/^# \{0,1\}//p' "$0" >&2; exit 2; }
[[ -e $HOME/.omacvm-user-testing ]] && { echo "fullscreen-space-vm: the user is testing: no VM (STANDARDS 18)" >&2; exit 1; }

NAME="OmacVM T-fullscreen-space"
PAT="-name $NAME -machine"
W=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fs-space-vm.XXXXXX")
LOG=$VMD/qemu-fullscreen-space.log
gssh() {
  ssh -i "$HOME/.ssh/omacvm" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
cleanup() {
  pgrep -f -- "$PAT" >/dev/null && gssh "sync; systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -f -- "$PAT" >/dev/null || break; sleep 1; done
  pkill -f -- "$PAT" 2>/dev/null
  # vd runs in $(...): its pids come from files (an array set there stays there).
  cat "$W"/*.vd-pid 2>/dev/null | xargs kill 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

swiftc -O -o "$W/spaces" "$R/src/tests/fullscreen-space/spaces.swift" 2>"$W/swiftc.err" ||
  { cat "$W/swiftc.err" >&2; exit 1; }
clang -fobjc-arc -framework Foundation -framework CoreGraphics \
  "$R/app/scripts/dev/virtual-display.m" -o "$W/virtual-display" || exit 1
vd() {   # NAME SIZE AT -> display id (a new identity each run: pid as serial)
  "$W/virtual-display" "$2" --at "$3" --name "$1" > "$W/$1.out" 2>&1 &
  echo $! > "$W/$1.vd-pid"
  for _ in $(seq 40); do grep -q '^id=' "$W/$1.out" && break; sleep 0.25; done
  sed -n 's/^id=//p' "$W/$1.out"
}
D1=$(vd fs-space-1 1440x900 -3000,-2000); D2=$(vd fs-space-2 1280x800 -1500,-2000)
[[ -n $D1 && -n $D2 ]] || { echo "fullscreen-space-vm: no virtual displays" >&2; exit 1; }
sleep 2
echo "virtual displays: $D1 (main window), $D2 (Virtual-2)"

RUN=$W/run; mkdir -p "$RUN"
env OMACVM_PRODUCT_NAME="$NAME" OMACVM_SLIRP_HOST_PORTS=1 \
  OMACVM_TEST_MAIN_DISPLAY="$D1" OMACVM_TEST_ONLY_DISPLAYS="$D1,$D2" OMACVM_DISPLAY_SOCKET="$RUN/display" \
  "$QEMU" -name "$NAME" -machine virt,gic-version=3 -accel hvf \
  -cpu host,pmu=off -smp 4,sockets=1,cores=4,threads=1 -m 6144M -nodefaults \
  -action reboot=reset,shutdown=poweroff \
  -drive "if=pflash,format=raw,readonly=on,file=$FW" \
  -drive "if=pflash,format=raw,file=$VMD/efi-vars.fd" \
  -drive "if=none,id=disk,file=$VMD/disk.img,format=raw,cache=writeback,discard=unmap" \
  -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
  -device virtio-gpu-gl-pci,max_outputs=2,xres=1920,yres=1080,romfile= \
  -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=on,full-grab=on,immersive=on,swap-opt-cmd=off" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -msg timestamp=on -serial none -monitor none \
  -device virtio-serial-pci,id=vser0 \
  -chardev "socket,id=disp0,path=$RUN/display,server=on,wait=off" \
  -device virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display \
  > "$LOG" 2>&1 &
QPID=$!

# 1. Own Space: the main window at once, Virtual-2 once the guest's display agent turns it on.
own_space() {   # DISPLAY WHAT SECONDS
  local s
  for _ in $(seq "$3"); do
    s=$("$W/spaces" state "$1" "$QPID")
    [[ $s == *" type=4 "* && $s != *" vm_windows=0 "* && $s == *" others=0 "* ]] && { ok "$2: own full-screen Space ($s)"; return 0; }
    kill -0 "$QPID" 2>/dev/null || { bad "$2: QEMU exited"; tail -5 "$LOG"; return 1; }
    sleep 1
  done
  bad "$2: no full-screen Space of its own ($s)"
}
own_space "$D1" "main window" 30
for _ in $(seq 120); do gssh true 2>/dev/null && break; sleep 2; done
# The Mac's helper ports are closed to this VM (OMACVM_SLIRP_HOST_PORTS=1); Gestures off in it too.
gssh 'systemctl disable --now omacvm-gestures >/dev/null 2>&1; true'
own_space "$D2" "Virtual-2 window" 90

# 2. The escape combo's move out of the main window's Space, and no jump back.
vm=$("$W/spaces" state "$D1" "$QPID" | sed -n 's/^space=\([0-9]*\).*/\1/p')
"$W/spaces" watch "$D1" 4 > "$W/watch" &
WP=$!
sleep 0.3
"$W/spaces" left "$D1"
wait "$WP"
sed 's/^/     /' "$W/watch"
last=$(tail -1 "$W/watch" | sed -n 's/.*space=\([0-9]*\).*/\1/p')
backs=$(awk -v vm="$vm" '{ split($2, a, "="); if (a[2] == vm) n++ } END { print n + 0 }' "$W/watch")
if [[ $last != "$vm" && $backs -le 1 ]]; then ok "the escape combo's move left the VM's Space and stayed out"
else bad "the display came back to the VM's Space (VM Space $vm, last $last, times on it $backs)"; fi
exit $fail
