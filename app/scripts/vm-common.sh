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
# downloads_dir ROOT: where builds of VMs in the VMs folder ROOT keep their
# downloads: ~/Library/Caches/omacvm when ROOT is on the home folder's drive,
# else ROOT/.downloads, so VMs on another drive leave the Mac's disk alone.
# The app's Storage.downloadsFolder has the same rule (src/tests/app-storage.sh).
# -L: a linked VMs folder counts where it points, as in the app.
downloads_dir() {
  local a=$1
  until [[ -e $a || $a == / ]]; do a=$(dirname "$a"); done
  if [[ $(stat -L -f %d "$a") == "$(stat -L -f %d "$HOME")" ]]; then echo "$HOME/Library/Caches/omacvm"
  else echo "${1%/}/.downloads"; fi
}

# Downloads (try-omarchy, prebuilt VMs): OMACVM_CACHE (the app passes it), else
# those of the VMs folder OMACVM_VMS_ROOT (omacvm build passes it), else the
# Mac's. Made only by builds and lookups (cache_ready).
if [[ -n ${OMACVM_CACHE:-} ]]; then CACHE=$OMACVM_CACHE
elif [[ -n ${OMACVM_VMS_ROOT:-} ]]; then CACHE=$(downloads_dir "$OMACVM_VMS_ROOT")
else CACHE=$HOME/Library/Caches/omacvm; fi

# cache_ready: makes CACHE. Time Machine leaves it out, each time: a lookup may
# have made it first (~/Library/Caches is left out anyway).
cache_ready() {
  mkdir -p "$CACHE" || return 1
  tmutil addexclusion "$CACHE" >/dev/null 2>&1 || true
}
KEY=${OMACVM_KEY:-$HOME/.ssh/omacvm}
source "$OMACVM_SRC/vm/live/release.sh"
# A script of "OmacVM Test" run by hand (apply-vm.sh from a shell) is the
# test identity too, not only when the app sets OMACVM_TEST_IDENTITY: else its
# apply installs the normal Bridge next to the test one, and that Bridge takes
# the test VM's media keys (MacBook Air, 2026-10-06).
if [[ -z ${OMACVM_TEST_IDENTITY:-} && -f $_root/../Info.plist ]] &&
   [[ $(plutil -extract CFBundleIdentifier raw -o - "$_root/../Info.plist" 2>/dev/null) == org.omacvm.app.test ]]; then
  export OMACVM_TEST_IDENTITY=1
fi
# The Mac's 127.0.0.1 ports the VM may reach as 10.0.2.2: Omanotch, Gestures, Bridge.
# OMACVM_HOST_PORTS= (empty): none (image builds and test VMs leave the Mac's helpers alone).
# The test identity (OMACVM_TEST_IDENTITY=1, from "OmacVM Test"): its own Gestures and
# Bridge on 47930/47931 (libslirp maps the guest's ports); Omanotch on 47911, where
# only a test Omanotch listens, never the installed one.
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then HOST_PORTS=${OMACVM_HOST_PORTS-47811>47911,47830>47930,47831>47931}
else HOST_PORTS=${OMACVM_HOST_PORTS-47811,47830,47831}; fi
source "$OMACVM_SRC/lib/proxy.sh"
proxy_none

# proxy_setup: the Mac's proxy (src/lib/proxy.sh) for this build; the ports of
# one on the Mac's 127.0.0.1 join HOST_PORTS (the VM's 10.0.2.2:PORT is then
# the Mac's 127.0.0.1:PORT). Image builds take nothing of this Mac.
proxy_setup() {
  [[ ${OMACVM_CREATE_IMAGE:-} == 1 ]] && return 0
  proxy_detect
  [[ -z $PROXY_NOTE ]] || log "proxy: $PROXY_NOTE"
  local p; p=$(proxy_ports)
  [[ -z $p ]] || HOST_PORTS=${HOST_PORTS:+$HOST_PORTS,}$p
  [[ -z $(proxy_summary) ]] || log "proxy: $(proxy_summary)"
}

# proxy_to_vm: the proxy variables into the live system's /root/omacvm-proxy.env
# (base-install.sh uses them and keeps them in the new system); nothing without a proxy.
proxy_to_vm() {
  local e; e=$(proxy_guest_env 10.0.2.2)
  [[ -n $e ]] || return 0
  printf '%s\n' "$e" | vssh "umask 022; cat > /root/omacvm-proxy.env"
}

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
  cache_ready || die "could not make $CACHE"
  mkdir -p "$d"
  LIVE_KERNEL=$d/vmlinuz-linux LIVE_INITRD=$d/initramfs-linux.img LIVE_ROOTFS=$d/rootfs.ext4
  # macOS may clear Caches: the marker counts only with the files still there.
  if [[ -f $d/ok-$LIVE_RELEASE && -f $LIVE_KERNEL && -f $LIVE_INITRD && -f $LIVE_ROOTFS ]]; then
    log "live system cached"; return
  fi
  rm -f "$d/ok-$LIVE_RELEASE"
  live_reuse "$d" && return
  dmg=$d/TryOmarchy-$LIVE_RELEASE.dmg
  # Only the app uses this folder: the omacvm command's build-live.sh works in
  # ../build-live and deletes its files when done.
  if [[ ! -f $dmg ]]; then
    log "downloading try-omarchy $LIVE_RELEASE (1.4 GB)"
    download "https://github.com/omacom/try-omarchy/releases/download/$LIVE_RELEASE/TryOmarchy.dmg" \
      "$dmg.part" try-omarchy
    mv "$dmg.part" "$dmg"
  fi
  # The DMG must be the pinned one (src/vm/live/release.sh), then its own
  # manifest vouches for the files inside.
  log "checking the download against its pinned SHA-256"
  [[ $(shasum -a 256 "$dmg" | cut -d' ' -f1) == "$LIVE_DMG_SHA256" ]] ||
    { rm -f "$dmg"; die "TryOmarchy.dmg $LIVE_RELEASE is not the pinned one; deleted it; try again to download it fresh"; }
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

# progress_line PHASE NOW DONE TOTAL: a progress line for the app (Creator.swift).
# Only when the app asks (OMACVM_PROGRESS=1): omacvm build runs these scripts
# in a terminal too.
progress_line() {
  [[ ${OMACVM_PROGRESS:-} == 1 ]] || return 0
  printf '{"omacvm_progress": 1, "phase": "%s", "now": "%s", "done": %d, "total": %d}\n' "$1" "$2" "$3" "$4"
}

# bytes_watch NOW TOTAL FILE...: every second a progress line with how many
# bytes of the FILEs are there, until killed or the script ($$) is gone (the
# app's Cancel stops only the script).
bytes_watch() {
  local now=$1 total=$2 f n sz; shift 2
  [[ ${OMACVM_PROGRESS:-} == 1 ]] || return 0
  while kill -0 $$ 2>/dev/null; do
    n=0
    for f in "$@"; do sz=$(stat -f %z "$f" 2>/dev/null || echo 0); n=$((n + sz)); done
    progress_line download "$now" "$n" "$total"
    sleep 1
  done
}

# download URL FILE NOW: curl with a progress line every second for the app
# (size from the server; 0 when it gives none), else curl's own bar.
download() {
  local url=$1 out=$2 total w rc=0
  if [[ ${OMACVM_PROGRESS:-} != 1 ]]; then
    curl -fL --retry 3 --progress-bar -o "$out" "$url"; return
  fi
  total=$(curl -fsIL --max-time 20 "$url" 2>/dev/null | tr -d '\r' |
    awk 'tolower($1) == "content-length:" && $2 ~ /^[0-9]+$/ { n = $2 } END { print n + 0 }') || total=0
  bytes_watch "$3" "${total:-0}" "$out" & w=$!
  curl -fsSL --retry 3 -o "$out" "$url" || rc=$?
  kill "$w" 2>/dev/null || true; wait "$w" 2>/dev/null || true
  [[ $rc == 0 ]] && progress_line download "$3" "$(stat -f %z "$out")" "${total:-0}"
  return "$rc"
}

# others_building: another OmacVM build runs: not this script, what it started
# or what started it (omacvm build, say). It may read a downloads folder.
others_building() {
  local mine=" " p=$$
  while [[ -n $p && $p -gt 1 ]]; do mine+="$p "; p=$(ps -o ppid= -p "$p" | tr -d ' '); done
  # bash running one of the build scripts (not a shell line or an editor that names one)
  local build='^[^ ]*bash ([^-].*/)?((create-vm|prebuilt-vm|build-live|make-image)[.]sh|omacvm build)( |$)'
  ps -x -ww -U "$(id -u)" -o pid=,ppid=,args= | awk -v me=$$ -v mine="$mine" -v build="$build" '
    { pid[NR] = $1; pp[$1] = $2; a = $0; sub(/^ *[0-9]+ +[0-9]+ /, "", a); args[NR] = a }
    END {
      for (i = 1; i <= NR; i++) {
        if (index(mine, " " pid[i] " ") || args[i] !~ build) continue
        q = pid[i]; ours = 0
        for (n = 0; n < 64 && q + 0 > 1; n++) { if (q == me) { ours = 1; break }; q = pp[q] }
        if (!ours) found = 1
      }
      exit !found
    }'
}

# live_reuse DIR: a live system of this release in another downloads folder
# (the Mac's own, or the app's others in OMACVM_LIVE_FROM, one per line) moves
# to DIR instead of being downloaded again: copied (a clone on one APFS drive),
# then deleted there. Any other live system there (an older release, a second
# copy) is of no use then: deleted too. While another build runs, all stay (it
# may read them).
live_reuse() {
  local d=$1 s f busy=0 found=1
  others_building && busy=1
  while IFS= read -r s; do
    [[ -n $s ]] || continue
    s=${s%/}/live
    [[ -d $s && ! -L $s && ! -L ${s%/live} && ! $s -ef $d ]] || continue
    if (( found )) && [[ -f $s/ok-$LIVE_RELEASE && -f $s/vmlinuz-linux && -f $s/initramfs-linux.img && -f $s/rootfs.ext4 ]]; then
      log "moving the live system from $s"
      rm -rf "$d/.moving" && mkdir -p "$d/.moving" || return 1
      for f in vmlinuz-linux initramfs-linux.img rootfs.ext4; do
        cp -c "$s/$f" "$d/.moving/$f" 2>/dev/null || cp "$s/$f" "$d/.moving/$f" ||
          { rm -rf "$d/.moving"; log "could not copy it: downloading instead"; return 1; }
      done
      for f in vmlinuz-linux initramfs-linux.img rootfs.ext4; do
        mv -f "$d/.moving/$f" "$d/$f" || { rm -rf "$d/.moving"; return 1; }
      done
      rmdir "$d/.moving" && touch "$d/ok-$LIVE_RELEASE" || return 1
      found=0
    fi
    (( busy )) && continue
    rm -f "$s"/ok-* && rm -f "$s/vmlinuz-linux" "$s/initramfs-linux.img" "$s/rootfs.ext4" "$s"/TryOmarchy-*.dmg || true
  done <<<"$(printf '%s\n%s\n' "$HOME/Library/Caches/omacvm" "${OMACVM_LIVE_FROM:-}")"
  return $found
}

# qemu_headless NAME ARGS...: QEMU without a window, serial console in
# logs/NAME-console.log, SSH on 127.0.0.1:SSH_PORT.
qemu_headless() {
  local name=$1; shift
  rm -f "$QMP"
  # Always QEMU's user network here (SSH on 127.0.0.1): say so for app_ip (src/lib/app.sh).
  echo "slirp headless" > "$LOG/network"
  OMACVM_SLIRP_HOST_PORTS=$HOST_PORTS \
  "$QEMU" -name "$(qe "$NAME")" -machine virt,gic-version=3 -accel hvf -cpu host,pmu=off \
    -smp "$CPUS" -m "${MEM_MB}M" -nodefaults -display none -monitor none \
    -action reboot=reset,shutdown=poweroff -boot menu=on,splash-time=0 \
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

# Text from the VM on its way to the app or a terminal: colour codes out, then
# only printable ASCII and tabs (no other escape sequences: a guest could set
# the window title or the Mac's clipboard), lines cut at 240 characters.
# Line by line, so progress still shows as it comes.
printable() {
  LC_ALL=C sed -l -e $'s/\x1b\\[[0-9;]*m//g' -e 's/[^[:print:][:blank:]]//g' -e 's/^\(.\{240\}\).*/\1/'
}

# run_logged LOGFILE CMD...: CMD's output to LOGFILE, its "==>" and progress
# lines to us. Lines starting with "| " are raw output (src/vm/progress.sh):
# only for the log, the app shows its tail.
run_logged() {
  local f=$1 rc; shift
  set +e
  "$@" 2>&1 | tee "$f" | printable | grep --line-buffered -v '^| ' |
    grep --line-buffered -E '^==>|^\{"omacvm_progress": 1, |ERROR|[Ee]rror:|failed'
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
