#!/bin/bash
# Drag and drop of files into a hidden test VM (feature drag-drop; docs/drag-and-drop.md), with nobody
# at the Mac: QEMU's drop path from the window's code on, the app's side (drop-serve = OmacVMDrop's
# DropServer, the code the app runs), the read-only share, the VM's omacvm-drop and its helper.
# What a person does on screen (the Finder drag onto the window, the pointer following it) is not
# here: QEMU's test hook (OMACVM_DROP_TEST=1) takes a "test-drop" line from the app's side and runs
# what performDragOperation runs after the pasteboard (the checks, opening off the main thread, the
# open files to the app). The VM's pointer is put where a drag would leave it with QMP's tablet.
#
#   drag-drop.sh WORK APP BASE_VM DROP_SERVE
#     WORK        an empty folder of this run (clone, logs, run sockets); kept: out/
#     APP         the test app (its QEMU and firmware), org.omacvm.app.test
#     BASE_VM     a test VM folder (disk.img, efi-vars.fd, ssh-key) with a desktop user logged in at boot
#     DROP_SERVE  app/app's drop-serve binary (swift build --product drop-serve)
#
# Rows (one "ROW name: PASS|FAIL detail" line each in WORK/out/rows.txt):
#   gating      before the VM's omacvm-drop says hello, QEMU takes no drop and nothing is staged
#   install     the VM step (src/drop/guest/install.sh on): helper built, share mounted ro, status ok
#   ready       QEMU is told ready once the VM's service says hello
#   app         a drop over a test window: it gets one text/uri-list drop of both files, names
#               percent-encoded; the app's log says "the app under the pointer"
#   nautilus    a drop over Nautilus: it copies both files into the folder it shows, sha256 equal
#   downloads   a drop over the empty desktop: the files land in ~/Downloads (sha256 equal), a
#               name there gets " (2)", the drop's staging on the Mac is gone
#   late        a drop held 2 s on the Mac: Downloads, not the app under the pointer
#   limits      257 files and a folder: refused by QEMU, nothing staged; a 200 MB file intact
#   readonly    the share refuses writes in the VM
#   speed       a 1 GiB drop into Downloads: seconds from the drop to the VM's answer
#   off         the same VM started without the switch: no port, no share, no socket, the service
#               idle (an app without drag and drop and a VM with it), nothing in qemu.log
# Exit 0 when every row passes. Bash 3.2 (macOS).
set -uo pipefail
export LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin
[[ $# == 4 ]] || { echo "usage: drag-drop.sh WORK APP BASE_VM DROP_SERVE" >&2; exit 2; }
W=$1 APP=$2 BASE=$3 SERVE=$4
R=$(cd "$(dirname "$0")/../.." && pwd -P)
OUT=$W/out RUN=$W/run VMD=$W/vm ST=$W/vm/drop SRC=$W/files
QEMU="$APP/Contents/MacOS/OmacVM-VM" FW="$APP/Contents/Resources/firmware/edk2-aarch64-code.fd"
NAME="OmacVM T-dnd" PORT=52885 GUSER=""
mkdir -p "$OUT" && : > "$OUT/rows.txt"
[[ -x $QEMU && -f $FW && -x $SERVE && -f $BASE/disk.img ]] || { echo "missing app, firmware, drop-serve or VM" >&2; exit 2; }
[[ -z $(ls -A "$W" | grep -v '^out$') ]] || { echo "WORK must be empty (but out/)" >&2; exit 2; }
fails=0
log() { echo "$(date +%H:%M:%S) $*" >> "$OUT/run.log"; }
row() { echo "ROW $1: $2${3:+ $3}" >> "$OUT/rows.txt"; log "ROW $1: $2${3:+ $3}"; [[ $2 == PASS ]] || fails=$((fails + 1)); }
qpid() { pgrep -f -- "-name $NAME," | head -1; }
gssh() {
  ssh -i "$VMD/ssh-key" -o IdentitiesOnly=yes -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@" < /dev/null
}
guser() {
  gssh "U=$GUSER; R=/run/user/\$(id -u \$U); H=\$(ls -t \$R/hypr 2>/dev/null | head -1); W=\$(ls \$R 2>/dev/null | grep -m1 '^wayland-[0-9]*\$'); cd /tmp; runuser -u \$U -- env HOME=/home/\$U USER=\$U XDG_RUNTIME_DIR=\$R DBUS_SESSION_BUS_ADDRESS=unix:path=\$R/bus HYPRLAND_INSTANCE_SIGNATURE=\$H WAYLAND_DISPLAY=\${W:-wayland-1} bash -lc $(printf %q "$1")"
}
sum() { shasum -a 256 "$1" | cut -c1-16; }
serve_pid=""
stop_vm() {
  local P; P=$(qpid); [[ -n $P ]] || return 0
  gssh "sync; systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 60); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
  kill -0 "$P" 2>/dev/null && { kill "$P"; sleep 3; }
  kill -0 "$P" 2>/dev/null && kill -9 "$P"
  log "VM stopped"
}
stop_serve() {
  exec 7>&- 2>/dev/null
  [[ -n $serve_pid ]] && { kill "$serve_pid" 2>/dev/null; wait "$serve_pid" 2>/dev/null; }
  serve_pid=""
}
finish() {
  stop_serve; stop_vm
  [[ -d $VMD && ! -L $VMD && -z $(qpid) ]] && rm -rf "$VMD" "$SRC" "$RUN" && log "clone, files and run folder deleted"
  log "end: $fails failed"
}
trap finish EXIT
trap 'exit 143' TERM INT HUP

# The Mac's files: names with spaces, # and %; 200 MB; 1 GiB; 257 small ones; a folder.
mkdir -p "$SRC/many" "$SRC/dir"
printf 'hello from the Mac\n' > "$SRC/hello.txt"
printf 'second file\n' > "$SRC/a b #50%.txt"
head -c 209715200 /dev/urandom > "$SRC/big.bin"
head -c 1073741824 /dev/urandom > "$SRC/huge.bin"
for i in $(seq 257); do printf '%s' "$i" > "$SRC/many/f$i"; done
mkdir -p "$VMD" "$RUN" && chmod 700 "$RUN"
cp -c "$BASE/disk.img" "$BASE/efi-vars.fd" "$BASE/ssh-key" "$VMD/" || { log "clone failed"; exit 1; }
chmod 600 "$VMD/ssh-key"
mkdir -p "$ST" && chmod 700 "$ST"
GUSER=$(sed -n 's/^OMACVM_USER=//p' "$BASE/vm.env" 2>/dev/null | tr -d '"'); GUSER=${GUSER:-omtest}
log "clone of $(basename "$BASE"), user $GUSER, app $(/usr/libexec/PlistBuddy -c 'Print OmacVMCommit' "$APP/Contents/Info.plist" 2>/dev/null)"

# on|off: QEMU as the app starts it (the drop's port and share last), hidden, slirp restricted.
start_qemu() {
  local mode=$1 extra=() envs=()
  rm -f "$RUN/qmp" "$RUN/dropp" "$OUT/qemu-$mode.log"
  if [[ $mode == on ]]; then
    extra=(-chardev "socket,id=drop0,path=$RUN/dropp,server=on,wait=off"
           -device "virtserialport,bus=vser0.0,nr=10,chardev=drop0,name=org.omacvm.drop"
           -fsdev "local,id=dropfs,path=$ST,security_model=none,readonly=on,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000"
           -device "virtio-9p-pci,fsdev=dropfs,mount_tag=omacvm-drop")
    envs=(OMACVM_DROP_SOCKET="$RUN/drop" OMACVM_DROP_TEST=1)
  fi
  ( export OMACVM_PRODUCT_NAME="$NAME" OMACVM_NOTCH=0 OMACVM_COCOA_HIDDEN=1 ${envs[@]+"${envs[@]}"}
    exec "$QEMU" -name "$NAME,debug-threads=on" -machine virt,gic-version=3 -accel hvf \
    -cpu host,pmu=off -smp "4,sockets=1,cores=4,threads=1" -m 3072M -nodefaults \
    -action reboot=reset,shutdown=poweroff -boot menu=on,splash-time=0 \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" -drive "if=pflash,format=raw,file=$VMD/efi-vars.fd" \
    -drive "if=none,id=disk,file=$VMD/disk.img,format=raw,cache=writeback,discard=unmap" \
    -device nvme,serial=omacvm,drive=disk,bootindex=0 \
    -netdev "user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device "virtio-gpu-gl-pci,max_outputs=1,xres=2560,yres=1440,romfile=,blob=true" \
    -display "cocoa,gl=on,show-cursor=off,zoom-to-fit=on,full-screen=off,full-grab=off,immersive=off,swap-opt-cmd=off" \
    -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -device virtio-serial-pci,id=vser0 ${extra[@]+"${extra[@]}"} \
    -msg timestamp=on -serial none -monitor none -qmp "unix:$RUN/qmp,server=on,wait=off" \
    > "$OUT/qemu-$mode.log" 2>&1 < /dev/null ) &
  sleep 3
  qpid > "$RUN/qemu.pid"
  log "QEMU ($mode) pid $(cat "$RUN/qemu.pid")"
  local up=""
  for _ in $(seq 90); do gssh true 2>/dev/null && { up=1; break; }; sleep 2; done
  [[ -n $up ]] || { log "no ssh in 180 s"; return 1; }
  for _ in $(seq 60); do [[ -n $(guser 'hyprctl monitors -j 2>/dev/null | grep -m1 name') ]] && break; sleep 2; done
  sleep 3
}

# The VM's pointer to logical X Y on its output, through QEMU's tablet (as a drag over the window).
point() {
  /usr/bin/python3 -I - "$RUN/qmp" "$1" "$2" "$SIZE" <<'PY'
import json, socket, sys
path, x, y, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4].split()
w, h = int(size[0]), int(size[1])
s = socket.socket(socket.AF_UNIX); s.connect(path); f = s.makefile("rw")
f.readline()
def cmd(o):
    f.write(json.dumps(o) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd({"execute": "qmp_capabilities"})
ev = [{"type": "abs", "data": {"axis": "x", "value": round(x / w * 32767)}},
      {"type": "abs", "data": {"axis": "y", "value": round(y / h * 32767)}}]
print(cmd({"execute": "input-send-event", "arguments": {"events": ev}}))
PY
  sleep 0.4
}

serve_log() { cat "$OUT/serve.log" 2>/dev/null; }
drop() { printf 'drop %s\n' "$(IFS=$'\t'; echo "$*")" >&7; }
staged() { find "$ST" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
wait_for() {  # FILE TEXT SECONDS: 0 once TEXT is in FILE
  local i; for i in $(seq $(( $3 * 4 ))); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done; return 1
}
count() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null); echo "${n:-0}"; }

# --- on -------------------------------------------------------------------------------------------
rm -f "$RUN/in"; mkfifo "$RUN/in"
"$SERVE" "$RUN/drop" "$RUN/dropp" "$ST" "$RUN/qemu.pid" < "$RUN/in" > "$OUT/serve.log" 2>&1 &
serve_pid=$!
exec 7> "$RUN/in"
wait_for "$OUT/serve.log" "drop-serve: listening" 10 || { log "drop-serve did not start"; exit 1; }
start_qemu on || exit 1
gssh "rm -rf /tmp/dnd && mkdir -p /tmp/dnd && tar -C /tmp/dnd -xf - && chown -R $GUSER /tmp/dnd" < "$W/guest.tar" 2>> "$OUT/run.log" ||
  { log "guest files not copied"; exit 1; }
SIZE=$(guser "bash /tmp/dnd/guest-rows.sh size")
log "guest: $(gssh 'uname -r; pacman -Q hyprland nautilus 2>&1' | tr '\n' ' ') output $SIZE"

# gating: QEMU connected, the VM's service not there yet.
wait_for "$OUT/qemu-on.log" "omacvm-drop: on" 10
q0=$(count "$OUT/qemu-on.log" "omacvm-drop: refused")
drop "$SRC/hello.txt"; sleep 2
if [[ $(count "$OUT/qemu-on.log" "omacvm-drop: refused") -gt $q0 && $(staged) == 0 ]] && grep -q "has not answered" "$OUT/qemu-on.log"; then
  row gating PASS "($(grep -m1 'omacvm-drop: refused' "$OUT/qemu-on.log" | sed 's/.*omacvm-drop: //'))"
else row gating FAIL "(qemu: $(grep 'omacvm-drop' "$OUT/qemu-on.log" | tail -2 | tr '\n' ' '); staged $(staged))"; fi

# install: the VM step as apply runs it.
gssh "bash /tmp/dnd/drop/guest/install.sh $GUSER on" >> "$OUT/run.log" 2>&1
st=$(gssh "bash /tmp/dnd/drop/guest/install.sh $GUSER --status; findmnt -n -o OPTIONS /run/omacvm/drop | cut -d, -f1")
if [[ $st == "ok "*$'\n'ro ]]; then row install PASS "($(tr '\n' ' ' <<<"$st"))"; else row install FAIL "($(tr '\n' ' ' <<<"$st"))"; fi

# ready: the service's hello.
if wait_for "$OUT/serve.log" "drag and drop: ready" 30 && wait_for "$OUT/qemu-on.log" "omacvm-drop: ready" 5; then row ready PASS
else row ready FAIL "($(tail -3 "$OUT/serve.log" | tr '\n' ' '))"; fi

# app: a test window under the pointer.
xy=$(guser "bash /tmp/dnd/guest-rows.sh window")
point $xy >> "$OUT/run.log"
n0=$(count "$OUT/serve.log" "the app under the pointer")
drop "$SRC/hello.txt" "$SRC/a b #50%.txt"
wait_for "$OUT/serve.log" "the app under the pointer" 15; sleep 1
d=$(guser "bash /tmp/dnd/guest-rows.sh window-drops")
uris=$(guser "cat /tmp/dnd/dst.txt")
if [[ $(count "$OUT/serve.log" "the app under the pointer") -gt $n0 && $d == drops=1* && $uris == *"a%20b%20%2350%25.txt"* ]]; then
  row app PASS "(window at $xy; $(guser "bash /tmp/dnd/guest-rows.sh cursor"); $d)"
else row app FAIL "(window at $xy; $d; serve: $(tail -2 "$OUT/serve.log" | tr '\n' ' '))"; fi
guser "bash /tmp/dnd/guest-rows.sh window-close" > /dev/null

# nautilus: copies into the folder it shows.
xy=$(guser "bash /tmp/dnd/guest-rows.sh nautilus /home/$GUSER/dndtest")
point $xy >> "$OUT/run.log"
drop "$SRC/big.bin" "$SRC/a b #50%.txt"
sleep 10
l=$(guser "bash /tmp/dnd/guest-rows.sh ls /home/$GUSER/dndtest")
if grep -q "^$(sum "$SRC/big.bin") 209715200 big.bin$" <<<"$l" && grep -q "^$(sum "$SRC/a b #50%.txt") .* a b #50%.txt$" <<<"$l"; then
  row nautilus PASS "(at $xy: $(tr '\n' ';' <<<"$l"))"
else row nautilus FAIL "(at $xy: $(tr '\n' ';' <<<"$l"); serve: $(tail -2 "$OUT/serve.log" | tr '\n' ' '))"; fi
guser "bash /tmp/dnd/guest-rows.sh nautilus-close; rm -rf ~/dndtest" > /dev/null

# downloads: nothing under the pointer takes files.
guser 'd=$(xdg-user-dir DOWNLOAD 2>/dev/null); rm -f "${d:-$HOME/Downloads}"/hello*.txt; echo mine > "${d:-$HOME/Downloads}/hello.txt"' > /dev/null
xy=$(guser "bash /tmp/dnd/guest-rows.sh desktop")
point $xy >> "$OUT/run.log"
before=$(staged)
n0=$(count "$OUT/serve.log" "in the VM: Downloads")
drop "$SRC/hello.txt"
wait_for "$OUT/serve.log" "in the VM: Downloads" 15; sleep 1
l=$(guser 'bash /tmp/dnd/guest-rows.sh ls "$(xdg-user-dir DOWNLOAD 2>/dev/null || echo ~/Downloads)"')
if [[ $(count "$OUT/serve.log" "in the VM: Downloads") -gt $n0 ]] && grep -q "^$(sum "$SRC/hello.txt") .* hello (2).txt$" <<<"$l" &&
   grep -q " hello.txt$" <<<"$l" && [[ $(staged) == "$before" ]]; then
  row downloads PASS "(at $xy; $(grep 'in the VM: Downloads' "$OUT/serve.log" | tail -1 | sed 's/.*in the VM: //'); staging gone)"
else row downloads FAIL "($(tr '\n' ';' <<<"$l"); staged $before -> $(staged); serve: $(tail -2 "$OUT/serve.log" | tr '\n' ' '))"; fi

# late: held 2 s on the Mac: Downloads even over a window.
xy=$(guser "bash /tmp/dnd/guest-rows.sh window"); point $xy >> "$OUT/run.log"
echo "delay 2000" >&7
n0=$(count "$OUT/serve.log" "(late")
drop "$SRC/hello.txt"
wait_for "$OUT/serve.log" "(late" 20; sleep 1
d=$(guser "bash /tmp/dnd/guest-rows.sh window-drops")
if [[ $(count "$OUT/serve.log" "(late") -gt $n0 && $d == drops=0* ]]; then row late PASS "($(grep '(late' "$OUT/serve.log" | tail -1 | sed 's/.*in the VM: //'))"
else row late FAIL "($d; serve: $(tail -2 "$OUT/serve.log" | tr '\n' ' '))"; fi
echo "delay 0" >&7
guser "bash /tmp/dnd/guest-rows.sh window-close" > /dev/null

# limits: 257 files, a folder.
before=$(staged); q0=$(count "$OUT/qemu-on.log" "omacvm-drop: refused")
many=(); for i in $(seq 257); do many+=("$SRC/many/f$i"); done
drop "${many[@]}"; sleep 2
drop "$SRC/hello.txt" "$SRC/dir"; sleep 2
if [[ $(count "$OUT/qemu-on.log" "omacvm-drop: refused") == $((q0 + 2)) && $(staged) == "$before" ]] &&
   grep -q "more than 256" "$OUT/qemu-on.log" && grep -q "a folder" "$OUT/qemu-on.log"; then
  row limits PASS "(257 files and a folder refused, nothing staged)"
else row limits FAIL "(qemu: $(grep 'omacvm-drop: refused' "$OUT/qemu-on.log" | tail -2 | tr '\n' ' '); staged $before -> $(staged))"; fi

# readonly: the share in the VM.
id=$(ls "$ST" | head -1)
r=$(gssh "touch /run/omacvm/drop/x 2>&1; touch /run/omacvm/drop/$id/x 2>&1; ls /run/omacvm/drop/$id 2>&1 | head -3" | tr '\n' ' ')
if [[ -n $id && $r == *"Read-only file system"*"Read-only file system"* ]]; then row readonly PASS "($r)"; else row readonly FAIL "(id '$id': $r)"; fi

# speed: 1 GiB into Downloads.
xy=$(guser "bash /tmp/dnd/guest-rows.sh desktop"); point $xy >> "$OUT/run.log"
n0=$(count "$OUT/serve.log" "in the VM: Downloads")
t0=$(/usr/bin/python3 -c 'import time; print(time.time())')
drop "$SRC/huge.bin"
for _ in $(seq 240); do [[ $(count "$OUT/serve.log" "in the VM: Downloads") -gt $n0 ]] && break; sleep 0.25; done
t1=$(/usr/bin/python3 -c 'import time; print(time.time())')
l=$(guser 'bash /tmp/dnd/guest-rows.sh ls "$(xdg-user-dir DOWNLOAD 2>/dev/null || echo ~/Downloads)"' | grep huge)
secs=$(awk "BEGIN{printf \"%.1f\", $t1-$t0}")
if grep -q "^$(sum "$SRC/huge.bin") 1073741824 huge.bin$" <<<"$l"; then
  row speed PASS "(1 GiB drop to the VM's answer: $secs s = $(awk "BEGIN{printf \"%.0f\", 1024/($t1-$t0)}") MB/s; $(grep 'drop: 1 files' "$OUT/serve.log" | tail -1 | sed 's/.*drop: //'))"
else row speed FAIL "($l; $secs s)"; fi
guser 'rm -f "$(xdg-user-dir DOWNLOAD 2>/dev/null || echo ~/Downloads)"/{hello*.txt,huge.bin}' > /dev/null

# --- off: the same VM started without the switch -------------------------------------------------
stop_vm; stop_serve
start_qemu off || exit 1
o=$(gssh "ls /dev/virtio-ports/ | grep -c drop; findmnt /run/omacvm/drop >/dev/null && echo mounted || echo unmounted; bash /tmp/dnd/drop/guest/install.sh $GUSER --status" 2>&1 | tr '\n' ' ')
os=$(guser "systemctl --user is-active omacvm-drop.service" 2>&1)
if [[ $o == "0 unmounted ok "* && $os != active && $(count "$OUT/qemu-off.log" "omacvm-drop") == 0 && ! -S $RUN/drop ]]; then
  row off PASS "(no port, share unmounted, service $os, QEMU silent, no socket)"
else row off FAIL "($o; service $os; qemu: $(grep -c omacvm-drop "$OUT/qemu-off.log"))"; fi
gssh "bash /tmp/dnd/drop/guest/install.sh $GUSER off; bash /tmp/dnd/drop/guest/install.sh $GUSER --status" >> "$OUT/run.log" 2>&1
log "rows: $(grep -c ' PASS' "$OUT/rows.txt") PASS, $fails FAIL"
exit $(( fails > 0 ))
