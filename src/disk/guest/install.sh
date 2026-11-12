#!/bin/bash
# The VM's own disks without an I/O scheduler, every route. Run as root inside
# the VM: ./install.sh
# The Mac does the real I/O scheduling for the VM's disk file; a scheduler in
# the guest only adds work. Omarchy 4.5 sets kyber on every disk when it
# appears and on every change event
# (/etc/udev/rules.d/60-omarchy-io-scheduler.rules): about half of none's 4k
# random reads and writes at queue depth 32 (#778). OmacVM's rule is read
# after it, on the same events, and sets none again, only on QEMU's NVMe and
# virtio disks: a USB disk passed in keeps Omarchy's choice. The file name
# sorts after Omarchy's 60- and before a rule of the user's own (99-*.rules).
# OmacVM has no uninstall inside the VM: the rule acts only while
# /etc/omacvm/env is there, so without OmacVM's record the disks go back to
# Omarchy's choice at the next start.
set -euo pipefail
cd "$(dirname "$0")"
D=${OMACVM_DISK_ROOT:-}   # tests only: a fake root for the files
install -Dm644 61-omacvm-io-scheduler.rules "$D"/etc/udev/rules.d/61-omacvm-io-scheduler.rules
[[ -z $D ]] || exit 0
# The running VM: udev reads the rule again and runs it for these disks now.
udevadm control --reload 2>/dev/null || true
udevadm trigger --action=change --subsystem-match=block --property-match=DEVTYPE=disk --sysname-match='nvme*' --sysname-match='vd*' 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true
echo "disk: no I/O scheduler on the VM's own disks"
