#!/bin/bash
# A new OmacVM.app VM from a prebuilt image instead of building it: a few
# minutes plus the download. The same contract as create-vm.sh (the app runs
# one or the other):
#
#   prebuilt-vm.sh VM_DIR     the password on stdin (one line)
#   prebuilt-vm.sh --lookup   is there an image for this version? Prints
#                             "TAG BYTES OMARCHY_VERSION IMAGE_VERSION" (exit 1:
#                             none). omacvm build asks this too, so the app and
#                             the command always pick the same image.
#
# VM_DIR/vm.env as for create-vm.sh. Progress lines start with "==>", steps
# with "STEP n/N". Exit 0 = the VM is ready and powered off. With no image for
# this OmacVM version (or no connection) it builds the VM with create-vm.sh
# instead and says so. OMACVM_CREATE_NO_MAC=1: without the Mac helpers.
# OMACVM_PREBUILT_SOURCE=DIR: an image from a folder (tests, see docs/prebuilt.md).
#
# How: the image's parts are downloaded and each checked against the
# manifest's SHA-256 (src/prebuilt/lib.sh, as for omacvm build --prebuilt),
# unpacked (disk.img stays sparse) and grown to DISK_GB. A small ISO labelled
# OMACVM-SEED carries the answers: user, full name, password hash, the SSH key
# for root, hostname, keyboard, timezone, language. The VM's first boot
# (omacvm-firstboot.service) applies them, without a window. Then OmacVM is
# applied as after a build, the VM shuts down and the seed is deleted. A run
# that fails removes the disk and NVRAM it made, so building again starts over.
#
# The image and its manifest are untrusted until checked: manifest values are
# checked by manifest.py and src/prebuilt/lib.sh, only <bundle>/disk.img is
# taken from the archive and only as a plain file, and text from the guest is
# cut to printable characters (vm-common.sh printable).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
R=$(cd "$OMACVM_SRC/.." && pwd)
info() { log "$*"; }
source "$OMACVM_SRC/prebuilt/lib.sh"

if [[ ${1:-} == --lookup ]]; then
  prebuilt_lookup app 2>/dev/null || exit 1
  echo "$PB_TAG $PB_SIZE ${PB_OMARCHY%% *} $PB_VERSION"
  exit 0
fi

VM_DIR=${1:?usage: prebuilt-vm.sh VM_DIR | --lookup}
vm_load "$VM_DIR"
IFS= read -r PASSWORD || true
[[ -n $PASSWORD ]] || die "no password on stdin"
# OmacVM's Mac helpers and the clock format are built with Apple's tools.
clt_ok || die "Xcode's Command Line Tools are missing: run xcode-select --install, then build again"
[[ ! -e $VM_DIR/disk.img && ! -L $VM_DIR/disk.img ]] || die "$VM_DIR already has a disk"
[[ $DISK_GB =~ ^[0-9]{1,5}$ ]] || die "DISK_GB in vm.env is not a number"
rm -f "$VM_DIR/ready"

STEPS=7
step() { echo "STEP $1/$STEPS $2"; }
SEED=$VM_DIR/seed.iso
MADE_DISK=0 MADE_VARS=0
[[ -e $VM_DIR/efi-vars.fd ]] || MADE_VARS=1
# However this ends: QEMU stops and the seed (it holds the password hash)
# goes. Until the VM is ready, so do the disk and NVRAM this run made: the app's
# Back and Build (or omacvm build again) can start over.
cleanup() {
  if qemu_running; then qemu_quit; fi
  rm -f "$SEED"; rm -rf "$VM_DIR/.unpack"
  [[ -e $VM_DIR/ready ]] && return 0
  if (( MADE_VARS )); then rm -f "$VM_DIR/efi-vars.fd"; fi
  if (( MADE_DISK )) && [[ -e $VM_DIR/disk.img ]]; then
    rm -f "$VM_DIR/disk.img"
    echo "==> removed the unfinished VM's disk: building again starts over"
  fi
}
trap cleanup EXIT

# ---------- 1. which image ----------
step 1 "Looking for a prebuilt VM"
if ! prebuilt_lookup app 2>/dev/null; then
  log "no prebuilt VM for OmacVM $(cat "$R/src/VERSION") (or no connection): building it here instead"
  trap - EXIT
  printf '%s\n' "$PASSWORD" | /bin/bash "$HERE/create-vm.sh" "$VM_DIR"
  exit 0
fi
log "release $PB_TAG: Omarchy $PB_OMARCHY, OmacVM $PB_VERSION"
# Room for the parts and the unpacked disk: a full disk would fail half way.
msg=$(prebuilt_space_ok "$VM_DIR" 2>&1) || die "$msg"
HASH=$(printf '%s' "$PASSWORD" | python3 "$OMACVM_SRC/prebuilt/sha512crypt.py") || die "could not hash the password"
[[ $HASH == '$6$'* ]] || die "could not hash the password"
unset PASSWORD

# ---------- 2. download ----------
step 2 "Downloading the prebuilt VM ($(pb_gb "$PB_SIZE") GB)"
t0=$(date +%s)
prebuilt_download
log "downloaded and checked in $(( $(date +%s) - t0 )) s"

# ---------- 3. unpack ----------
step 3 "Unpacking the VM"
t0=$(date +%s)
# Only <bundle>/disk.img, as a plain file (lib.sh).
MADE_DISK=1
prebuilt_unpack_disk "$VM_DIR/.unpack" "$VM_DIR/disk.img"
prebuilt_cleanup
# The image's disk is the smallest the app offers; the first boot grows the
# file system into the rest.
if pb_disk_bigger "$DISK_GB"; then truncate_file "$VM_DIR/disk.img" $((10#$DISK_GB * 1024 * 1024 * 1024)); fi
efi_vars_create
# The answers for the first boot. QEMU's user network: SSH arrives from 10.0.2.2.
U=$VM_USER FULL=${VM_FULLNAME:-$VM_USER} HOST=${VM_HOSTNAME:-omarchy} KB=${KEYBOARD:-us}
TZ_MAC=${VM_TZ:-UTC} LANG_VM=${VM_LANG:-en_US.UTF-8} TYPE=app SEED_NET=10.0.2.0/24
prebuilt_seed "$SEED"
unset HASH
log "unpacked in $(( $(date +%s) - t0 )) s ($(du -sh "$VM_DIR/disk.img" | cut -f1) on disk)"

# ---------- 4. first boot ----------
step 4 "First boot: your user, keys, keyboard and timezone"
t0=$(date +%s)
qemu_headless firstboot "${QEMU_UEFI[@]}" \
  -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -drive "if=none,id=seed,file=$(qe "$SEED"),format=raw,readonly=on" -device virtio-blk-pci,drive=seed
# The first boot puts the Mac's key in for root early on: SSH answers while it
# still sets up the user. Without the seed it would wait on its console.
wait_ssh 600 || die "the VM did not answer on SSH (log: $LOG/firstboot-console.log)"
# The guest's own log, for the app and the terminal: printable and short.
guest_log() { vssh "$1" < /dev/null 2>/dev/null | head -c 65536 | printable || true; }
# The marker goes when the first boot is done. ssh exits 1 when it is gone, and
# 255 when SSH itself failed (the VM is busy): then ask again.
first_done=0
for ((i = 0; i < 300; i += 3)); do
  qemu_running || die "the VM stopped during its first boot (log: $LOG/firstboot-console.log)"
  rc=0; vssh "test -e /var/lib/omacvm/prebuilt/pending" < /dev/null 2>/dev/null || rc=$?
  if (( rc == 1 )); then first_done=1; break; fi
  if (( rc == 0 )) && vssh "systemctl is-failed -q omacvm-firstboot" < /dev/null 2>/dev/null; then
    die "the first boot failed: $(guest_log "tail -3 /var/log/omacvm-firstboot.log" | tr '\n' ' ' | cut -c1-300)"
  fi
  sleep 3
done
(( first_done )) || die "the first boot did not finish in 5 minutes (log: $LOG/firstboot-console.log)"
guest_log "cat /var/log/omacvm-firstboot.log" | grep '^==>' | head -n 100 || true
log "first boot done in $(( $(date +%s) - t0 )) s"

# ---------- 5. OmacVM in the VM ----------
step 5 "Adding OmacVM to the VM"
# New host keys from the first boot: forget an earlier VM's of this name.
OMA_PIN_RESET=1 run_logged "$LOG/omacvm-install.log" "$HERE/apply-vm.sh" "$VM_DIR" --no-mac ||
  die "OmacVM did not install (log: $LOG/omacvm-install.log)"
touch "$VM_DIR/ready"

# ---------- 6. OmacVM on the Mac ----------
step 6 "Adding OmacVM's helpers on the Mac"
if [[ ${OMACVM_CREATE_NO_MAC:-} == 1 ]]; then
  echo "==> Mac helpers skipped (OMACVM_CREATE_NO_MAC=1)"
else
  run_logged "$LOG/omacvm-mac.log" "$HERE/apply-vm.sh" "$VM_DIR" ||
    echo "WARN: the Mac helpers did not install (log: $LOG/omacvm-mac.log); the VM works without them"
fi

# ---------- 7. done ----------
step 7 "Shutting down"
vssh "systemctl poweroff" < /dev/null 2>/dev/null || true
qemu_wait_exit 120 || qemu_quit
rm -f "$SEED"
disk_bus_virtio
echo "READY $NAME"
