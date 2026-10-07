#!/bin/bash
# OmacVM.app's VMs folders without a VM: moves on one drive and to another (a
# small disk image), sparse disks, cancel, refusals (changes during a move,
# linked folders), half copies left behind, busy folders, downloads,
# Time Machine, the app into ~/Applications. Fixture folders only.
#   src/tests/app-storage.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
MNT=""
cleanup() {
  [[ -z $MNT ]] || hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1 || true
  [[ -z ${HFS:-} ]] || hdiutil detach -quiet -force "$HFS" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/work" "$T/volumes/Real" "$T/volumes/Hfs"
swiftc -O -o "$T/storage-test" "$R/app/app/Sources/OmacVM/Storage.swift" "$R/src/tests/app-storage/main.swift"
# "Another drive": 64 MB, APFS, mounted inside the fixture folder.
hdiutil create -quiet -size 64m -fs APFS -volname OmacVMTest "$T/drive.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$T/volumes/Real" "$T/drive.dmg"
MNT=$T/volumes/Real
# Mac OS Extended: no sparse files.
hdiutil create -quiet -size 64m -fs JHFS+ -volname OmacVMTestHFS "$T/hfs.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$T/volumes/Hfs" "$T/hfs.dmg"
HFS=$T/volumes/Hfs
"$T/storage-test" "$T/work" "$MNT" "$T/volumes" "$HFS"

# The build scripts' rules (app/scripts/vm-common.sh), on the same folders.
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
log() { printf '==> %s\n' "$*"; }
eval "$(sed -n -e '/^downloads_dir()/,/^}/p' -e '/^others_building()/,/^}/p' -e '/^live_reuse()/,/^}/p' "$R/app/scripts/vm-common.sh")"
while IFS=$'\t' read -r root want; do
  expect "downloads_dir agrees with the app: $root" "$want" "$(HOME=$T/work/dlhome downloads_dir "$root")"
done < "$T/work/downloads-rule.tsv"

# The app looks for a prebuilt image first (the setup view), then builds: the
# lookup makes the downloads folder and Time Machine must leave it out anyway.
# The real script, in a copy of the source tree with a stand-in runtime.
F=$T/fake
mkdir -p "$F/app/runtime/.build/qemu-gpu-runtime/bin" "$F/app/runtime/.build/firmware" "$F/empty"
cp -R "$R/app/scripts" "$F/app/scripts"
ln -s "$R/src" "$F/src"
printf '#!/bin/sh\n' > "$F/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
chmod +x "$F/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64"
: > "$F/app/runtime/.build/firmware/edk2-aarch64-code.fd"
dl=$MNT/VMs/.downloads
expect "lookup with no image" 1 "$(OMACVM_CACHE=$dl OMACVM_PREBUILT_SOURCE=$F/empty /bin/bash "$F/app/scripts/prebuilt-vm.sh" --lookup >/dev/null 2>&1; echo $?)"
expect "lookup first: the downloads folder is left out of Time Machine" yes \
  "$([[ -d $dl ]] && tmutil isexcluded "$dl" | grep -q '\[Excluded\]' && echo yes)"
dl2=$MNT/VMs2/.downloads
expect "omacvm build: the lookup uses the VMs folder's downloads" "$dl2" \
  "$(mkdir -p "$MNT/VMs2" && OMACVM_VMS_ROOT=$MNT/VMs2 env -u OMACVM_CACHE /bin/bash -c 'source "$1"; echo "$CACHE"' _ "$F/app/scripts/vm-common.sh")"
expect "sourcing vm-common.sh makes no downloads folder" no "$([[ -e $dl2 ]] && echo yes || echo no)"
expect "no VMs folder given: the Mac's" "$HOME/Library/Caches/omacvm" \
  "$(env -u OMACVM_CACHE -u OMACVM_VMS_ROOT /bin/bash -c 'source "$1"; echo "$CACHE"' _ "$F/app/scripts/vm-common.sh")"

# Another build running: downloads it may read stay. Not one this script
# started (its own children are its own), so through a shell that exits.
fake_build() {
  /bin/bash -c '(exec -a "/bin/bash /x/create-vm.sh /y/Omarchy" sleep 30) >/dev/null 2>&1 & echo $!'
  sleep 0.3
}
expect "no other build" 1 "$(others_building; echo $?)"
( exec -a "/bin/bash /x/create-vm.sh /y/Mine" sleep 30 ) & mine=$!
sleep 0.3
expect "a build this script started is its own" 1 "$(others_building; echo $?)"
kill "$mine"; wait "$mine" 2>/dev/null || true
other=$(fake_build)
expect "another build" 0 "$(others_building; echo $?)"
kill "$other" 2>/dev/null || true

# A live system of an earlier build in another downloads folder moves to the new place.
H=$T/work/dlhome LIVE_RELEASE=v0.4.1 old=$T/work/dlhome/Library/Caches/omacvm/live new=$MNT/VMs/.downloads/live
mkdir -p "$old" "$new"
live() { for f in vmlinuz-linux initramfs-linux.img rootfs.ext4; do printf '%s' "$f" > "$1/$f"; done; }
live "$old"
expect "no reuse without the marker" 1 "$(HOME=$H live_reuse "$new" >/dev/null; echo $?)"
expect "without the marker it is of no use: deleted" no "$([[ -e $old/rootfs.ext4 ]] && echo yes || echo no)"
live "$old"; : > "$old/ok-v0.4.0"
expect "no reuse of another release" 1 "$(HOME=$H live_reuse "$new" >/dev/null; echo $?)"
expect "another release: deleted" no "$([[ -e $old/rootfs.ext4 || -e $old/ok-v0.4.0 ]] && echo yes || echo no)"
live "$old"; : > "$old/ok-v0.4.1"
expect "no reuse into the Mac's cache itself" 1 "$(HOME=$H live_reuse "$old" >/dev/null; echo $?)"
chmod 555 "$new"
expect "a copy that fails: downloads instead" 1 "$(HOME=$H live_reuse "$new" >/dev/null 2>&1; echo $?)"
chmod 755 "$new"
expect "a copy that fails: nothing marked, nothing deleted" yes \
  "$([[ ! -e $new/ok-v0.4.1 && -f $old/rootfs.ext4 && -f $old/ok-v0.4.1 ]] && echo yes)"
other=$(fake_build)
expect "reused while another build runs" 0 "$(HOME=$H live_reuse "$new" >/dev/null; echo $?)"
kill "$other" 2>/dev/null || true
expect "another build runs: copied, the old one stays" yes \
  "$([[ -f $new/ok-v0.4.1 && $(cat "$new/rootfs.ext4") == rootfs.ext4 && -f $old/rootfs.ext4 && -f $old/ok-v0.4.1 ]] && echo yes)"
rm -f "$new"/*
expect "reused" 0 "$(HOME=$H live_reuse "$new" >/dev/null; echo $?)"
expect "moved: files and marker there, gone here" "rootfs.ext4 ok yes" \
  "$(cat "$new/rootfs.ext4") $([[ -f $new/ok-v0.4.1 ]] && echo ok) $([[ ! -e $old/rootfs.ext4 && ! -e $old/ok-v0.4.1 && ! -e $new/.moving ]] && echo yes)"
# Back to the Mac's drive (or another VMs folder): the app names the old folders.
other_dl=$MNT/Old/.downloads; mkdir -p "$other_dl/live"
mv "$new"/* "$other_dl/live/"
expect "reused from an old VMs folder" 0 "$(HOME=$H OMACVM_LIVE_FROM=$'/nowhere\n'$other_dl live_reuse "$old" >/dev/null; echo $?)"
expect "moved back: there, gone from the old folder" yes \
  "$([[ -f $old/ok-v0.4.1 && -f $old/rootfs.ext4 && ! -e $other_dl/live/rootfs.ext4 && ! -e $other_dl/live/ok-v0.4.1 ]] && echo yes)"
(( fail == 0 )) || exit 1
