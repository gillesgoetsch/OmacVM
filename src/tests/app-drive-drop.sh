#!/bin/bash
# OmacVM.app when the drive with a VM's folder drops off: DriveWatch
# (app/app/Sources/OmacVM/DriveWatch.swift) on a small disk image that is
# detached by force under it, a file on it held open as QEMU holds the VM's
# disk; on APFS and on exFAT (SD cards; newer macOS mounts it in user space, FSKit).
# A drive renamed under a running VM is no drop. No VM, no app.
#   src/tests/app-drive-drop.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
MNT=$T/mnt
REN=
cleanup() {
  hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true
  if [[ -n $REN ]]; then
    hdiutil detach -quiet -force "$REN" >/dev/null 2>&1 || true
    hdiutil detach -quiet -force "${REN}R" >/dev/null 2>&1 || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/work" "$MNT"
swiftc -O -o "$T/drive-drop-test" "$R/app/app/Sources/OmacVM/Storage.swift" \
  "$R/app/app/Sources/OmacVM/DriveWatch.swift" "$R/src/tests/app-drive-drop/main.swift"

# exFAT first, without the rename check; then APFS with it.
"$R/src/tests/hdiutil-create.sh" 120 -quiet -size 64m -fs ExFAT -volname OMACVMDROP "$T/exfat.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$T/exfat.dmg"
echo "== exFAT"
"$T/drive-drop-test" "$T/work/exfat" "$MNT" "$T/exfat.dmg" OMACVMDROP
hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true

"$R/src/tests/hdiutil-create.sh" 120 -quiet -size 64m -fs APFS -volname OmacVMDrop "$T/drive.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MNT" "$T/drive.dmg"
# The rename needs a mount point under /Volumes: the last tab field of the
# volume's line. hdiutil does not always print that line last (with other
# images attaching at the same time the disk's own lines can come after it).
"$R/src/tests/hdiutil-create.sh" 120 -quiet -size 64m -fs APFS -volname "OmacVMRen$$" "$T/ren.dmg"
hdiutil attach -nobrowse "$T/ren.dmg" > "$T/ren.out"
REN=$(awk -F'\t' '$NF ~ /^\/Volumes\// { print $NF }' "$T/ren.out")
[[ $REN == /Volumes/* && $REN != *$'\n'* ]] || {
  echo "FAIL rename image not under /Volumes: '$REN'"; cat "$T/ren.out"
  # The image is still attached here: detach its whole disk. Only here, as
  # macOS hands the disk number to the next image once the test freed it.
  d=$(awk -F'\t' '$2 ~ /^GUID_partition_scheme/ { sub(/ +$/, "", $1); print $1 }' "$T/ren.out")
  REN=
  [[ -z $d ]] || hdiutil detach -quiet -force "$d" >/dev/null 2>&1 || true
  exit 1; }
echo "== APFS"
"$T/drive-drop-test" "$T/work/apfs" "$MNT" "$T/drive.dmg" OmacVMDrop "$REN"
