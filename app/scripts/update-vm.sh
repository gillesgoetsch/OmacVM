#!/bin/bash
# Bring an existing OmacVM.app VM up to this app's OmacVM: start it without a
# window, apply OmacVM (as at the end of a build), shut it down. For VMs made
# by an older app: replacing the app does not touch the VM, and a VM from
# before 3.0.0 has no control centre that could ask for the update.
#   update-vm.sh VM_DIR
# Progress lines as create-vm.sh ("==>", "STEP n/N"). Exit 0 = updated and
# powered off. Nothing is deleted: a failed apply leaves the VM as it was
# (omacvm apply rolls its own steps back), and it starts as before.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"

vm_load "${1:?usage: update-vm.sh VM_DIR}"
[[ -f $VM_DIR/disk.img && -f $VM_DIR/efi-vars.fd && -e $VM_DIR/ready ]] || die "$NAME is not a finished VM"
# QEMU names the disk on its command line: one that runs from here or from the
# command line (omacvm start) must not get a second QEMU on the same disk.
if ps -x -U "$(id -u)" -o args= | grep -v grep | grep -qF -- "file=$(qe "$VM_DIR/disk.img"),"; then
  die "$NAME runs: shut it down, then update it"
fi

STEPS=3
step() { echo "STEP $1/$STEPS $2"; }
# However this ends (also the app quitting): the VM shuts down cleanly first,
# it has the user's files.
stop_vm() {
  qemu_running || return 0
  vssh "systemctl poweroff" < /dev/null 2>/dev/null || true
  qemu_wait_exit 90 || qemu_quit
}
trap stop_vm EXIT

step 1 "Starting $NAME without a window"
qemu_headless update "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0
wait_ssh 300 || die "$NAME did not answer on SSH (log: $LOG/update-console.log)"

step 2 "Updating OmacVM in the VM and on the Mac"
run_logged "$LOG/omacvm-update.log" "$HERE/apply-vm.sh" "$VM_DIR" ||
  die "OmacVM did not update (log: $LOG/omacvm-update.log); the VM starts as before"

step 3 "Shutting down"
stop_vm
echo "UPDATED $NAME"
