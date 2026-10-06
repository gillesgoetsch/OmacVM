#!/bin/bash
# Build a new OmacVM VM from nothing: Arch Linux ARM + Omarchy (omarchy-mac) on
# one raw disk that boots through UEFI and GRUB. 10-30 minutes, mostly downloads.
#
#   create-vm.sh VM_DIR        (OMACVM_CREATE_NO_MAC=1: without the Mac helpers;
#                               OMACVM_CREATE_IMAGE=1: for a prebuilt image, nothing of this Mac)
#
# VM_DIR/vm.env must exist (the app writes it): NAME CPUS MEM_MB DISK_GB SSH_PORT
#   VM_USER VM_FULLNAME VM_HOSTNAME VM_TZ VM_LANG KEYBOARD [FEATURES="bridge=on ..."]
# The password comes on stdin (one line). Progress lines start with "==>",
# steps with "STEP n/N". Exit 0 = the VM is ready and powered off.
#
# Steps: try-omarchy (MIT) boots as a temporary live system, OmacVM's
# base-install.sh puts Arch Linux ARM on the disk, omarchy-install.sh adds
# Omarchy, guest/install.sh adds OmacVM. Same as the omacvm command's routes.
set -euo pipefail
VM_DIR=${1:?usage: create-vm.sh VM_DIR}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
IFS= read -r PASSWORD || true
[[ -n $PASSWORD ]] || die "no password on stdin"
# OmacVM's Mac helpers and the clock format are built here with Apple's tools.
clt_ok || die "Xcode's Command Line Tools are missing: run xcode-select --install, then build again"

STEPS=7
step() { echo "STEP $1/$STEPS $2"; }
LOG=$VM_DIR/logs
mkdir -p "$LOG"
# Time Machine leaves the VM out: its disk changes all the time (the sticky
# flag, no admin needed; it moves with the folder).
tmutil addexclusion "$VM_DIR" >/dev/null 2>&1 || true
trap 'qemu_running && qemu_quit; rm -f "$VM_DIR/live.img"' EXIT

# ---------- 1. the live system ----------
step 1 "Getting the temporary live system (try-omarchy, 1.4 GB once)"
live_fetch                         # sets LIVE_KERNEL LIVE_INITRD LIVE_ROOTFS
LIVE_IMG=$VM_DIR/live.img
cp -c "$LIVE_ROOTFS" "$LIVE_IMG" 2>/dev/null || cp "$LIVE_ROOTFS" "$LIVE_IMG"
truncate_file "$LIVE_IMG" $((16 * 1024 * 1024 * 1024))   # the live system grows into it
[[ -f $VM_DIR/disk.img ]] || truncate_file "$VM_DIR/disk.img" $((DISK_GB * 1024 * 1024 * 1024))
efi_vars_create

log "starting the live system"
key_b64=$(base64 < "$KEY.pub" | tr -d '\n')
# Through UEFI, so the installer can register GRUB as a boot entry.
qemu_headless live "${QEMU_UEFI[@]}" -kernel "$LIVE_KERNEL" -initrd "$LIVE_INITRD" \
  -append "root=/dev/vda rw rootwait console=ttyAMA0 loglevel=4 tryomarchy.ssh_access=1 systemd.set_credential_binary=ssh.authorized_keys.root:$key_b64" \
  -drive "if=none,id=live,file=$(qe "$LIVE_IMG"),format=raw,cache=unsafe" -device virtio-blk-pci,drive=live \
  -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk
wait_ssh 300 || die "the live system did not answer on SSH (log: $LOG/live-console.log)"

# ---------- 2. Arch Linux ARM ----------
step 2 "Installing Arch Linux ARM onto the disk"
HASH=$(printf '%s' "$PASSWORD" | vssh "openssl passwd -6 -stdin") || die "could not hash the password"
[[ $HASH == '$6$'* ]] || die "could not hash the password"
read -r kb_layout kb_variant <<<"$KEYBOARD"
printf 'OMA_USER=%q\nOMA_FULLNAME=%q\nOMA_HASH=%q\nOMA_TZ=%q\nOMA_LANG=%q\nOMA_HOSTNAME=%q\nOMA_XKB_LAYOUT=%q\nOMA_XKB_VARIANT=%q\n' \
  "$VM_USER" "$VM_FULLNAME" "$HASH" "$VM_TZ" "$VM_LANG" "$VM_HOSTNAME" "$kb_layout" "${kb_variant:-}" |
  vssh "umask 077; cat > /root/omacvm.env"
vssh "cat > /root/omacvm.pub" < "$KEY.pub"
if ! run_logged "$LOG/base-install.log" vssh "bash -s" < "$OMACVM_SRC/vm/base-install.sh"; then
  # pacstrap's full output is only in the live system: keep it with the log.
  { echo "---- /root/pacstrap.log ----"; vssh "cat /root/pacstrap.log" < /dev/null; } >> "$LOG/base-install.log" 2>&1 || true
  die "the Arch Linux ARM install failed (log: $LOG/base-install.log)"
fi
vssh "systemctl poweroff" 2>/dev/null || true
qemu_wait_exit 120 || die "the live system did not shut down"
rm -f "$LIVE_IMG"

# ---------- 3. first boot from the disk ----------
step 3 "Starting the new system (UEFI, GRUB)"
qemu_headless system "${QEMU_UEFI[@]}" \
  -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0
wait_ssh 300 || die "the new system did not answer on SSH (log: $LOG/system-console.log)"

# ---------- 4. Omarchy ----------
step 4 "Installing Omarchy (omarchy-mac, 20-40 minutes)"
CHANNEL=$(omarchy_channel)
run_logged "$LOG/omarchy-install.log" vssh "OMARCHY_MAC_CHANNEL=$CHANNEL bash -s" < "$OMACVM_SRC/vm/omarchy-install.sh" ||
  die "Omarchy did not install (log: $LOG/omarchy-install.log)"
vssh "rm -f /root/omacvm.env"   # it holds the password hash

# ---------- 5. OmacVM in the VM ----------
step 5 "Adding OmacVM to the VM"
# A new system: forget the host key of an earlier VM of the same name.
apply_mode=--no-mac; [[ ${OMACVM_CREATE_IMAGE:-} == 1 ]] && apply_mode=--image
OMA_PIN_RESET=1 run_logged "$LOG/omacvm-install.log" "$HERE/apply-vm.sh" "$VM_DIR" "$apply_mode" ||
  die "OmacVM did not install (log: $LOG/omacvm-install.log)"
touch "$VM_DIR/ready"   # the VM works from here on, Mac helpers or not

# ---------- 6. OmacVM on the Mac ----------
step 6 "Adding OmacVM's helpers on the Mac"
# OMACVM_CREATE_NO_MAC=1 (test VMs): leave the Mac's helpers as they are.
if [[ ${OMACVM_CREATE_NO_MAC:-} == 1 || ${OMACVM_CREATE_IMAGE:-} == 1 ]]; then
  echo "==> Mac helpers skipped (OMACVM_CREATE_NO_MAC=1)"
else
  run_logged "$LOG/omacvm-mac.log" "$HERE/apply-vm.sh" "$VM_DIR" ||
    echo "WARN: the Mac helpers did not install (log: $LOG/omacvm-mac.log); the VM works without them"
fi

# ---------- 7. done ----------
step 7 "Shutting down"
vssh "systemctl poweroff" 2>/dev/null || true
qemu_wait_exit 120 || qemu_quit
disk_bus_virtio
echo "READY $NAME"
