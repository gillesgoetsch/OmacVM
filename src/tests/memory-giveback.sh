#!/bin/bash
# OmacVM.app gives the VM's cold file cache and its scattered free memory back
# (src/memory/guest/giveback.sh, ADR 0059), without a VM: the script against a
# fake /proc and /sys.
# compressing (macOS compresses the VM): Inactive(file) less min(1 GB, an
# eighth of the VM) through memory.reclaim (swappiness=0: file pages only) in
# 1 GB steps; nothing when that is under 64 MB or the balloon does not report
# free pages; the whole cache (drop_caches) only when the kernel has no
# cold-only way. idle (the VM is quiet): the same above min(2 GB, a quarter of
# the VM), never the whole cache, act=busy when the VM's PSI says it is busy,
# its cache left alone on the memory-optimized kernel (MGLRU). compact (after
# the warning's drop): compaction only. Each ends with one write to
# compact_memory when 256 MB or more is free in blocks under the reporting
# order and memory PSI some avg10 <= 0.10, killed at its time cap, one run at a
# time (flock). Never the reporting order, swap or zram. Also: the app runs it
# from its bundle, and nothing in the VM runs it by itself (an old app with a
# new VM does nothing new).
#   src/tests/memory-giveback.sh
# Runs it with bash, the VM's /bin/sh. On Linux one more row: a kernel that
# refuses swappiness= (a real EINVAL). macOS has no timeout(1) or flock(1):
# stand-ins (KILL after N s; a flock(2) on the inherited descriptor).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/src/memory/guest/giveback.sh
M=$R/app/app/Sources/OmacVMDesktop/MemoryGiveBack.swift
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
mkdir "$T/bin"
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$T/bin/timeout" <<'SH'
#!/bin/bash
# timeout [-s SIG] N CMD...: a stand-in for coreutils' (exit 128 + SIG when it had to kill)
sig=TERM; [[ $1 == -s ]] && { sig=$2; shift 2; }
n=$1; shift
"$@" & p=$!
( trap 'kill "$s" 2>/dev/null; exit 0' TERM; sleep "$n" & s=$!; wait "$s"; kill -"$sig" "$p" 2>/dev/null ) & w=$!
wait "$p"; rc=$?
kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
exit "$rc"
SH
fi
if ! command -v flock >/dev/null 2>&1; then
  cat > "$T/bin/flock" <<'SH'
#!/bin/bash
# flock -n FD: a stand-in for util-linux's, on the descriptor the caller holds (the lock stays with it)
[[ $1 == -n ]] && shift
exec /usr/bin/python3 -I -c 'import fcntl, sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)' "$1" 2>/dev/null
SH
fi
chmod +x "$T"/bin/* 2>/dev/null
export PATH="$T/bin:$PATH"
PG=$(getconf PAGESIZE)
mkroot() {   # DIR ACTIVE_FILE_MB INACTIVE_FILE_MB [FEATURES] [ORDER] [SMALL_FREE_MB]
  local d=$1 sp=$(( ${6:-1191} * 1048576 / PG ))
  mkdir -p "$d/proc/sys/vm" "$d/proc/pressure" "$d/sys/module/page_reporting/parameters" "$d/sys/fs/cgroup" \
    "$d/sys/bus/virtio/drivers/virtio_balloon/virtio3" "$d/sys/block/zram0" "$d/run"
  printf 'MemTotal:       %d kB\nMemFree:        %d kB\nActive(file):   %d kB\nInactive(file): %d kB\n' \
    $((42035 * 1024)) $((20900 * 1024)) $(($2 * 1024)) $(($3 * 1024)) > "$d/proc/meminfo"
  # SMALL_FREE_MB of free memory in 4 KiB pages (under order 6), and 4 GB in 4 MB blocks (order 10).
  printf 'Node 0, zone      DMA      0      0      0      0      0      0      0      0      0      0      0\n' > "$d/proc/buddyinfo"
  printf 'Node 0, zone   Normal %d      0      0      0      0      0      0      0      0      0 %d\n' "$sp" $(( 4096 * 1048576 / PG / 1024 )) >> "$d/proc/buddyinfo"
  echo "${5:-6}" > "$d/sys/module/page_reporting/parameters/page_reporting_order"
  echo "${4:-0000110100000000000000000000000000000000000000000000000000000000}" > "$d/sys/bus/virtio/drivers/virtio_balloon/virtio3/features"
  : > "$d/sys/fs/cgroup/memory.reclaim"
  echo 0 > "$d/proc/sys/vm/drop_caches"; echo keep > "$d/proc/sys/vm/compact_memory"
  echo keep > "$d/sys/block/zram0/disksize"; echo keep > "$d/proc/swaps"
  psi "$d" 0.00 0.00
  printf 'nr_free_pages 1\nworkingset_refault_file %d\nworkingset_refault_anon 9\n' $(( 300 * 1048576 / PG )) > "$d/proc/vmstat"
}
psi() {   # DIR MEMORY_AVG10 IO_AVG10: the VM's pressure (PSI) as the kernel writes it
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$2" > "$1/proc/pressure/memory"
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$3" > "$1/proc/pressure/io"
}
run() {   # DIR MODE [PAUSE] [BUDGET]: the script as the app runs it (sh -c, comment lines left out)
  OMACVM_GIVEBACK_ROOT=$1 OMACVM_GIVEBACK_PAUSE=${3:-0} OMACVM_GIVEBACK_BUDGET=${4:-25} bash -c "$(grep -v '^[[:space:]]*#' "$S")" giveback "$2"
}
key() { tr ' ' '\n' <<< "$1" | sed -n "s/^$2=//p"; }
untouched() {   # DIR: what the script must never write
  echo "$(cat "$1/sys/module/page_reporting/parameters/page_reporting_order") $(cat "$1/sys/block/zram0/disksize") $(cat "$1/proc/swaps")"
}
cm() { cat "$1/proc/sys/vm/compact_memory"; }

# The user's VM (42 GB, 2.8 GB active and 12.4 GB cold file cache, 1191 MB free in blocks too small to report, as on
# the M1 after Chrome closed): all but the newest 1 GB, in 1 GB steps, then one compaction.
mkroot "$T/u" 2850 12700
out=$(run "$T/u" compressing)
expect "cold cache less 1 GB is asked for" "reclaim 11676" "$(key "$out" act) $(key "$out" want)"
expect "in 1 GB steps (12)" 12 "$(key "$out" steps)"
expect "the last step is the rest, file pages only" "$((412 * 1048576)) swappiness=0" "$(cat "$T/u/sys/fs/cgroup/memory.reclaim")"
expect "no full cache drop" 0 "$(cat "$T/u/proc/sys/vm/drop_caches")"
expect "1191 MB in blocks under order 6 (256 KiB), the VM not waiting for memory: one write to compact_memory" "1 ran 1191" \
  "$(cm "$T/u") $(key "$out" cpt) $(key "$out" small)"
expect "reporting order, zram, swap untouched" "6 keep keep" "$(untouched "$T/u")"
expect "cache before and after, refaults, reporting on" "15550 15550 300 1 6" \
  "$(key "$out" cache) $(key "$out" cache_to) $(key "$out" rf) $(key "$out" rep) $(key "$out" order)"
expect "one line of key=value, at most 200 characters" "1 yes" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ') $([[ ${#out} -le 200 && $out =~ ^[a-z_]+=[a-z0-9.-]+( [a-z_]+=[a-z0-9.-]+)*$ ]] && echo yes)"

# A 4 GB VM (the MacBook Air row): the newest eighth of it stays, 487 MB of 3.9 GB.
mkroot "$T/f" 891 1875
sed -i.bak "s/^MemTotal:.*/MemTotal:       $((3899 * 1024)) kB/" "$T/f/proc/meminfo"
out=$(run "$T/f" compressing)
expect "a 4 GB VM keeps its newest eighth" "reclaim 1388 2" "$(key "$out" act) $(key "$out" want) $(key "$out" steps)"

# Little cold cache: no reclaim; little small free memory: no compaction.
mkroot "$T/s" 900 1068 "" "" 200
out=$(run "$T/s" compressing)
expect "under 64 MB of cold cache beyond the newest 1 GB: nothing" "none 44" "$(key "$out" act) $(key "$out" want)"
expect "  memory.reclaim, drop_caches, compact_memory not written (200 MB in small blocks: under 256)" "|0|keep|small" \
  "$(cat "$T/s/sys/fs/cgroup/memory.reclaim")|$(cat "$T/s/proc/sys/vm/drop_caches")|$(cm "$T/s")|$(key "$out" cpt)"

# The VM waits for memory (PSI memory some avg10 0.25): while macOS compresses the cache still goes, no compaction.
mkroot "$T/p" 2850 12700
psi "$T/p" 0.25 0.00
out=$(run "$T/p" compressing)
expect "PSI busy while macOS compresses: the cold cache, no compaction" "reclaim busy keep 0.25" "$(key "$out" act) $(key "$out" cpt) $(cm "$T/p") $(key "$out" psi)"

# The balloon does not report free pages: freed memory would stay on the Mac anyway.
mkroot "$T/n" 2850 12700 0000100000000000
out=$(run "$T/n" compressing)
expect "balloon without free page reporting: nothing, says so" "norep 0" "$(key "$out" act) $(key "$out" rep)"
expect "  nothing written" "|0|keep" "$(cat "$T/n/sys/fs/cgroup/memory.reclaim")|$(cat "$T/n/proc/sys/vm/drop_caches")|$(cm "$T/n")"
mkroot "$T/o" 2850 12700 "" 4294967295
out=$(run "$T/o" compressing)
expect "reporting order not set (no reporting device): nothing" "norep -1" "$(key "$out" act) $(key "$out" order)"
out=$(run "$T/o" compact)
expect "  compact: nothing either" "norep keep" "$(key "$out" act) $(cm "$T/o")"

# No memory.reclaim (a kernel before 5.19, no cgroup2): the whole cache, as at macOS's warning.
mkroot "$T/k" 2850 12700
rm "$T/k/sys/fs/cgroup/memory.reclaim"
out=$(run "$T/k" compressing)
expect "no memory.reclaim: drop_caches 1, then compaction" "drop 1 1" "$(key "$out" act) $(cat "$T/k/proc/sys/vm/drop_caches") $(cm "$T/k")"
expect "  reporting order, zram, swap untouched" "6 keep keep" "$(untouched "$T/k")"

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
  mkroot "$T/e2" 2850 12700
  ln -sf /proc/self/timerslack_ns "$T/e2/sys/fs/cgroup/memory.reclaim"
  out=$(run "$T/e2" idle)
  expect "  idle: the cache stays (no drop), compaction still" "refused 0 1" "$(key "$out" act) $(cat "$T/e2/proc/sys/vm/drop_caches") $(cm "$T/e2")"
fi

# idle: the VM is quiet. Cold cache above the newest min(2 GB, a quarter of the VM), then compaction.
mkroot "$T/i" 2850 12700
out=$(run "$T/i" idle)
expect "idle, Inactive(file) above the keep: memory.reclaim, all but the newest 2 GB" "reclaim 10652 11" "$(key "$out" act) $(key "$out" want) $(key "$out" steps)"
expect "  the last step is the rest, file pages only; then compaction" "$((412 * 1048576)) swappiness=0 1 ran" \
  "$(cat "$T/i/sys/fs/cgroup/memory.reclaim") $(cm "$T/i") $(key "$out" cpt)"
expect "  never the whole cache" 0 "$(cat "$T/i/proc/sys/vm/drop_caches")"
mkroot "$T/i4" 891 1875
sed -i.bak "s/^MemTotal:.*/MemTotal:       $((3899 * 1024)) kB/" "$T/i4/proc/meminfo"
out=$(run "$T/i4" idle)
expect "  a 4 GB VM keeps its newest quarter (974 MB)" "reclaim 901" "$(key "$out" act) $(key "$out" want)"
for b in "0.25 0.00" "0.00 2.50"; do
  mkroot "$T/b" 2850 12700
  psi "$T/b" $b
  out=$(run "$T/b" idle)
  expect "idle, the VM busy by its PSI (memory, io: $b): act=busy, nothing written" "busy|0|keep" \
    "$(key "$out" act)|$(cat "$T/b/sys/fs/cgroup/memory.reclaim" | wc -c | tr -d ' ')|$(cm "$T/b")"
done
mkroot "$T/g" 0 12700
mkdir -p "$T/g/sys/kernel/mm/lru_gen"; echo 0x0007 > "$T/g/sys/kernel/mm/lru_gen/enabled"
out=$(run "$T/g" idle)
expect "idle on the memory-optimized kernel (MGLRU on): its cache stays, compaction still" "mglru 0 1" \
  "$(key "$out" act) $(cat "$T/g/sys/fs/cgroup/memory.reclaim" | wc -c | tr -d ' ') $(cm "$T/g")"
echo 0x0000 > "$T/g/sys/kernel/mm/lru_gen/enabled"; echo keep > "$T/g/proc/sys/vm/compact_memory"
expect "  MGLRU built in but off: as the stock kernel" "reclaim" "$(key "$(run "$T/g" idle)" act)"

# compact (after the warning's drop, the pressure normal again): compaction only.
mkroot "$T/c" 2850 12700
out=$(run "$T/c" compact)
expect "compact: one write to compact_memory, the cache untouched" "compact ran 1 0" \
  "$(key "$out" act) $(key "$out" cpt) $(cm "$T/c") $(cat "$T/c/sys/fs/cgroup/memory.reclaim" | wc -c | tr -d ' ')"
expect "  small free before and after, the time" yes "$([[ $(key "$out" small) == 1191 && $(key "$out" small_to) =~ ^[0-9]+$ && $(key "$out" cpt_ms) =~ ^[0-9]+$ ]] && echo yes)"
rm -r "$T/c/proc/pressure"; echo keep > "$T/c/proc/sys/vm/compact_memory"
out=$(run "$T/c" compact)
expect "no /proc/pressure (a kernel without PSI): no compaction" "nopsi keep na" "$(key "$out" cpt) $(cm "$T/c") $(key "$out" psi)"
mkroot "$T/c2" 2850 12700
rm "$T/c2/proc/sys/vm/compact_memory"
out=$(run "$T/c2" compact)
expect "no compact_memory (a kernel without compaction): none" "no" "$(key "$out" cpt)"
out=$(run "$T/c2" idle)
expect "  idle there: the cache still" "reclaim no" "$(key "$out" act) $(key "$out" cpt)"

# A compaction that does not end (compact_memory a FIFO nobody reads): killed at its cap (budget 4 s here).
mkroot "$T/x" 2850 12700
rm "$T/x/proc/sys/vm/compact_memory"; mkfifo "$T/x/proc/sys/vm/compact_memory"
start=$(date +%s); out=$(run "$T/x" compact 0 4); took=$(( $(date +%s) - start ))
expect "a blocking compact_memory: killed at the cap, the script ends" "cap yes" "$(key "$out" cpt) $( (( took >= 3 && took <= 7 )) && echo yes)"
# One at a time: a retry while the first still runs in the VM (the app stopped waiting) does nothing.
( run "$T/x" compact 0 6 > "$T/x.first" ) & first=$!
sleep 1.5
out=$(run "$T/x" idle)
expect "a second run while the first holds the lock: act=locked, nothing written" "locked skip 0" \
  "$(key "$out" act) $(key "$out" cpt) $(cat "$T/x/sys/fs/cgroup/memory.reclaim" | wc -c | tr -d ' ')"
wait "$first"
expect "  the first ran to its cap; afterwards the next one runs" "cap reclaim" "$(key "$(cat "$T/x.first")" cpt) $(key "$(run "$T/x" idle 0 4)" act)"
# No flock in the VM: the cache as before, no compaction.
mkdir "$T/nf"; for c in awk cat cut date getconf sed sleep sync touch tr bash sh; do ln -s "$(command -v "$c")" "$T/nf/$c"; done
ln -s "$(command -v timeout)" "$T/nf/timeout"
mkroot "$T/l" 2850 12700
out=$(PATH=$T/nf OMACVM_GIVEBACK_ROOT=$T/l OMACVM_GIVEBACK_PAUSE=0 "$T/nf/bash" -c "$(grep -v '^[[:space:]]*#' "$S")" giveback idle)
expect "no flock: the cache, no compaction" "reclaim no keep" "$(key "$out" act) $(key "$out" cpt) $(cm "$T/l")"

# The line stays within 200 characters with the biggest numbers (a 128 GB VM, 7-digit refaults, PSI 99.99).
mkroot "$T/w" 131072 131072 "" "" 131072
sed -i.bak "s/^MemTotal:.*/MemTotal:       $((131072 * 1024)) kB/" "$T/w/proc/meminfo"
psi "$T/w" 99.99 0.00
printf 'workingset_refault_file %d\n' $(( 9999999 * (1048576 / PG) )) > "$T/w/proc/vmstat"
rm "$T/w/sys/fs/cgroup/memory.reclaim"
out=$(OMACVM_GIVEBACK_ROOT=$T/w OMACVM_GIVEBACK_PAUSE=0 bash -c "$(grep -v '^[[:space:]]*#' "$S" | sed 's/echo 1 > "$R\/proc\/sys\/vm\/drop_caches" \&\& //')" giveback compressing)
expect "the longest line: at most 200 characters (${#out})" yes "$([[ ${#out} -le 200 && $(key "$out" rf) == 9999999 ]] && echo yes)"

# report: numbers only.
mkroot "$T/r" 2850 12700
out=$(run "$T/r" report)
expect "report writes nothing" "report||0|keep|skip" "$(key "$out" act)|$(cat "$T/r/sys/fs/cgroup/memory.reclaim")|$(cat "$T/r/proc/sys/vm/drop_caches")|$(cm "$T/r")|$(key "$out" cpt)"
expect "another mode: refused" "act=usage" "$(run "$T/r" warm)"

# At most 20 s (the app waits 30 s for the answer): 1 s between steps here 3 s.
mkroot "$T/t" 2850 12700
start=$(date +%s); out=$(run "$T/t" compressing 3); took=$(( $(date +%s) - start ))
expect "stops after 20 s (7-8 steps at 3 s)" yes "$( (( took <= 24 && $(key "$out" steps) >= 6 && $(key "$out" steps) <= 8 )) && echo yes)"

# What the script may write: memory.reclaim ($f), drop_caches, compact_memory (as $1 of the sh under timeout -s KILL)
# and its lock file, nothing else.
expect "the script writes only memory.reclaim, drop_caches, compact_memory and its lock" \
  '> "$1"|> "$R/proc/sys/vm/drop_caches"|> "$f"|>>"$L"' \
  "$(grep -v '^[[:space:]]*#' "$S" | grep -o -E '>>? *"[^"]*"' | LC_ALL=C sort -u | paste -sd '|' -)"
expect "  \$f is memory.reclaim, \$1 compact_memory under timeout -s KILL, \$L the lock in /run" "1 1 1" \
  "$(grep -c '^    act=reclaim; f=$R/sys/fs/cgroup/memory.reclaim; left=$want$' "$S") $(grep -c -F "timeout -s KILL \"\$c\" sh -c 'echo 1 > \"\$1\"' sh \"\$R/proc/sys/vm/compact_memory\"" "$S") $(grep -c '^L=$R/run/omacvm-giveback.lock$' "$S")"
expect "  no swap, zram, reporting order or balloon writes" "" \
  "$(grep -v '^[[:space:]]*#' "$S" | grep -n -e swapoff -e swapon -e zram -e 'page_reporting_order *"* *>' -e 'balloon.*>')"
expect "the command the app sends stays small (under 5 KB)" yes "$( (( $(grep -v '^[[:space:]]*#' "$S" | wc -c) < 5120 )) && echo yes)"

# omacvm check's "VM memory" row (src/cmd/check.sh) from the app's logs/memory-giveback; never a failure. The Mac side: macOS only.
if [[ $(uname -s) == Darwin ]]; then
  C=$R/src/cmd/check.sh
  row=$(sed -n '/^  # The VM.s memory, and the VM.s file cache this run/,/^  \[\[ -n \$what \]\] && ok "VM memory"/p' "$C")
  expect "check.sh has the row, and it is never bad" "yes 0" "$([[ -n $row ]] && echo yes) $(grep -c '\(bad\|warn\) ' <<< "$row")"
  vmrow() {   # VMDIR [STORED_PAGES]: the row's text
    ( sp=${2:-1000}; ok() { echo "$1: $2"; }; app_env() { sed -n "s/^$2=//p" "$1/vm.env"; }
      eval "$(grep -m1 '^  gb() {' "$C")"
      sysctl() { case $2 in hw.pagesize) echo 16384 ;; hw.memsize) echo $((64 << 30)) ;; esac; }
      vm_stat() { printf 'Pages free:     100.\nPages stored in compressor:     %s.\n' "$sp"; }
      miclog=$1/logs/qemu.log; eval "$row" )
  }
  V=$T/vm; mkdir -p "$V/logs"; echo "MEM_MB=43008" > "$V/vm.env"; : > "$V/logs/qemu.log"
  expect "an app before this line, nothing yet" "VM memory: 42.0 GB; the VM freed no file cache this run" "$(vmrow "$V")"
  # The app's start line (MemoryGiveBack.startLine), as 3.2.11's QEMU (no reclaim fix) gives it.
  echo "OmacVM: VM memory: give-back while macOS compresses: off (this QEMU keeps given-back pages); macOS's memory warning still drops the VM's file cache" >> "$V/logs/qemu.log"
  expect "the app's line says the words check reads" "2" "$(grep -c -e '"OmacVM: VM memory: give-back while macOS compresses: " + (pagesGoBack' -e '? "on (this QEMU gives the pages back to macOS)"' "$M")"
  OFF="give-back while macOS compresses: off (this QEMU keeps given-back pages)"
  expect "a QEMU that keeps given-back pages: off, nothing freed" "VM memory: 42.0 GB; $OFF; the VM freed no file cache this run" "$(vmrow "$V")"
  printf 'omacvm: context error reported 3 "x\nOmacVM: VM memory: give-back while macOS compresses: on"\n' >> "$V/logs/qemu.log"
  expect "a later line from the VM (a name in QEMU's lines) does not count: the first is the app's" "VM memory: 42.0 GB; $OFF; the VM freed no file cache this run" "$(vmrow "$V")"
  at=$(date -j -f '%Y-%m-%d %H:%M' '2026-10-28 10:12' +%s)
  printf 'count=1\nat=%s\ntrigger=warning\nact=drop\ngiven_mb=\nreturned_mb=100\noff=0\n' "$at" > "$V/logs/memory-giveback"
  expect "the warning's drop: QEMU's footprint, not memory back to the Mac" \
    "VM memory: 42.0 GB; $OFF; the VM freed file cache once this run, at 10:12 (macOS was short of memory): QEMU's footprint 100 MB smaller a minute later" "$(vmrow "$V" 1000)"
  sed -i.bak 's/^returned_mb=.*/returned_mb=0/' "$V/logs/memory-giveback"
  expect "the warning's drop, the footprint did not fall" \
    "VM memory: 42.0 GB; $OFF; the VM freed file cache once this run, at 10:12 (macOS was short of memory): QEMU's footprint no smaller a minute later" "$(vmrow "$V" 1000)"
  sed -i.bak 's/^count=.*/count=3/; s/^returned_mb=.*/returned_mb=100/' "$V/logs/memory-giveback"
  expect "little back, macOS holds a quarter of the Mac compressed: the hint" \
    "VM memory: 42.0 GB; $OFF; the VM freed file cache 3 times this run, the last at 10:12 (macOS was short of memory): QEMU's footprint 100 MB smaller a minute later; macOS holds 17.0 GB compressed and the VM had little left to give: a smaller VM memory leaves the Mac more (omacvm resources)" \
    "$(vmrow "$V" $((17 << 16)))"
  # A QEMU with the reclaim fix (3.2.12): on, and what the VM said it freed.
  echo "OmacVM: VM memory: give-back while macOS compresses: on (this QEMU gives the pages back to macOS)" > "$V/logs/qemu.log"
  printf 'count=3\nat=%s\ntrigger=compressing\nact=reclaim\ngiven_mb=12186\nreturned_mb=0\noff=0\n' "$at" > "$V/logs/memory-giveback"
  expect "a QEMU with the fix: on; a give-back while macOS compressed the VM: what the VM freed" \
    "VM memory: 42.0 GB; give-back while macOS compresses: on; the VM freed file cache 3 times this run, the last at 10:12 (macOS was compressing the VM): 11.9 GB" "$(vmrow "$V")"
  printf 'count=3\nat=%s\ntrigger=compressing\nact=reclaim\ngiven_mb=12186\nreturned_mb=0\noff=0\nkept=1\n' "$at" > "$V/logs/memory-giveback"
  expect "QEMU found macOS keeping the pages (kept=1): off for the rest of the run" \
    "VM memory: 42.0 GB; give-back while macOS compresses: off for the rest of this run (macOS kept the pages QEMU gave back); the VM freed file cache 3 times this run, the last at 10:12 (macOS was compressing the VM): 11.9 GB" "$(vmrow "$V")"
  printf 'count=0\ntrigger=off\noff=1\n' > "$V/logs/memory-giveback"
  expect "a balloon that does not report" "VM memory: 42.0 GB; give-back while macOS compresses: on; its balloon does not report free pages: what it frees stays on the Mac this run" "$(vmrow "$V")"
  printf 'count=1\nat=x;rm -rf /\nreturned_mb=$(id)\n' > "$V/logs/memory-giveback"
  : > "$V/logs/qemu.log"
  expect "a file that is not numbers: nothing read from it" "VM memory: 42.0 GB; the VM freed no file cache this run" "$(vmrow "$V")"
fi

# The app runs it from its bundle on "compressing" (GPUMemory.swift), and nothing in the VM by itself.
G=$R/app/app/Sources/OmacVM/GPUMemory.swift
expect "the app carries the script from its bundle" 1 "$(grep -c '"Contents/Resources/omacvm/src/memory/guest/giveback.sh"' "$G")"
expect "the app runs it through runAndWait, with \"compressing\", \"idle\" and \"compact\"" "1 1 1 1 1" \
  "$(grep -c '\["-c", script, "giveback", mode\], seconds: 30)' "$G") $(grep -c 'GuestAgent.runAndWait' "$G") $(grep -c 'askVM("compressing", script, s)' "$G") $(grep -c 'askVM("idle", script, s)' "$G") $(grep -c 'askVM("compact", script, s)' "$G")"
expect "a silent agent: one line in qemu.log, not one per 30 s (the policy: desktop-tests)" "1 1 1" \
  "$(grep -c "did not answer: trying again" "$G") $(grep -B1 "did not answer: trying again" "$G" | grep -c 'if giveBack.misses == 1 {') $(grep -c 'giveBack.noAnswer(at:' "$G")"
# While macOS compresses the VM, only with a QEMU that gives the pages back (MemoryGiveBack.pagesGoBack, read from
# QEMU's binary at each start, one qemu.log line); the policy itself: desktop-tests.
expect "the app reads its QEMU at the start, sets pagesGoBack and logs the line" "1 1 1 1" \
  "$(grep -c 'qemuGivesPagesBack(binary: Paths.qemu, environment: ProcessInfo.processInfo.environment)' "$G") $(grep -c 'let on = MemoryGiveBack.thisQEMUGivesPagesBack' "$G") $(grep -c 'giveBack.pagesGoBack = on' "$G") $(grep -c 'log(MemoryGiveBack.startLine(pagesGoBack: on))' "$G")"
expect "the app's give-back starts with pagesGoBack off; OMACVM_GIVEBACK_IDLE from its environment" "1 1" \
  "$(grep -c 'private var giveBack = MemoryGiveBack(ram: ProcessInfo.processInfo.physicalMemory,$' "$G") $(grep -c '^ *idle: MemoryGiveBack.idleOn(environment: ProcessInfo.processInfo.environment))$' "$G")"
expect "every look: QEMU's CPU and macOS's pressure into the sample, seen even while a give-back runs" "1 1 1" \
  "$(grep -c 'cpu: p.cpu, normal: HostMemory.pressureNormal())' "$G") $(grep -c '^        giveBack.seen(s)$' "$G") $(grep -B1 '^        guard !givingBack else { return }$' "$G" | grep -c 'settled(w, s)')"
expect "the warning's drop done: the compaction-only call is due (MemoryGiveBack.dropped)" 1 "$(grep -c '^            giveBack.dropped()$' "$G")"
# The marker: the text the reclaim fix (qemu-hvf-free-page-reclaim-reusable.patch, PR #603) must put into QEMU, and
# that prepare-qemu-gpu-runtime.sh must find in a runtime with it (else the app keeps the give-back off). Without the
# patch (3.2.11) no runtime patch has the text, so the app says off.
mk=$(sed -n 's/.*public static let reclaimMarker = "\(.*\)"$/\1/p' "$M")
RP=$R/app/runtime/patches/qemu-hvf-free-page-reclaim-reusable.patch PREP=$R/app/runtime/prepare-qemu-gpu-runtime.sh
expect "the marker is set" yes "$([[ ${#mk} -ge 20 ]] && echo yes)"
if [[ -f $RP ]]; then
  expect "the reclaim fix puts the marker into QEMU" 1 "$(grep -c -F "$mk" "$RP" | awk '{ print ($1 > 0) }')"
  expect "prepare-qemu-gpu-runtime.sh checks the runtime has the marker" 1 "$(grep -c -F "'$mk'" "$PREP")"
else
  expect "no reclaim fix: no runtime patch has the marker, prepare does not ask for it" "0 0" \
    "$(cat "$R"/app/runtime/patches/*.patch | grep -c -F "$mk") $(grep -c -F "$mk" "$PREP")"
fi
# The fix built in is not the fix working: QEMU writes logs/memory-reclaim (OMACVM_RECLAIM_STATUS, "reclaim=keeps") when
# macOS keeps the pages anyway, and the app turns the give-back off for the run (policy: desktop-tests; QEMU's side:
# test-reclaim.sh --keeps).
RN=$R/app/app/Sources/OmacVM/Runner.swift
expect "the app names QEMU's status file and removes an old one before the start" "1 1 1" \
  "$(grep -c 'env\["OMACVM_RECLAIM_STATUS"\] = MemoryGiveBack.reclaimFile(for: c).path' "$RN") $(grep -c 'try? FileManager.default.removeItem(at: MemoryGiveBack.reclaimFile(for: c))' "$RN") $(grep -c 'config.folder.appendingPathComponent("logs/memory-reclaim")' "$G")"
expect "every 5 s while on, the app reads it; QEMU's word turns the give-back off, logged, check's kept=1" "1 1 1 1 1" \
  "$(grep -c '        if giveBack.pagesGoBack { qemuKeepsPages() }' "$G") $(grep -c 'guard let why = MemoryGiveBack.qemuKeeps(status: text) else { return }' "$G") $(grep -c '        giveBack.qemuKept()' "$G") $(grep -c '        status.kept = true' "$G") $(grep -c '        log(MemoryGiveBack.keptLine(why))' "$G")"
if [[ -f $RP ]]; then
  expect "the reclaim fix writes that file with the words the app reads" "1 1" \
    "$(grep -c -F 'getenv("OMACVM_RECLAIM_STATUS")' "$RP") $(grep -c -F '"reclaim=keeps\nwhy=%s\n"' "$RP")"
fi
expect "no unit, timer or install line in the VM runs it" "" \
  "$(grep -rl giveback "$R/src" | grep -v -e '^'"$R"'/src/memory/guest/giveback.sh$' -e '^'"$R"'/src/tests/memory-giveback.sh$' -e '^'"$R"'/src/cmd/check.sh$')"
exit $fail
