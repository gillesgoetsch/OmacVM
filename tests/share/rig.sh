#!/bin/bash
# The Mac folder (virtio-9p) on a test VM: speed per mount option, coherence
# with changes on the Mac, and the VM's own mount at ~/Mac. Runs on a test Mac
# (the Mac mini), never on the user's VMs: it clones SRC_VM into a throwaway.
#   rig.sh start | resume | bench | coherence OPTS | service | off | stop
# Env: SRC_VM (VM folder to clone), APP (OmacVM app with the runtime),
#      W (work dir, default /private/tmp/omacvm-sf), REPS (runs per config).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
W=${W:-/private/tmp/omacvm-sf}
SRC_VM=${SRC_VM:-$HOME/Library/Application Support/OmacVM/VMs/OmacVM M-kk}
APP=${APP:-$HOME/Applications/OmacVM Test.app}
VMD=${VMD:-$HOME/omacvm-sf-vm}           # same volume as SRC_VM (APFS clone)
S=${S:-$HOME/omacvm-sf-share}            # the shared Mac folder
QEMU=$APP/Contents/Resources/runtime/bin/OmacVM
FW=$APP/Contents/Resources/firmware/edk2-aarch64-code.fd
PORT=52391 KEY=$HOME/.ssh/omacvm REPS=${REPS:-1}
mkdir -p "$W"
die() { echo "rig: $*" >&2; exit 1; }
vssh() { ssh -i "$KEY" -p $PORT -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"; }
running() { [[ -f $W/pid ]] && kill -0 "$(cat "$W/pid")" 2>/dev/null; }
wait_ssh() { local i; for ((i = 0; i < 100; i++)); do running || return 1; vssh true </dev/null 2>/dev/null && return 0; sleep 3; done; return 1; }
key_in() {   # this Mac's public key into the clone's root (guest-exec)
  python3 - "$W/qga" "$(cat "$KEY.pub")" <<'PY'
import base64, json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); f = s.makefile("rw")
def cmd(c, a=None):
    f.write(json.dumps({"execute": c, **({"arguments": a} if a else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd("guest-sync", {"id": 7})
sh = "mkdir -p /root/.ssh && grep -qxF '%s' /root/.ssh/authorized_keys 2>/dev/null || echo '%s' >> /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys; systemctl restart sshd" % (sys.argv[2], sys.argv[2])
r = cmd("guest-exec", {"path": "/bin/sh", "arg": ["-c", sh], "capture-output": True})
if "error" in r: sys.exit(1)
pid = r["return"]["pid"]
for _ in range(20):
    st = cmd("guest-exec-status", {"pid": pid})["return"]
    if st.get("exited"): sys.exit(st.get("exitcode", 1))
    time.sleep(0.5)
sys.exit(1)
PY
}
qe() { printf '%s' "${1//,/,,}"; }

boot() {   # boot [share]: start the clone, with the Mac folder when asked
  local share=() u=1000
  # shellcheck disable=SC2054   # QEMU option values, not array separators
  [[ ${1:-} == share ]] && share=(-fsdev "local,id=macfs,path=$(qe "$S"),security_model=none,multidevs=remap,guest_owner_uid=$u,guest_owner_gid=$u"
                                 -device virtio-9p-pci,fsdev=macfs,mount_tag=omacvm-mac)
  "$QEMU" -name omacvm-sf -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off -smp 4 -m 8192 \
    -nodefaults -display none -monitor none -serial "file:$W/console.log" -action reboot=reset,shutdown=poweroff \
    -drive "if=pflash,format=raw,readonly=on,file=$(qe "$FW")" -drive "if=pflash,format=raw,file=$(qe "$VMD/efi-vars.fd")" \
    -drive "if=none,id=disk,file=$(qe "$VMD/disk.img"),format=raw,cache=writeback,discard=unmap" \
    -device nvme,serial=omacvm,drive=disk,bootindex=0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-rng-pci -qmp "unix:$W/qmp,server=on,wait=off" ${share[@]+"${share[@]}"} \
    -device virtio-serial-pci -chardev "socket,id=qga0,path=$W/qga,server=on,wait=off" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 > "$W/qemu.log" 2>&1 &
  echo $! > "$W/pid"
  # The clone's root may not take this Mac's key: add it through the guest agent.
  local i; for ((i = 0; i < 100; i++)); do running || break; key_in && break; sleep 3; done
  wait_ssh || die "no SSH: $(tail -3 "$W/qemu.log")"
  # Test VM: no Mac links (STANDARDS 18a).
  vssh 'for s in omacvm-gestures; do systemctl disable --now $s 2>/dev/null; done; true' </dev/null
}
halt() {
  running || return 0
  vssh 'systemctl poweroff' </dev/null 2>/dev/null
  for _ in $(seq 60); do running || return 0; sleep 1; done
  kill "$(cat "$W/pid")"; sleep 2
}

case ${1:-} in
  start)
    [[ -e $VMD ]] && die "$VMD exists (rig.sh stop first)"
    mkdir -p "$VMD" && cp -c "$SRC_VM/disk.img" "$SRC_VM/efi-vars.fd" "$VMD/" || die "clone failed"
    rm -rf "$S"; mkdir -p "$S/repo"
    python3 "$H/mktree.py" "$S/repo" 30000
    ( cd "$S/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm tree ) || die "repo"
    boot share
    vssh 'mkdir -p /root/sf /mnt/mac' </dev/null
    scp -q -i "$KEY" -P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$H/mktree.py" "$H/guest-bench.sh" "$H/../../src/app/guest/omacvm-mac-folder" \
      "$H/../../src/app/guest/omacvm-mac-folder.service" root@127.0.0.1:/root/sf/
    vssh 'set -e; cd /root/sf; U=$(getent passwd 1000 | cut -d: -f1)
      python3 mktree.py t 12000 && tar -cf tree.tar -C t . && rm -rf t
      rm -rf /var/tmp/sf-local; mkdir -p /var/tmp/sf-local/repo; python3 mktree.py /var/tmp/sf-local/repo 30000
      chown -R $U: /var/tmp/sf-local
      runuser -u $U -- sh -c "cd /var/tmp/sf-local/repo && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm tree"
      uname -r; modinfo 9pnet_virtio | grep -E "^(filename|vermagic)"' </dev/null
    ;;
  resume)   # resume: boot the clone again (after start), with the Mac folder
    running && die "already running"
    boot share
    ;;
  bench)   # bench [LABEL...]: the guest disk, then each mount option (or only these)
    out=$W/bench.jsonl; shift; only=" $* "
    [[ $# == 0 || $only == *" disk "* ]] && vssh "/root/sf/guest-bench.sh /var/tmp/sf-local disk $REPS" </dev/null | tee -a "$out"
    for o in "default|" "msize128k-none|msize=131072,cache=none" "msize512k-none|msize=512000,cache=none" \
             "msize512k-mmap|msize=512000,cache=mmap" "msize512k-readahead|msize=512000,cache=readahead" \
             "msize512k-loose|msize=512000,cache=loose"; do
      l=${o%%|*} m=${o#*|}
      [[ $# == 0 || $only == *" $l "* ]] || continue
      vssh "umount /mnt/mac 2>/dev/null; mount -t 9p -o trans=virtio,version=9p2000.L,access=client${m:+,$m} omacvm-mac /mnt/mac && grep ' /mnt/mac ' /proc/mounts" </dev/null >&2 || { echo "mount $l failed" >&2; continue; }
      vssh "/root/sf/guest-bench.sh /mnt/mac 9p-$l $REPS" </dev/null | tee -a "$out"
    done
    vssh 'umount /mnt/mac' </dev/null
    ;;
  coherence)   # coherence OPTS: changes on the Mac seen in the VM at once, and back
    m=${2:?mount options}
    vssh "umount /mnt/mac 2>/dev/null; mount -t 9p -o trans=virtio,version=9p2000.L,access=client,$m omacvm-mac /mnt/mac" </dev/null || die "mount"
    f=$S/coh.txt; res=""
    check() { local name=$1 want=$2 got; got=$(vssh "$3" </dev/null 2>&1); [[ $got == "$want" ]] && res+="$name=ok " || res+="$name=FAIL(${got:0:40}) "; }
    printf 'v1' > "$f"; check read 'v1' 'cat /mnt/mac/coh.txt'
    sleep 1.1; printf 'v2' > "$f"; check rewrite 'v2' 'cat /mnt/mac/coh.txt'
    printf 'v2+more' > "$f"; check grow 'v2+more' 'cat /mnt/mac/coh.txt'
    : > "$S/new.txt"; check create yes 'test -e /mnt/mac/new.txt && echo yes || echo no'
    rm -f "$S/new.txt"; check delete no 'test -e /mnt/mac/new.txt && echo yes || echo no'
    mv "$f" "$S/coh2.txt"; check rename 'v2+more' 'cat /mnt/mac/coh2.txt'
    vssh 'echo -n g1 > /mnt/mac/fromvm.txt' </dev/null; [[ $(cat "$S/fromvm.txt") == g1 ]] && res+="vm-write=ok " || res+="vm-write=FAIL "
    vssh 'ls -ln /mnt/mac/fromvm.txt | cut -d" " -f3,4' </dev/null | grep -qx '1000 1000' && res+="owner=ok " || res+="owner=FAIL "
    rm -f "$S/coh2.txt" "$S/fromvm.txt"
    echo "coherence $m: $res" | tee -a "$W/coherence.txt"
    vssh 'umount /mnt/mac' </dev/null
    ;;
  service)   # service: the VM's own unit mounts ~/Mac at boot; the user can write
    scp -q -i "$KEY" -P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$H/../../src/app/guest/omacvm-mac-folder" "$H/../../src/app/guest/omacvm-mac-folder.service" root@127.0.0.1:/root/sf/
    vssh 'install -m755 /root/sf/omacvm-mac-folder /usr/local/bin/ && install -m644 /root/sf/omacvm-mac-folder.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable omacvm-mac-folder.service' </dev/null
    halt; boot share
    vssh 'U=$(getent passwd 1000 | cut -d: -f1); H=$(getent passwd 1000 | cut -d: -f6)
      systemctl is-active omacvm-mac-folder; grep " $H/Mac " /proc/mounts
      runuser -u $U -- sh -c "echo hi > ~/Mac/user-write.txt && ls -l ~/Mac/user-write.txt"' </dev/null
    ls -l "$S/user-write.txt" && rm -f "$S/user-write.txt"
    ;;
  off)   # off: no share -> no mount, no empty ~/Mac, the boot as before
    halt; boot
    vssh 'H=$(getent passwd 1000 | cut -d: -f6); systemctl is-active omacvm-mac-folder; systemctl show -p Result omacvm-mac-folder
      test -e $H/Mac && echo "~/Mac still there" || echo "no ~/Mac"; systemd-analyze blame | grep -i mac-folder' </dev/null
    ;;
  halt) halt ;;
  stop)
    halt; rm -rf "$VMD" "$S"
    ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
