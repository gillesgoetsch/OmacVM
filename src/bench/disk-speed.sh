#!/bin/bash
# Disk speed of an app VM with different QEMU disk options, in one boot.
#
#   disk-speed.sh prep  VM_DIR WORK            clone VM_DIR's disk (APFS clone) into WORK, install fio/git,
#                                              a git mirror and a package cache in that clone
#   disk-speed.sh run   WORK TAG CONFIG...     boot the clone with one test disk per CONFIG, measure each
#   disk-speed.sh soak  WORK MINUTES           the system disk: verified random I/O, pause/resume, fstrim, scrub
#   disk-speed.sh clean WORK
#
# CONFIG = name[@dir]: nvme-wb (today's app default), nvme-none, nvme-wb-ioev, vblk-wb, vblk-wb-iot,
# vblk-none-iot, nvme-unsafe (reference only: flushes ignored), nvme-wb-dz (detect-zeroes=unmap).
# @dir puts that test disk in another folder (another volume). Steps per config: DS_STEPS
# (default "fio real space"). Results: WORK/results.jsonl, one JSON object per line.
# Runs QEMU headless, user network only, no Mac links (no clipboard, no helper ports).
# Use only on a test Mac (the Mac mini), never with the user's own VMs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APP=${OMACVM_APP:-$HOME/Applications/OmacVM Test.app}
QEMU=$APP/Contents/Resources/runtime/bin/OmacVM
FW=$APP/Contents/Resources/firmware/edk2-aarch64-code.fd
KEY=${OMACVM_KEY:-$HOME/.ssh/omacvm}
PORT=${DS_PORT:-52390}
CPUS=${DS_CPUS:-6} MEM=${DS_MEM_MB:-6144}
DISK_GB=8
die() { echo "disk-speed: $*" >&2; exit 1; }

vssh() {
  ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
alloc() { echo $(( $(stat -f %b "$1") * 512 / 1048576 )); }   # MiB the Mac really uses

drive_opts() {   # config -> -drive options after file=
  case $1 in
  nvme-wb|vblk-wb|vblk-wb-iot|nvme-wb-ioev) echo "cache=writeback,discard=unmap" ;;
  nvme-none|vblk-none-iot) echo "cache=none,discard=unmap" ;;
  nvme-unsafe) echo "cache=unsafe,discard=unmap" ;;
  nvme-wb-dz) echo "cache=writeback,discard=unmap,detect-zeroes=unmap" ;;
  *) die "unknown config $1" ;;
  esac
}
device_args() {   # config index -> -device (and -object) arguments, one per line
  local c=$1 i=$2
  case $c in
  nvme-wb-ioev) echo "-device"; echo "nvme,serial=ds$i,drive=d$i,ioeventfd=on" ;;
  nvme-*) echo "-device"; echo "nvme,serial=ds$i,drive=d$i" ;;
  vblk-*-iot) echo "-object"; echo "iothread,id=iot$i"
              echo "-device"; echo "virtio-blk-pci,serial=ds$i,drive=d$i,iothread=iot$i" ;;
  vblk-*) echo "-device"; echo "virtio-blk-pci,serial=ds$i,drive=d$i" ;;
  esac
}

boot() {   # WORK, extra QEMU args...
  local w=$1; shift
  # DS_SYS_BUS=virtio: the system disk on virtio-blk with an iothread (else NVMe, as the app today).
  local sysdev=(-device "nvme,serial=omacvm,drive=disk,bootindex=0")
  [[ ${DS_SYS_BUS:-} == virtio ]] &&
    sysdev=(-object "iothread,id=iodisk" -device "virtio-blk-pci,drive=disk,iothread=iodisk,bootindex=0,romfile=")
  rm -f "$w/qmp"
  "$QEMU" -name "OmacVM M-disk-speed" -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off \
    -smp "$CPUS" -m "${MEM}M" -nodefaults -display none -monitor none -serial "file:$w/console.log" \
    -action reboot=reset,shutdown=poweroff \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" -drive "if=pflash,format=raw,file=$w/efi-vars.fd" \
    -drive "if=none,id=disk,file=$w/sys.img,format=raw,cache=writeback,discard=unmap" \
    "${sysdev[@]}" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-rng-pci -qmp "unix:$w/qmp,server=on,wait=off" "$@" > "$w/qemu.log" 2>&1 &
  echo $! > "$w/pid"
  local i t0=$SECONDS
  for ((i = 0; i < 300; i++)); do
    kill -0 "$(cat "$w/pid")" 2>/dev/null || die "QEMU stopped: $(tail -3 "$w/qemu.log")"
    if vssh true </dev/null 2>/dev/null; then
      echo "{\"test\":\"boot\",\"sys_bus\":\"${DS_SYS_BUS:-nvme}\",\"ssh_s\":$((SECONDS - t0))}" >> "$w/results.jsonl"
      return 0
    fi
    sleep 1
  done
  die "no SSH after 300 s"
}
halt() {   # WORK
  local w=$1 i
  [[ -f $w/pid ]] || return 0
  vssh systemctl poweroff </dev/null >/dev/null 2>&1 || true
  for ((i = 0; i < 60; i++)); do kill -0 "$(cat "$w/pid")" 2>/dev/null || break; sleep 1; done
  kill "$(cat "$w/pid")" 2>/dev/null || true
  rm -f "$w/pid"
}

case ${1:-} in
prep)
  vm=$2 w=$3
  [[ -f $vm/disk.img && -f $vm/efi-vars.fd ]] || die "no VM in $vm"
  mkdir -p "$w"
  # The system disk: an APFS clone (DS_SYS must be on the VM's volume).
  sys=${DS_SYS:-$HOME/omacvm-disk-speed-sys.img}
  [[ -f $sys ]] || cp -c "$vm/disk.img" "$sys" || die "cannot clone $vm/disk.img to $sys (same volume?)"
  ln -sf "$sys" "$w/sys.img"
  cp "$vm/efi-vars.fd" "$w/efi-vars.fd"
  trap 'halt "$w"' EXIT
  boot "$w"
  vssh 'cat > /root/ds.sh && chmod +x /root/ds.sh' < "$here/disk-speed-guest.sh"
  vssh 'systemctl disable --now fstrim.timer >/dev/null 2>&1; /root/ds.sh prep' | tee -a "$w/results.jsonl"
  ;;
run)
  w=$2 tag=$3; shift 3
  steps=${DS_STEPS:-fio real space}
  args=() serials=() names=() files=()
  i=0
  for spec in "$@"; do
    i=$((i + 1)); c=${spec%%@*}; d=$w; [[ $spec == *@* ]] && d=${spec#*@}
    f=$d/ds-$i.img
    rm -f "$f"; mkdir -p "$d"
    dd if=/dev/null of="$f" bs=1 seek=$((DISK_GB << 30)) 2>/dev/null   # sparse, like the app's disk.img
    args+=(-drive "if=none,id=d$i,file=$f,format=raw,$(drive_opts "$c")")
    while IFS= read -r a; do args+=("$a"); done < <(device_args "$c" "$i")
    serials+=("ds$i") names+=("$spec") files+=("$f")
  done
  trap 'halt "$w"; rm -f "${files[@]}"' EXIT
  boot "$w" "${args[@]}"
  vssh 'cat > /root/ds.sh && chmod +x /root/ds.sh' < "$here/disk-speed-guest.sh"
  vssh 'systemctl stop fstrim.timer >/dev/null 2>&1 || true'
  emit() { python3 -c 'import json,sys; j=json.loads(sys.argv[1]); j.update(config=sys.argv[2], tag=sys.argv[3]); print(json.dumps(j))' "$1" "$2" "$tag" | tee -a "$w/results.jsonl"; }
  space() { emit "{\"test\":\"space\",\"at\":\"$2\",\"alloc_mib\":$(alloc "$3")}" "$1"; }
  n=${#names[@]}
  # Each run starts at another config, so no config always goes first.
  off=$(( $(date +%s) % n ))
  for ((k = 0; k < n; k++)); do
    j=$(( (k + off) % n )); c=${names[$j]} s=${serials[$j]} f=${files[$j]}
    for step in $steps; do
      case $step in
      fio)
        while read -r l; do emit "$l" "$c"; done < <(vssh "/root/ds.sh $s fio write")
        sudo -n purge 2>/dev/null || true      # reads from the disk, not the Mac's cache
        while read -r l; do emit "$l" "$c"; done < <(vssh "/root/ds.sh $s fio read")
        while read -r l; do emit "$l" "$c"; done < <(vssh "/root/ds.sh $s fio rest")
        vssh "/root/ds.sh $s wipe" >/dev/null ;;
      real)
        emit "$(vssh "/root/ds.sh $s real")" "$c"
        space "$c" after-real "$f"
        sudo -n purge 2>/dev/null || true
        emit "$(vssh "/root/ds.sh $s coldread")" "$c"
        vssh "/root/ds.sh $s wipe" >/dev/null ;;
      space)
        space "$c" empty "$f"
        emit "$(vssh "/root/ds.sh $s fill 2048")" "$c"; space "$c" after-fill "$f"
        vssh "/root/ds.sh $s rmonly" >/dev/null; sleep 60; space "$c" rm-60s-async-discard "$f"
        emit "$(vssh "/root/ds.sh $s trim")" "$c"; space "$c" after-fstrim "$f"
        emit "$(vssh "/root/ds.sh $s zeros 1024")" "$c"; space "$c" after-1g-zeros "$f"
        vssh "/root/ds.sh $s wipe" >/dev/null; space "$c" after-blkdiscard "$f" ;;
      esac
    done
  done
  ;;
soak)   # WORK MINUTES: the system disk under verified random I/O, paused and resumed every 30 s
         # (as the app does when the Mac sleeps), fstrim every 2 min; then a reboot and a btrfs scrub.
  w=$2 min=${3:-10}
  trap 'halt "$w"' EXIT
  boot "$w"
  qmp() { printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" | nc -U -w 2 "$w/qmp" >/dev/null; }
  vssh "rm -f /root/soak.fio; nohup fio --name=soak --filename=/root/soak.fio --size=1G --rw=randrw --bs=4k-64k \
    --ioengine=libaio --iodepth=16 --direct=1 --verify=crc32c --verify_backlog=1024 --time_based --runtime=$((min * 60)) \
    --output-format=json --output=/root/soak.json >/dev/null 2>&1 &"
  pauses=0 trims=0 end=$((SECONDS + min * 60))
  stuck() { grep -aq "blocked in I/O wait" "$w/console.log"; }   # the guest's hung-task warning
  while ((SECONDS < end)) && ! stuck; do
    sleep 25
    # DS_PAUSE=0: no pause/resume (to tell a pause problem from a load problem).
    if [[ ${DS_PAUSE:-1} == 1 ]]; then qmp stop; sleep 5; qmp cont; pauses=$((pauses + 1)); else sleep 5; pauses=$((pauses + 1)); fi
    if ((pauses % 4 == 0)); then vssh "fstrim / >/dev/null" && trims=$((trims + 1)); fi
  done
  # The guest's clock stops while the VM is paused: fio runs that much longer.
  for ((i = 0; i < 120; i++)); do stuck || ! vssh "pgrep -x fio >/dev/null" && break; sleep 5; done
  if stuck; then
    echo "{\"test\":\"soak\",\"sys_bus\":\"${DS_SYS_BUS:-nvme}\",\"pause\":${DS_PAUSE:-1},\"pauses\":$pauses,\"fstrims\":$trims,\"result\":\"HUNG\",\"after_s\":$((SECONDS - end + min * 60))}" | tee -a "$w/results.jsonl"
    exit 1
  fi
  hung=$(grep -ac "blocked in I/O wait" "$w/console.log" || true)
  res=$(vssh "python3 -c \"import json; j=json.load(open('/root/soak.json'))['jobs'][0]; print(j['error'], j['read']['io_bytes'] >> 20, j['write']['io_bytes'] >> 20)\"")
  vssh "rm -f /root/soak.fio /root/soak.json; systemctl reboot" || true
  sleep 10
  for ((i = 0; i < 60; i++)); do vssh true </dev/null 2>/dev/null && break; sleep 2; done
  scrub=$(vssh "btrfs scrub start -B / 2>&1 | grep -E 'Error summary|summary' | tr -s ' '; dmesg | grep -ciE 'I/O error|blk_update_request|csum failed' || true")
  echo "{\"test\":\"soak\",\"sys_bus\":\"${DS_SYS_BUS:-nvme}\",\"minutes\":$min,\"pauses\":$pauses,\"fstrims\":$trims,\"pause\":${DS_PAUSE:-1},\"hung_task_lines\":$hung,\"fio_error_read_mib_write_mib\":\"$res\",\"scrub_and_io_errors\":\"$(echo $scrub)\"}" | tee -a "$w/results.jsonl"
  ;;
up)    # boot the prepared clone and leave it running (for a look by hand); "down" stops it
  boot "$2"; echo "ssh -i $KEY -p $PORT root@127.0.0.1" ;;
down) halt "$2" ;;
clean)
  w=$2
  halt "$w"
  sys=$(readlink "$w/sys.img" || true)
  [[ -n $sys && $sys == */omacvm-disk-speed-sys.img ]] && rm -f "$sys"
  rm -rf "$w"
  ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
