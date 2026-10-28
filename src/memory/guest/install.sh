#!/bin/bash
# Memory tuning for the guest, every route. Run as root inside the VM: ./install.sh
# Parallels, UTM and Fusion keep every page the guest ever touched until the VM
# stops, so the guest should not hoard: a small zram, smooth reclaim, THP
# without allocation stalls, MGLRU protection. OmacVM.app's balloon takes freed
# memory out of QEMU's footprint (free page reporting); the tmpfiles file sets
# its block size.
set -euo pipefail
cd "$(dirname "$0")"
install -m644 90-omacvm.sysctl /etc/sysctl.d/90-omacvm.conf
install -Dm644 90-omacvm-zram.conf /etc/systemd/zram-generator.conf.d/90-omacvm.conf
install -m644 90-omacvm-mm.tmpfiles /etc/tmpfiles.d/90-omacvm-mm.conf
install -m644 virtio-balloon.modules /etc/modules-load.d/virtio-balloon.conf
sysctl -q --system
systemd-tmpfiles --create /etc/tmpfiles.d/90-omacvm-mm.conf 2>/dev/null || true
echo "memory tuning installed (zram size applies after a reboot)"
