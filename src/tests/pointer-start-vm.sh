#!/bin/bash
# The VM takes the pointer without a click (omacvm-cocoa-pointer-start.patch),
# in a real QEMU and guest: a throwaway OmacVM.app VM boots on a virtual Mac
# display (never the user's screens, never the focus), QEMU's test hook moves
# a made-up mouse over the window from the start and never clicks, and the
# guest must get that motion right after its start and after a reboot in it:
# Hyprland's pointer moves, the tablet sends positions and no button. The
# Mac's cursor (only logged in test mode) is hidden only after Omarchy's
# display agent said hello, and shown again from the reboot until its next
# hello. --off runs QEMU's own way (OMACVM_POINTER_START=0) and expects the
# pointer to stay put (the user's 15:00 report). --full: test-mode full
# screen (a borderless window over the virtual display).
#   src/tests/pointer-start-vm.sh --runtime DIR --vm DIR --ssh-port PORT [--full] [--off] [--no-reboot]
# DIR (vm): a COPY of an OmacVM.app VM made by omacvm apply (disk.img,
# efi-vars.fd; Mac-link features off); the test writes to it.
# --runtime: a QEMU runtime (bin/qemu-system-aarch64) with the pointer-start
# patch; the firmware is taken from --firmware or the app runtime's build.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
RT=""; VMD=""; PORT=""; FULL=off; OFF=0; REBOOT=1
FW=$R/app/runtime/.build/firmware/edk2-aarch64-code.fd
while (( $# )); do
  case $1 in
    --runtime) RT=$2; shift 2 ;;
    --vm) VMD=$2; shift 2 ;;
    --ssh-port) PORT=$2; shift 2 ;;
    --firmware) FW=$2; shift 2 ;;
    --full) FULL=on; shift ;;
    --off) OFF=1; shift ;;
    --no-reboot) REBOOT=0; shift ;;
    *) sed -n '12s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -x $RT/bin/qemu-system-aarch64 && -f $VMD/disk.img && -f $VMD/efi-vars.fd && $PORT =~ ^[0-9]+$ && -f $FW ]] ||
  { sed -n '12s/^# \{0,1\}//p' "$0" >&2; exit 2; }
[[ -e $HOME/.omacvm-user-testing ]] && { echo "pointer-start-vm: the user is testing: no VM (STANDARDS 18)" >&2; exit 1; }
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "pointer-start-vm: port $PORT is in use" >&2; exit 1; }

NAME="OmacVM T-pointer-start"
PAT="-name $NAME -machine"
W=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-pointer-start-vm.XXXXXX")
LOG=$VMD/qemu-pointer-start.log
VD_PID=""
cleanup() {
  pgrep -f -- "$PAT" >/dev/null && gssh "sync; systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -f -- "$PAT" >/dev/null || break; sleep 1; done
  pkill -f -- "$PAT" 2>/dev/null
  [[ -n $VD_PID ]] && kill "$VD_PID" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

gssh() {
  ssh -i "$HOME/.ssh/omacvm" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# A virtual display of our own (killing it unplugs it); every other display is left alone.
clang -fobjc-arc -framework Foundation -framework CoreGraphics \
  "$R/app/scripts/dev/virtual-display.m" -o "$W/virtual-display" || exit 1
"$W/virtual-display" 1440x900 --name "OmacVM pointer-start" > "$W/vd.out" 2>&1 &
VD_PID=$!
for _ in $(seq 40); do grep -q '^id=' "$W/vd.out" && break; sleep 0.25; done
VD=$(sed -n 's/^id=//p' "$W/vd.out")
[[ -n $VD ]] || { echo "pointer-start-vm: no virtual display" >&2; exit 1; }
sleep 2
SKIP=$(swift -e 'import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
print(ids[0..<Int(n)].map(String.init).joined(separator: ","))' 2>/dev/null | tr ',' '\n' | grep -vx "$VD" | paste -sd, -)
[[ -n $SKIP ]] || { echo "pointer-start-vm: could not list the Mac's displays" >&2; exit 1; }
echo "virtual display $VD; left alone: $SKIP; full screen: $FULL; pointer start: $( ((OFF)) && echo off || echo on)"

RUN=$W/run; mkdir -p "$RUN"
env OMACVM_PRODUCT_NAME="$NAME" OMACVM_SLIRP_HOST_PORTS=1 \
  OMACVM_TEST_SKIP_DISPLAYS="$SKIP" OMACVM_TEST_MAIN_DISPLAY="$VD" OMACVM_BACKGROUND=1 \
  OMACVM_TEST_POINTER=1800 OMACVM_DISPLAY_SOCKET="$RUN/display" \
  $( ((OFF)) && echo OMACVM_POINTER_START=0 ) \
  "$RT/bin/qemu-system-aarch64" -name "$NAME" -machine virt,gic-version=3 -accel hvf \
  -cpu host,pmu=off -smp 4,sockets=1,cores=4,threads=1 -m 8192M -nodefaults \
  -action reboot=reset,shutdown=poweroff \
  -drive "if=pflash,format=raw,readonly=on,file=$FW" \
  -drive "if=pflash,format=raw,file=$VMD/efi-vars.fd" \
  -drive "if=none,id=disk,file=$VMD/disk.img,format=raw,cache=writeback,discard=unmap" \
  -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
  -device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile= \
  -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=$FULL,full-grab=on,immersive=off,swap-opt-cmd=off" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -msg timestamp=on -serial none -monitor none \
  -device virtio-serial-pci,id=vser0 \
  -chardev "socket,id=disp0,path=$RUN/display,server=on,wait=off" \
  -device virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display \
  > "$LOG" 2>&1 &
start=$(date +%s)

# Hyprland up: the desktop user's session. No input is ever sent by this script.
wait_desktop() {
  local i
  for i in $(seq 120); do
    gssh 'ls /run/user/*/hypr/*/.socket.sock' >/dev/null 2>&1 && return 0
    pgrep -f -- "$PAT" >/dev/null || { echo "QEMU exited:" >&2; tail -5 "$LOG" >&2; return 1; }
    sleep 2
  done
  return 1
}
wait_desktop || { bad "no desktop within 4 minutes"; exit 1; }
echo "desktop up after $(( $(date +%s) - start )) s"
# STANDARDS 18a/25: nothing of this VM reaches the Mac (no clipboard port; Mac-link units off).
gssh 'for u in omacvm-gestures omacvm-notchcast; do systemctl disable --now $u >/dev/null 2>&1; done; true'

# What the guest sees: Hyprland's pointer three times, then 2 s of the tablet's events.
probe() {
  gssh 'bash -s' <<'GUEST'
source /etc/omacvm/env 2>/dev/null
U=${OMACVM_USER:-$(id -nu 1000)}; UID_=$(id -u "$U"); X=/run/user/$UID_
SIG=$(ls "$X/hypr" | head -1)
pos() { sudo -u "$U" env XDG_RUNTIME_DIR=$X HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl cursorpos 2>/dev/null; }
echo "pos $(pos)"; sleep 0.6; echo "pos $(pos)"; sleep 0.6; echo "pos $(pos)"
EV=$(awk '/^N: Name="QEMU Virtio Tablet"/{t=1} t && /^H: Handlers=/{for (i=1;i<=NF;i++) if ($i ~ /^event/) print $i; exit}' /proc/bus/input/devices)
python3 - "/dev/input/$EV" <<'PY'
import os, select, struct, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
abs_n = btn = 0
end = time.time() + 2
while time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        data = os.read(fd, 24 * 64)
        for i in range(0, len(data) - 23, 24):
            _, _, typ, code, val = struct.unpack("qqHHi", data[i:i + 24])
            abs_n += typ == 3
            btn += typ == 1
print("tablet abs", abs_n, "buttons", btn)
PY
GUEST
}

check_guest() {   # LABEL
  local out p1 p2 p3 abs btn
  out=$(probe)
  p1=$(sed -n '1s/^pos //p' <<<"$out"); p2=$(sed -n '2s/^pos //p' <<<"$out"); p3=$(sed -n '3s/^pos //p' <<<"$out")
  abs=$(awk '/^tablet/{print $3}' <<<"$out"); btn=$(awk '/^tablet/{print $5}' <<<"$out")
  echo "$1: Hyprland's pointer $p1 -> $p2 -> $p3; tablet: ${abs:-?} positions, ${btn:-?} buttons in 2 s"
  if ((OFF)); then
    [[ -n $p1 && $p1 == "$p2" && $p2 == "$p3" ]] && ok "$1: QEMU's own way: the pointer stays put without a click" ||
      bad "$1: QEMU's own way: the pointer moved without a click ($p1, $p2, $p3)"
    [[ ${abs:-0} == 0 ]] && ok "$1: QEMU's own way: no positions reach the guest" || bad "$1: QEMU's own way: $abs positions"
  else
    [[ -n $p1 && $p1 != "$p2" && $p2 != "$p3" ]] && ok "$1: the pointer moves without a click" ||
      bad "$1: the pointer did not move ($p1, $p2, $p3)"
    (( ${abs:-0} > 0 )) && ok "$1: the guest's tablet gets positions ($abs in 2 s)" || bad "$1: no positions in the guest"
  fi
  [[ ${btn:-x} == 0 ]] && ok "$1: no button event (no click)" || bad "$1: button events: ${btn:-?}"
}

check_log() {   # LABEL HELLOS: the Mac's cursor is hidden only after hello number HELLOS
  local seq
  seq=$(grep -oE 'omacvm-pointer: Mac cursor (hidden|shown)|cocoa: the guest draws its own pointer now|omacvm-pointer: taken \([^)]*\)' "$LOG" |
        sed -E 's/omacvm-pointer: Mac cursor /cursor-/; s/cocoa: the guest draws its own pointer now/hello/; s/omacvm-pointer: taken \((.*)\)/take:\1/' |
        tr '\n' ' ')
  echo "$1: QEMU: $seq"
  if ((OFF)); then
    grep -q 'cocoa: pointer: taken on enter or click' "$LOG" && ok "$1: QEMU says it takes the pointer QEMU's way" ||
      bad "$1: no 'taken on enter or click' line"
    return
  fi
  grep -q 'cocoa: pointer: taken without a click' "$LOG" && ok "$1: QEMU says it takes the pointer without a click" ||
    bad "$1: no 'taken without a click' line"
  grep -q 'omacvm-pointer: taken (motion over the VM)' "$LOG" && ok "$1: the first motion over the VM took it" ||
    bad "$1: no take on motion"
  # The first "hidden" comes after the first hello (the reboot's order is checked on its own).
  python3 - "$2" <<PY && ok "$1: the Mac's cursor hides only once the guest draws its pointer ($2 hello)" || bad "$1: the Mac's cursor hid with no guest pointer"
import sys
seq = """$seq""".split(); hellos = int(sys.argv[1])
first_hidden = seq.index("cursor-hidden") if "cursor-hidden" in seq else -1
first_hello = seq.index("hello") if "hello" in seq else -1
sys.exit(0 if 0 <= first_hello < first_hidden and seq.count("hello") >= hellos
         and seq.count("cursor-hidden") >= hellos else 1)
PY
}

sleep 3
check_guest "start"
check_log "start" 1

if ((REBOOT)); then
  before=$(grep -c 'cocoa: the guest draws its own pointer now' "$LOG")
  gssh 'systemctl reboot' >/dev/null 2>&1
  sleep 15
  wait_desktop || { bad "no desktop after the reboot"; exit 1; }
  for _ in $(seq 30); do (( $(grep -c 'cocoa: the guest draws its own pointer now' "$LOG") > before )) && break; sleep 1; done
  gssh 'for u in omacvm-gestures omacvm-notchcast; do systemctl disable --now $u >/dev/null 2>&1; done; true'
  sleep 3
  check_guest "after a reboot"
  if ! ((OFF)); then
    # The reset shows the Mac's cursor (the guest draws none) until the next hello hides it again.
    tail -n +"$(grep -n 'cocoa: the guest draws its own pointer now' "$LOG" | sed -n "${before}p" | cut -d: -f1)" "$LOG" |
      grep -oE 'omacvm-pointer: Mac cursor (hidden|shown)|cocoa: the guest draws its own pointer now' | tr '\n' '|' > "$W/after"
    grep -q 'Mac cursor shown|cocoa: the guest draws its own pointer now|omacvm-pointer: Mac cursor hidden' "$W/after" &&
      ok "after a reboot: the Mac's cursor shown while it booted, hidden again at its hello" ||
      bad "after a reboot: cursor sequence $(cat "$W/after")"
    check_log "after a reboot" 2
  fi
fi

((fail)) && { echo "pointer-start-vm: FAILED (QEMU log: $LOG)"; exit 1; }
echo "pointer-start-vm: all ok"
