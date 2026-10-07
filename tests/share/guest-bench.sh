#!/bin/bash
# The Mac folder benchmark, inside the VM as root: guest-bench.sh DIR LABEL [REPS]
# One JSON line per run on stdout: big file write/read (MB/s), small files
# (untar, read, stat, delete; seconds), git status in DIR/repo (seconds).
# Needs /root/sf/tree.tar (setup) and a git repo at DIR/repo.
set -uo pipefail
D=$1 LABEL=$2 REPS=${3:-1}
U=$(getent passwd 1000 | cut -d: -f1)
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
now() { date +%s%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", (b - a) / 1e9 }'; }
mbps() { awk -v a="$1" -v b="$2" -v m="$3" 'BEGIN { printf "%.0f", m / ((b - a) / 1e9) }'; }
for ((r = 1; r <= REPS; r++)); do
  rm -rf "$D/big" "$D/small"
  drop; a=$(now); dd if=/dev/zero of="$D/big" bs=1M count=1024 conv=fsync status=none; b=$(now); w=$(mbps "$a" "$b" 1024)
  drop; a=$(now); dd if="$D/big" of=/dev/null bs=1M status=none; b=$(now); rd=$(mbps "$a" "$b" 1024)
  rm -f "$D/big"
  mkdir -p "$D/small"
  drop; a=$(now); tar --no-same-owner -xf /root/sf/tree.tar -C "$D/small"; sync; b=$(now); untar=$(secs "$a" "$b")
  drop; a=$(now); find "$D/small" -type f -print0 | xargs -0 cat > /dev/null; b=$(now); sread=$(secs "$a" "$b")
  a=$(now); find "$D/small" -ls > /dev/null; b=$(now); sstat=$(secs "$a" "$b")
  a=$(now); rm -rf "$D/small"; sync; b=$(now); srm=$(secs "$a" "$b")
  gs() { runuser -u "$U" -- git -C "$D/repo" status --porcelain > /dev/null; }
  a=$(now); gs; b=$(now); gfirst=$(secs "$a" "$b")
  a=$(now); gs; b=$(now); gwarm=$(secs "$a" "$b")
  drop; a=$(now); gs; b=$(now); gcold=$(secs "$a" "$b")
  printf '{"label": "%s", "run": %d, "write_MBps": %s, "read_MBps": %s, "untar_s": %s, "read_small_s": %s, "stat_s": %s, "rm_s": %s, "git_first_s": %s, "git_warm_s": %s, "git_cold_s": %s}\n' \
    "$LABEL" "$r" "$w" "$rd" "$untar" "$sread" "$sstat" "$srm" "$gfirst" "$gwarm" "$gcold"
done
