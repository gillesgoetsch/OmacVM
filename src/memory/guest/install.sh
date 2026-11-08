#!/bin/bash
# Memory tuning for the guest, every route. Run as root inside the VM: ./install.sh
# A VM app keeps every page the guest ever touched until the VM
# stops, so the guest should not hoard: a small zram, smooth reclaim, THP
# without allocation stalls, MGLRU protection. OmacVM.app's balloon takes freed
# memory out of QEMU's footprint (free page reporting); the tmpfiles file sets
# its block size.
set -euo pipefail
cd "$(dirname "$0")"
D=${OMACVM_MEMORY_ROOT:-}   # tests only: a fake root for the files
install -Dm644 90-omacvm.sysctl "$D"/etc/sysctl.d/90-omacvm.conf
install -Dm644 90-omacvm-zram.conf "$D"/etc/systemd/zram-generator.conf.d/90-omacvm.conf
install -Dm644 90-omacvm-mm.tmpfiles "$D"/etc/tmpfiles.d/90-omacvm-mm.conf
install -Dm644 virtio-balloon.modules "$D"/etc/modules-load.d/virtio-balloon.conf
# A kernel replaced since this start (the move to Omarchy 4.5 takes the VM
# to another kernel): its modules are gone, so settings that need one not
# loaded yet (another file's net.core.default_qdisc = fq) fail until the
# restart; then they apply. Ours (vm.*) apply now either way.
if ! out=$(sysctl -q --system 2>&1); then
  if [[ -d ${OMACVM_MODULES_DIR:-/usr/lib/modules}/$(uname -r)/kernel ]]; then echo "$out" >&2; exit 1; fi
  echo "memory tuning: this kernel was replaced since the VM started; the settings that need its modules apply after a restart"
fi
systemd-tmpfiles --create /etc/tmpfiles.d/90-omacvm-mm.conf 2>/dev/null || true
echo "memory tuning installed (zram size applies after a reboot)"
