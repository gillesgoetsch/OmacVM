#!/bin/bash
# Guest side of disk-speed.sh: tests one test disk (found by its serial).
# Runs as root in a throwaway test VM; the test disks hold nothing else.
#   disk-speed-guest.sh SERIAL fio            fio on the raw disk (first 2 GiB)
#   disk-speed-guest.sh SERIAL real           btrfs: git clone + checkouts, pacman install of base
#   disk-speed-guest.sh SERIAL fill MiB       btrfs: write MiB of random data, sync
#   disk-speed-guest.sh SERIAL trim           rm the data, fstrim
#   disk-speed-guest.sh SERIAL zeros MiB      write MiB of zeros to the raw disk at 4 GiB
#   disk-speed-guest.sh SERIAL wipe           unmount, blkdiscard the whole disk
#   disk-speed-guest.sh prep                  fio + git, a git mirror and a package cache (needs the network)
# Prints one JSON object per measurement.
set -euo pipefail
MNT=/mnt/ds
REPO=/root/ds-src.git
PKGS=/root/ds-pkgs
OLD=v2.30.0 NEW=v2.47.0          # git checkouts: far apart, many files change
O=noatime,compress=zstd:1,space_cache=v2,discard=async   # as base-install.sh

now() { date +%s.%N; }
dt() { python3 -c "print(round($2-$1,3))"; }

if [[ $1 == prep ]]; then
  # Also the one real "pacman -Syu" number (network included) on today's system disk.
  t0=$(now); pacman -Syu --noconfirm --noprogressbar > /tmp/syu.log 2>&1; t1=$(now)
  echo "{\"test\":\"syu\",\"s\":$(dt $t0 $t1),\"upgraded\":$(grep -c ') upgrading ' /tmp/syu.log || true)}"
  pacman -S --needed --noconfirm --noprogressbar fio git >/dev/null
  [[ -d $REPO ]] || git clone -q --mirror https://github.com/git/git "$REPO"
  # base and all its dependencies, resolved against an empty root.
  r=$(mktemp -d); mkdir -p "$r/db" "$PKGS"
  cp -r /var/lib/pacman/sync "$r/db/"
  pacman -r "$r" --dbpath "$r/db" --cachedir "$PKGS" -Sw --noconfirm --noprogressbar base >/dev/null
  rm -rf "$r"
  echo "{\"prep\":\"ok\",\"pkgs\":$(ls "$PKGS"/*.pkg.tar.* | wc -l)}"
  exit 0
fi

SER=$1 WHAT=$2
DEV=/dev/$(lsblk -ndo NAME,SERIAL | awk -v s="$SER" '$2 == s {print $1}')
[[ -b $DEV ]] || { echo "no disk with serial $SER" >&2; exit 1; }

fio1() {   # name, fio options...
  local name=$1; shift
  fio --name="$name" --filename="$DEV" --direct=1 --ioengine=libaio --size=2G --offset=0 \
      --refill_buffers --randrepeat=0 --output-format=json "$@" > /tmp/fio.json
  python3 - "$name" "$SER" <<'EOF'
import json, sys
j = json.load(open('/tmp/fio.json'))['jobs'][0]
r, w, s = j['read'], j['write'], j.get('sync', {})
out = {'test': sys.argv[1], 'serial': sys.argv[2],
       'read_mbs': round(r['bw_bytes'] / 1e6, 1), 'read_iops': round(r['iops']),
       'write_mbs': round(w['bw_bytes'] / 1e6, 1), 'write_iops': round(w['iops'])}
for k, d in (('read', r), ('write', w)):
    if d['io_bytes']:
        out[k + '_lat_us'] = round(d['clat_ns']['mean'] / 1000, 1)
        out[k + '_p99_us'] = round(d['clat_ns']['percentile'].get('99.000000', 0) / 1000, 1)
if s.get('total_ios'):
    out['fsync_lat_us'] = round(s['lat_ns']['mean'] / 1000, 1)
print(json.dumps(out))
EOF
}

mounted() { findmnt -n "$MNT" >/dev/null 2>&1; }
mkfs_mount() {
  mounted && umount "$MNT"
  mkfs.btrfs -q -f "$DEV" >/dev/null
  mkdir -p "$MNT"; mount -o "$O" "$DEV" "$MNT"
}

case $WHAT in
fio)
  mounted && umount "$MNT"
  case ${3:-all} in
  write) fio1 seqwrite --rw=write --bs=1M --iodepth=8 ;;
  read)
    fio1 seqread --rw=read --bs=1M --iodepth=8
    fio1 randread-qd32 --rw=randread --bs=4k --iodepth=32 --runtime=10 --time_based
    fio1 randread-qd1 --rw=randread --bs=4k --iodepth=1 --runtime=10 --time_based ;;
  rest)
    fio1 randwrite-qd32 --rw=randwrite --bs=4k --iodepth=32 --runtime=10 --time_based
    fio1 fsync-qd1 --rw=randwrite --bs=4k --iodepth=1 --fsync=1 --runtime=10 --time_based ;;
  esac ;;
real)
  mkfs_mount
  sync; echo 3 > /proc/sys/vm/drop_caches
  t0=$(now); git clone -q --no-local "$REPO" "$MNT/git"; sync; t1=$(now)
  git -C "$MNT/git" checkout -q "$OLD"; sync; t2=$(now)
  echo 3 > /proc/sys/vm/drop_caches
  t3=$(now); git -C "$MNT/git" checkout -q "$NEW"; sync; t4=$(now)
  root=$MNT/root; mkdir -p "$root/var/lib/pacman" "$root/proc" "$root/dev"
  cp -r /var/lib/pacman/sync "$root/var/lib/pacman/"
  mount -t proc proc "$root/proc"; mount --bind /dev "$root/dev"
  echo 3 > /proc/sys/vm/drop_caches
  t5=$(now)
  pacman -r "$root" --cachedir "$PKGS" -S --noconfirm --noprogressbar base > /tmp/pacman.log 2>&1 || true
  sync; t6=$(now)
  umount "$root/dev" "$root/proc"
  n=$(pacman -r "$root" -Q | wc -l)
  echo "{\"test\":\"real\",\"serial\":\"$SER\",\"git_clone_s\":$(dt $t0 $t1),\"git_checkout_old_s\":$(dt $t1 $t2),\"git_checkout_new_s\":$(dt $t3 $t4),\"pacman_base_s\":$(dt $t5 $t6),\"pacman_pkgs\":$n,\"used_mib\":$(df -m --output=used "$MNT" | tail -1)}" ;;
fill)
  mounted || mkfs_mount
  t0=$(now); head -c "$(( $3 * 1048576 ))" /dev/urandom > "$MNT/fill"; sync; t1=$(now)
  echo "{\"test\":\"fill\",\"serial\":\"$SER\",\"mib\":$3,\"s\":$(dt $t0 $t1)}" ;;
trim)
  rm -rf "${MNT:?}"/*; sync
  t0=$(now); out=$(fstrim -v "$MNT"); t1=$(now)
  echo "{\"test\":\"trim\",\"serial\":\"$SER\",\"fstrim\":\"$out\",\"s\":$(dt $t0 $t1)}" ;;
rmonly)
  rm -rf "${MNT:?}"/*; sync
  echo "{\"test\":\"rmonly\",\"serial\":\"$SER\"}" ;;
zeros)
  mounted && umount "$MNT"
  dd if=/dev/zero of="$DEV" bs=1M count="$3" seek=4096 oflag=direct status=none; sync
  echo "{\"test\":\"zeros\",\"serial\":\"$SER\",\"mib\":$3}" ;;
wipe)
  mounted && umount "$MNT"
  blkdiscard -f "$DEV"
  echo "{\"test\":\"wipe\",\"serial\":\"$SER\"}" ;;
esac
