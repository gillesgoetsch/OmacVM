#!/bin/bash
# The prebuilt image's disk is packed sparse (src/prebuilt/sparsify.py, run by
# make-image.sh): a raw disk whose zeros are allocated (as dd conv=sparse once
# left the app's disk: 62 of 64 GB) gets its zeroed MiBs back as holes, its
# bytes unchanged; tar then packs only the data, and unpacking it
# (unpack.py, src/tests/prebuilt-unpack.sh) gives a sparse disk again. Also:
# the archive names root as the owner, not this Mac's user. macOS (APFS,
# F_PUNCHHOLE) only.
#   src/tests/prebuilt-sparse.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ $(uname) == Darwin ]] || { echo "skip: macOS only (F_PUNCHHOLE)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
kb() { echo $(( $(stat -f %b "$1") / 2 )); }

# 64 MiB, all of it written (zeros allocated), data at the start, at 20 MiB
# (not on a MiB boundary) and in the last MiB.
f=$T/disk.img
dd if=/dev/zero of="$f" bs=1m count=64 status=none
printf 'start' | dd of="$f" conv=notrunc status=none
dd if=/dev/urandom of="$f" bs=4k count=3 seek=$(( 20 * 256 + 5 )) conv=notrunc status=none
printf 'end' | dd of="$f" bs=1 seek=$(( 64 * 1048576 - 3 )) conv=notrunc status=none
sum=$(shasum -a 256 < "$f")
expect "test disk is allocated" 1 "$(( $(kb "$f") >= 60000 ))"
out=$(python3 "$R/src/prebuilt/sparsify.py" "$f"); rc=$?
expect "sparsify.py runs" 0 "$rc"
expect "it prints before and after" 1 "$([[ $out =~ ^[0-9]+\ [0-9]+$ ]] && echo 1)"
expect "zeros became holes (3 MiB of data left at most)" 1 "$(( $(kb "$f") <= 3 * 1024 ))"
expect "bytes unchanged" "$sum" "$(shasum -a 256 < "$f")"
expect "size unchanged" 67108864 "$(stat -f %z "$f")"
before=$(kb "$f"); python3 "$R/src/prebuilt/sparsify.py" "$f" >/dev/null
expect "a sparse disk stays as it is" "$before $sum" "$(kb "$f") $(shasum -a 256 < "$f")"
# all zeros: nothing allocated afterwards
z=$T/zero.img; dd if=/dev/zero of="$z" bs=1m count=8 status=none
python3 "$R/src/prebuilt/sparsify.py" "$z" >/dev/null
expect "an all-zero disk becomes one hole" 0 "$(kb "$z")"

# Packed and unpacked as make-image.sh and prebuilt-vm.sh do: sparse again.
mkdir -p "$T/w/Omarchy" "$T/x"; mv "$f" "$T/w/Omarchy/disk.img"
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname root -C "$T/w" -cf "$T/img.tar" Omarchy
expect "archive holds the data only" 1 "$(( $(stat -f %z "$T/img.tar") < 8 * 1048576 ))"
expect "archive owner is root, not this Mac's user" "root/root" \
  "$(tar -tvf "$T/img.tar" | awk '{ print $3 "/" $4 }' | sort -u | paste -sd' ' -)"
python3 -I "$R/src/prebuilt/unpack.py" extract Omarchy/disk.img "$T/x/disk.img" 67108864 < "$T/img.tar"
expect "unpacked: bytes unchanged" "$sum" "$(shasum -a 256 < "$T/x/disk.img")"
expect "unpacked: sparse" 1 "$(( $(kb "$T/x/disk.img") <= 3 * 1024 ))"

# make-image.sh makes the app's disk sparse when it packs and repacks it, and
# stops when it is still mostly allocated.
M=$R/src/prebuilt/make-image.sh
expect "package: app disk made sparse after the copy" 1 \
  "$(grep -A2 'unpack.py" copy "$b/disk.img" "$stage/disk.img"' "$M" | grep -c 'sparse_disk "$stage/disk.img"')"
expect "repack: app disk made sparse" 1 "$(awk '/^stage_repack\(\) \{/ {on=1} on && /sparse_disk "\$stage\/disk.img"/ {n++} on && /^}$/ {exit} END {print n+0}' "$M")"
expect "sparse_disk stops on a disk still half allocated" 1 "$(grep -c 'kb < PREBUILT_DISK_GB \* 1048576 / 2' "$M")"
expect "tar names root as the owner" 1 "$(grep -c 'tar --no-xattrs --uid 0 --gid 0 --uname root --gname root' "$M")"

# A VM's disk.img that takes more than half its size on the Mac after the
# unpack or the setup is made sparse there (#305: a fresh 3.0.9 setup on macOS
# 15.8.1 took 61 of 64 GB); a sparse one is left alone.
(
  source "$R/src/lib/mac.sh"; source "$R/src/prebuilt/lib.sh"
  g=$T/vm.img
  dd if=/dev/zero of="$g" bs=1m count=32 status=none
  printf 'data' | dd of="$g" conv=notrunc status=none
  gsum=$(shasum -a 256 < "$g")
  msg=$(prebuilt_compact "$g")
  expect "compact: an allocated disk becomes sparse" 1 "$(( $(kb "$g") <= 1024 ))"
  expect "compact: bytes unchanged" "$gsum" "$(shasum -a 256 < "$g")"
  expect "compact: it says so" 1 "$([[ $msg == *"zeros made holes"* ]] && echo 1)"
  msg=$(prebuilt_compact "$g")
  expect "compact: a sparse disk is left alone" "" "$msg"
  dd if=/dev/zero of="$g" bs=1m count=32 conv=notrunc status=none
  msg=$(prebuilt_compact "$g" unpack)
  expect "compact: right after the unpack it warns" 1 "$([[ $msg == "WARN: right after the unpack, disk.img took"* ]] && echo 1)"
  (( fail )) && exit 1; exit 0
) || fail=1
expect "unpack: the app's disk is checked, a warning if it was not sparse" 1 "$(grep -A3 'mv "$f" "$2"' "$R/src/prebuilt/lib.sh" | grep -c 'prebuilt_compact "$2" unpack')"
expect "setup: compacted once the VM is off" 1 "$(grep -c 'qemu_running || prebuilt_compact "$VM_DIR/disk.img"' "$R/app/scripts/prebuilt-vm.sh")"

(( fail )) && { echo "prebuilt-sparse: FAILED"; exit 1; }
echo "prebuilt-sparse: all passed"
