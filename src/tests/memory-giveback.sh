#!/bin/bash
# OmacVM.app gives the VM's cold file cache back to the Mac while macOS is
# compressing the VM (src/memory/guest/giveback.sh, ADR 0059), without a VM:
# the script against a fake /proc and /sys. It takes Inactive(file) less
# 256 MB through memory.reclaim (swappiness=0: file pages only) in 1 GB steps,
# nothing when that is under 64 MB or the balloon does not report free pages,
# the whole cache (drop_caches) only when the kernel has no cold-only way,
# and never touches compaction, the reporting order, swap or zram. Also: the
# app runs it on "compressing" from its bundle, and nothing in the VM runs it
# by itself (an old app with a new VM does nothing new).
#   src/tests/memory-giveback.sh
# Runs it with bash, the VM's /bin/sh. On Linux one more row: a kernel that
# refuses swappiness= (a real EINVAL).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/src/memory/guest/giveback.sh
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
mkroot() {   # DIR ACTIVE_FILE_MB INACTIVE_FILE_MB [FEATURES] [ORDER]
  local d=$1
  mkdir -p "$d/proc/sys/vm" "$d/sys/module/page_reporting/parameters" "$d/sys/fs/cgroup" \
    "$d/sys/bus/virtio/drivers/virtio_balloon/virtio3" "$d/sys/block/zram0"
  printf 'MemTotal:       %d kB\nMemFree:        %d kB\nActive(file):   %d kB\nInactive(file): %d kB\n' \
    $((42035 * 1024)) $((20900 * 1024)) $(($2 * 1024)) $(($3 * 1024)) > "$d/proc/meminfo"
  printf 'Node 0, zone      DMA      0      0      0      0      0      0      0      0      0      0      0\n' > "$d/proc/buddyinfo"
  printf 'Node 0, zone   Normal 200000 100000  50000  10000   1000    100      5      1      0      0      0\n' >> "$d/proc/buddyinfo"
  echo "${5:-6}" > "$d/sys/module/page_reporting/parameters/page_reporting_order"
  echo "${4:-0000110100000000000000000000000000000000000000000000000000000000}" > "$d/sys/bus/virtio/drivers/virtio_balloon/virtio3/features"
  : > "$d/sys/fs/cgroup/memory.reclaim"
  echo 0 > "$d/proc/sys/vm/drop_caches"; echo keep > "$d/proc/sys/vm/compact_memory"
  echo keep > "$d/sys/block/zram0/disksize"; echo keep > "$d/proc/swaps"
}
run() {   # DIR MODE [PAUSE]: the script as the app runs it (sh -c, comment lines left out)
  OMACVM_GIVEBACK_ROOT=$1 OMACVM_GIVEBACK_PAUSE=${3:-0} bash -c "$(grep -v '^[[:space:]]*#' "$S")" giveback "$2"
}
key() { tr ' ' '\n' <<< "$1" | sed -n "s/^$2=//p"; }
untouched() {   # DIR: what the script must never write
  echo "$(cat "$1/proc/sys/vm/compact_memory") $(cat "$1/sys/module/page_reporting/parameters/page_reporting_order") $(cat "$1/sys/block/zram0/disksize") $(cat "$1/proc/swaps")"
}

# The user's VM (42 GB, 2.8 GB active and 12.4 GB cold file cache): 12.4 GB back in 1 GB steps.
mkroot "$T/u" 2850 12700
out=$(run "$T/u" compressing)
expect "cold cache less 256 MB is asked for" "reclaim 12444" "$(key "$out" act) $(key "$out" want_mb)"
expect "in 1 GB steps (13)" 13 "$(key "$out" steps)"
expect "the last step is the rest, file pages only" "$((156 * 1048576)) swappiness=0" "$(cat "$T/u/sys/fs/cgroup/memory.reclaim")"
expect "no full cache drop" 0 "$(cat "$T/u/proc/sys/vm/drop_caches")"
expect "compaction, reporting order, zram, swap untouched" "keep 6 keep keep" "$(untouched "$T/u")"
pages=$((200000 + 100000 * 2 + 50000 * 4 + 10000 * 8 + 1000 * 16 + 100 * 32))
expect "small_free_mb: free blocks under order 6 (256 KiB)" $((pages * $(getconf PAGESIZE) / 1048576)) "$(key "$out" small_free_mb)"
expect "cache before and after, the VM's size, reporting on" "15550 15550 42035 1 6" \
  "$(key "$out" cache_mb) $(key "$out" cache_after_mb) $(key "$out" total_mb) $(key "$out" reporting) $(key "$out" order)"
expect "one line of key=value, at most 200 characters" "1 yes" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ') $([[ ${#out} -le 200 && $out =~ ^[a-z_]+=[a-z0-9-]+( [a-z_]+=[a-z0-9-]+)*$ ]] && echo yes)"

# Little cold cache: nothing (under 64 MB to take).
mkroot "$T/s" 900 300
out=$(run "$T/s" compressing)
expect "under 64 MB of cold cache beyond 256 MB: nothing" "none 44" "$(key "$out" act) $(key "$out" want_mb)"
expect "  memory.reclaim and drop_caches not written" "|0" "$(cat "$T/s/sys/fs/cgroup/memory.reclaim")|$(cat "$T/s/proc/sys/vm/drop_caches")"

# The balloon does not report free pages: freed memory would stay on the Mac anyway.
mkroot "$T/n" 2850 12700 0000100000000000
out=$(run "$T/n" compressing)
expect "balloon without free page reporting: nothing, says so" "norep 0" "$(key "$out" act) $(key "$out" reporting)"
expect "  nothing written" "|0" "$(cat "$T/n/sys/fs/cgroup/memory.reclaim")|$(cat "$T/n/proc/sys/vm/drop_caches")"
mkroot "$T/o" 2850 12700 "" 4294967295
out=$(run "$T/o" compressing)
expect "reporting order not set (no reporting device): nothing" "norep -1" "$(key "$out" act) $(key "$out" order)"

# No memory.reclaim (a kernel before 5.19, no cgroup2): the whole cache, as at macOS's warning.
mkroot "$T/k" 2850 12700
rm "$T/k/sys/fs/cgroup/memory.reclaim"
out=$(run "$T/k" compressing)
expect "no memory.reclaim: drop_caches 1" "drop 1" "$(key "$out" act) $(cat "$T/k/proc/sys/vm/drop_caches")"
expect "  compaction, reporting order, zram, swap untouched" "keep 6 keep keep" "$(untouched "$T/k")"

# A write it cannot do for another reason (EAGAIN in a real VM: nothing more to take): stop, no drop.
if [[ $(id -u) != 0 ]]; then
  mkroot "$T/a" 2850 12700
  chmod 444 "$T/a/sys/fs/cgroup/memory.reclaim"
  out=$(run "$T/a" compressing)
  expect "a refused step that is not EINVAL: stops, no drop" "reclaim 0 0" "$(key "$out" act) $(key "$out" steps) $(cat "$T/a/proc/sys/vm/drop_caches")"
fi

# Linux: a kernel that refuses swappiness= (before 6.11) answers EINVAL: the whole cache.
if [[ $(uname -s) == Linux && -f /proc/self/timerslack_ns ]]; then
  mkroot "$T/e" 2850 12700
  ln -sf /proc/self/timerslack_ns "$T/e/sys/fs/cgroup/memory.reclaim"   # takes only a number: EINVAL
  out=$(run "$T/e" compressing)
  expect "EINVAL (swappiness= unknown): drop_caches 1" "drop 0 1" "$(key "$out" act) $(key "$out" steps) $(cat "$T/e/proc/sys/vm/drop_caches")"
fi

# report: numbers only.
mkroot "$T/r" 2850 12700
out=$(run "$T/r" report)
expect "report writes nothing" "report||0" "$(key "$out" act)|$(cat "$T/r/sys/fs/cgroup/memory.reclaim")|$(cat "$T/r/proc/sys/vm/drop_caches")"
expect "another mode: refused" "act=usage" "$(run "$T/r" idle)"

# At most 20 s (the app waits 30 s for the answer): 1 s between steps here 3 s.
mkroot "$T/t" 2850 12700
start=$(date +%s); out=$(run "$T/t" compressing 3); took=$(( $(date +%s) - start ))
expect "stops after 20 s (7-8 steps at 3 s)" yes "$( (( took <= 24 && $(key "$out" steps) >= 6 && $(key "$out" steps) <= 8 )) && echo yes)"

# What the script may write: memory.reclaim and drop_caches, nothing else.
expect "the script writes only memory.reclaim and drop_caches" "" \
  "$(grep -n -e compact_memory -e swapoff -e swapon -e zram -e 'page_reporting_order *"* *>' -e 'balloon.*>' "$S" | grep -v '^[0-9]*:#' | grep -v 'never programs')"
expect "the command the app sends stays small (under 3 KB)" yes "$( (( $(grep -v '^[[:space:]]*#' "$S" | wc -c) < 3072 )) && echo yes)"

# The app runs it from its bundle on "compressing" (GPUMemory.swift), and nothing in the VM by itself.
G=$R/app/app/Sources/OmacVM/GPUMemory.swift
expect "the app carries the script from its bundle" 1 "$(grep -c '"Contents/Resources/omacvm/src/memory/guest/giveback.sh"' "$G")"
expect "the app runs it with \"compressing\" through runAndWait" "1 1" \
  "$(grep -c '\["-c", script, "giveback", "compressing"\]' "$G") $(grep -c 'GuestAgent.runAndWait' "$G")"
expect "no unit, timer or install line in the VM runs it" "" \
  "$(grep -rl giveback "$R/src" | grep -v -e '^'"$R"'/src/memory/guest/giveback.sh$' -e '^'"$R"'/src/tests/memory-giveback.sh$' -e '^'"$R"'/src/cmd/check.sh$')"
exit $fail
