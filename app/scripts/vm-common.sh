# Shared by the VM scripts (sourced). Finds the runtime, loads a VM's settings,
# runs QEMU without a window and talks to the VM over SSH.

log() { printf '==> %s\n' "$*"; }
# QEMU option values split at commas; a comma in a value is written twice.
qe() { printf '%s' "${1//,/,,}"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Where things are: inside the app (Contents/Resources) or in the source tree
# (app/ of the omacvm repo, OmacVM's VM side in ../src).
_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d $_root/runtime/.build/qemu-gpu-runtime ]]; then
  QEMU=$_root/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64
  ZSTD=$_root/runtime/.build/qemu-gpu-runtime/bin/zstd
  FIRMWARE=$_root/runtime/.build/firmware/edk2-aarch64-code.fd
  OMACVM_SRC=$(cd "$_root/.." && pwd)/src
else
  QEMU=$_root/runtime/bin/OmacVM
  ZSTD=$_root/runtime/bin/zstd
  FIRMWARE=$_root/firmware/edk2-aarch64-code.fd
  OMACVM_SRC=$_root/omacvm/src
fi
[[ -x $QEMU && -f $FIRMWARE && -d $OMACVM_SRC ]] || die "the app is incomplete (QEMU, firmware or OmacVM missing under $_root)"
CACHE=${OMACVM_CACHE:-$HOME/Library/Caches/omacvm}
KEY=${OMACVM_KEY:-$HOME/.ssh/omacvm}
source "$OMACVM_SRC/vm/live/release.sh"
# The Mac's 127.0.0.1 ports the VM may reach as 10.0.2.2: Omanotch, Gestures, Bridge.
HOST_PORTS=47811,47830,47831

vm_load() {
  VM_DIR=$(cd "$1" && pwd)
  [[ -f $VM_DIR/vm.env ]] || die "no vm.env in $VM_DIR"
  source "$VM_DIR/vm.env"
  : "${NAME:?}" "${CPUS:?}" "${MEM_MB:?}" "${DISK_GB:?}" "${SSH_PORT:?}" "${VM_USER:?}"
  LOG=$VM_DIR/logs; mkdir -p "$LOG"
  RUN_DIR=$(getconf DARWIN_USER_TEMP_DIR)omacvm
  mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
  VM_ID=$(printf '%s' "$VM_DIR" | shasum | cut -c1-8)
  QMP=$RUN_DIR/$VM_ID.qmp          # short: Unix socket paths stop at 104 bytes
  PIDFILE=$RUN_DIR/$VM_ID.pid
  QEMU_UEFI=(-drive "if=pflash,format=raw,readonly=on,file=$(qe "$FIRMWARE")"
             -drive "if=pflash,format=raw,file=$(qe "$VM_DIR/efi-vars.fd")")
  DISK_OPT="if=none,id=disk,file=$(qe "$VM_DIR/disk.img"),format=raw,cache=writeback,discard=unmap"
  if [[ ! -f $KEY ]]; then
    mkdir -p "$(dirname "$KEY")"; chmod 700 "$(dirname "$KEY")"
    ssh-keygen -t ed25519 -N "" -C omacvm -f "$KEY" -q
  fi
}

# Xcode's Command Line Tools (swiftc, clang), for OmacVM's Mac helpers.
clt_ok() { xcode-select -p >/dev/null 2>&1 && xcrun -f swiftc >/dev/null 2>&1 && xcrun -f clang >/dev/null 2>&1; }

# Grow (or create) a sparse file to SIZE bytes.
truncate_file() { dd if=/dev/null of="$1" bs=1 seek="$2" 2>/dev/null; }

efi_vars_create() { [[ -f $VM_DIR/efi-vars.fd ]] || mkfile -n 64m "$VM_DIR/efi-vars.fd"; }

# try-omarchy's release: kernel, initramfs and its Arch Linux ARM root file
# system: the DMG checked against its pinned SHA-256, the files inside against
# the release's own manifest. Downloaded once.
live_fetch() {
  local d=$CACHE/live dmg vol app g
  mkdir -p "$d"
  LIVE_KERNEL=$d/vmlinuz-linux LIVE_INITRD=$d/initramfs-linux.img LIVE_ROOTFS=$d/rootfs.ext4
  # macOS may clear Caches: the marker counts only with the files still there.
  if [[ -f $d/ok-$LIVE_RELEASE && -f $LIVE_KERNEL && -f $LIVE_INITRD && -f $LIVE_ROOTFS ]]; then
    log "live system cached"; return
  fi
  rm -f "$d/ok-$LIVE_RELEASE"
  dmg=$d/TryOmarchy-$LIVE_RELEASE.dmg
  # Only the app uses this folder: the omacvm command's build-live.sh works in
  # ../build-live and deletes its files when done.
  if [[ ! -f $dmg ]]; then
    log "downloading try-omarchy $LIVE_RELEASE (1.4 GB)"
    curl -fL --retry 3 --progress-bar -o "$dmg.part" \
      "https://github.com/omacom/try-omarchy/releases/download/$LIVE_RELEASE/TryOmarchy.dmg"
    mv "$dmg.part" "$dmg"
  fi
  # The DMG must be the pinned one (src/vm/live/release.sh), then its own
  # manifest vouches for the files inside.
  log "checking the download against its pinned SHA-256"
  [[ $(shasum -a 256 "$dmg" | cut -d' ' -f1) == "$LIVE_DMG_SHA256" ]] ||
    { rm -f "$dmg"; die "TryOmarchy.dmg $LIVE_RELEASE is not the pinned one; deleted it, try again to download it again"; }
  vol=$d/mnt; mkdir -p "$vol"
  hdiutil attach -nobrowse -readonly -mountpoint "$vol" "$dmg" >/dev/null || die "could not open $dmg"
  app=$(find "$vol" -maxdepth 2 -name '*.app' | head -1)
  g=$app/Contents/Resources/guest
  local f want got
  for f in vmlinuz-linux initramfs-linux.img rootfs.ext4.zst; do
    want=$(awk -v f="$f" '$2 == f { print $1 }' "$g/SHA256SUMS")
    got=$(shasum -a 256 "$g/$f" | cut -d' ' -f1)
    [[ -n $want && $want == "$got" ]] || { hdiutil detach "$vol" >/dev/null; die "$f: checksum mismatch"; }
  done
  cp "$g/vmlinuz-linux" "$g/initramfs-linux.img" "$d/"
  log "unpacking the live system (6 GB)"
  "$ZSTD" -d -q -f "$g/rootfs.ext4.zst" -o "$d/rootfs.ext4"
  hdiutil detach "$vol" >/dev/null
  touch "$d/ok-$LIVE_RELEASE"
  rm -f "$dmg"
}

# qemu_headless NAME ARGS...: QEMU without a window, serial console in
# logs/NAME-console.log, SSH on 127.0.0.1:SSH_PORT.
qemu_headless() {
  local name=$1; shift
  rm -f "$QMP"
  OMACVM_SLIRP_HOST_PORTS=$HOST_PORTS \
  "$QEMU" -name "$(qe "$NAME")" -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off \
    -smp "$CPUS" -m "${MEM_MB}M" -nodefaults -display none -monitor none \
    -action reboot=reset,shutdown=poweroff \
    -serial "file:$(qe "$LOG/$name-console.log")" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-rng-pci -qmp "unix:$(qe "$QMP"),server=on,wait=off" "$@" \
    > "$LOG/$name-qemu.log" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 1
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || die "QEMU did not start: $(tail -3 "$LOG/$name-qemu.log")"
}

qemu_running() { [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
qemu_wait_exit() {   # [seconds]
  local i
  for ((i = 0; i < ${1:-120}; i++)); do qemu_running || return 0; sleep 1; done
  return 1
}
qmp() { printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" | nc -U -w 2 "$QMP" >/dev/null 2>&1; }
qemu_quit() { qmp quit || true; qemu_wait_exit 10 || kill "$(cat "$PIDFILE")" 2>/dev/null || true; }

vssh() {
  ssh -i "$KEY" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
wait_ssh() {   # [seconds]
  local i
  for ((i = 0; i < ${1:-300}; i += 3)); do
    qemu_running || return 1
    vssh true < /dev/null 2>/dev/null && return 0
    sleep 3
  done
  return 1
}

# run_logged LOGFILE CMD...: CMD's output to LOGFILE, its "==>" lines to us.
run_logged() {
  local f=$1 rc; shift
  set +e
  "$@" 2>&1 | tee "$f" | sed -l 's/\x1b\[[0-9;]*m//g' | grep --line-buffered -E '^==>|ERROR|[Ee]rror:|failed'
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# omarchy-mac's release lane: stable once published, else rc.
omarchy_channel() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
    https://api.github.com/repos/omarchy-mac/omarchy-pkgs-aarch64/releases/tags/stable) || code=0
  [[ $code == 200 ]] && echo stable || echo rc
}
