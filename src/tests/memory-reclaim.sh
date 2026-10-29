#!/bin/bash
# Offline checks for the free page reclaim fix (no VM, no QEMU build): the
# patch is pinned, applied after the two it builds on (both unchanged) and
# tested by the runtime build, and its helper gives a report's old pages back
# to macOS: app/runtime/Tests/memory/test-reclaim.sh, here on the helper taken
# from the patch (the runtime build runs it on the patched QEMU source).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-hvf-free-page-reclaim-reusable.patch
B=$R/app/runtime/build-qemu-gpu-runtime.sh
S=$R/app/runtime/patches/SHA256SUMS
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

sum=$(shasum -a 256 "$P" | cut -d' ' -f1)
check "patch is pinned in SHA256SUMS" grep -q "^$sum  qemu-hvf-free-page-reclaim-reusable.patch$" "$S"
check "runtime build pins the same SHA-256" grep -q "^reclaim_reusable_patch_sha256=$sum$" "$B"
# The two patches it applies after carry hvf_report_free_pages' old body: never edited.
check "free-page-reclaim patch unchanged" \
  grep -q "^5d422130996b99145d017d4429df660a07c757388ef7d52cba389766c18b0acf  qemu-hvf-free-page-reclaim.patch$" "$S"
check "mapped-sections patch unchanged" \
  grep -q "^2991378d565faeaf114bb5948bfa9ad05c39b078e4e1f4c2a674c3283800fab0  qemu-hvf-mapped-sections.patch$" "$S"
order=$(grep -n -e '-i "$memory_reclaim_patch"' -e '-i "$mapped_sections_patch"' -e '-i "$reclaim_reusable_patch"' "$B" |
  cut -d: -f1 | tr '\n' ' ')
check "runtime build applies it after free-page-reclaim and mapped-sections" \
  awk -v o="$order" 'BEGIN { n = split(o, a, " "); exit !(n == 3 && a[1] < a[2] && a[2] < a[3]) }'
check "runtime build checks its SHA-256" grep -q 'verify_file_sha .*"$reclaim_reusable_patch" "$reclaim_reusable_patch_sha256"' \
  <<<"$(tr -d '\\\n' < "$B")"
check "runtime build runs its test on the patched source" \
  grep -q 'Tests/memory/test-reclaim.sh" "$source_dir"' "$B"
check "the test's files are in the runtime inputs" grep -q 'Tests/memory/\*' "$R/app/scripts/build-app.sh"
# Under the main lock: stage-2 unmap, the old range moved aside (only with room for it on
# the worker's queue), the new backing, stage-2 map; never the advice. The worker: advice, then unmap.
seq=$(awk '/^\+static mach_vm_address_t omacvm_reclaim_backing\(/ { on = 1 } on && /^\+}$/ { exit } on' "$P" |
  grep -o -e 'hv_vm_unmap(' -e 'mach_vm_remap(' -e 'MADV_FREE_REUSABLE' -e 'MAP_FIXED' -e 'hv_vm_map(' | tr '\n' ' ')
check "backing: unmap, move aside, MAP_FIXED, map, no advice (was: $seq)" \
  test "$seq" = "hv_vm_unmap( mach_vm_remap( MAP_FIXED hv_vm_map( "
advice=$(grep -c '^+.*madvise(' "$P")
in_release=$(awk '/^\+static OmacvmReclaimPages omacvm_reclaim_release\(/ { on = 1 } on && /^\+}$/ { exit } on' "$P" |
  grep -c 'madvise(')
check "no advice under the main lock: madvise only in the worker's release ($in_release of $advice)" \
  test "$advice/$in_release" = "1/1"
check "a range moves aside only with room on the worker's queue" grep -q '^+    } else if (!omacvm_reclaim_room()) {$' "$P"
seq=$(awk '/^\+static OmacvmReclaimPages omacvm_reclaim_release\(/ { on = 1 } on && /^\+}$/ { exit } on' "$P" |
  grep -o -e 'MADV_FREE_REUSABLE' -e 'munmap(' | tr '\n' ' ')
check "release: the advice, then unmap (was: $seq)" test "$seq" = "MADV_FREE_REUSABLE munmap( "
check "the release runs on a worker thread at utility QoS" grep -q '^+    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);' "$P"
check "every range moved aside is queued for the worker" \
  grep -q '^+    } else if (aside && !omacvm_reclaim_queue(aside, size, 0)) {$' "$P"
check "each report's hold is timed from the start of hvf_report_free_pages" \
  bash -c 'grep -q "^+    int64_t start = get_clock();$" "$1" && grep -q "^+    omacvm_reclaim_report(start, gpa, host, size, flags);$" "$1"' _ "$P"
check "the old comment against MADV_FREE_REUSABLE is gone" \
  bash -c '! grep -q "^+.*Unlike MADV_FREE_REUSABLE" "$1"' _ "$P"
check "OMACVM_RECLAIM_REUSABLE=0 turns it off" grep -q 'getenv("OMACVM_RECLAIM_REUSABLE")' "$P"
# macOS keeping the pages (a refused madvise, or an advice skipped without an error: the worker's window rule)
# stops the move aside for the run, once, and tells the app (MemoryGiveBack.qemuKeeps; test-reclaim.sh --keeps).
check "macOS keeping the pages stops the move aside, said once a run" \
  grep -q '^+    if (__atomic_exchange_n(&omacvm_reclaim_kept, true, __ATOMIC_RELAXED)) {' "$P"
check "  a refused madvise counts" grep -q '^+    omacvm_reclaim_keeps(why);' "$P"
check "  the worker judges every release" grep -q '^+        if (!omacvm_reclaim_takes(&judge, before, left, why, sizeof(why))) {' "$P"
check "  the app's status file: OMACVM_RECLAIM_STATUS, reclaim=keeps" \
  bash -c 'grep -q "getenv(\"OMACVM_RECLAIM_STATUS\")" "$1" && grep -qF "\"reclaim=keeps\\nwhy=%s\\n\"" "$1"' _ "$P"
# The text the app looks for in QEMU's binary (MemoryGiveBack.reclaimMarker), in a line QEMU keeps.
check "the worker's first line has the app's marker" \
  grep -q '^+    info_report("OmacVM: free page reclaim gives the pages back to macOS "$' "$P"
check "OMACVM_RECLAIM_CHECK=1 for tests" grep -q 'getenv("OMACVM_RECLAIM_CHECK")' "$P"
for line in "free page reporting %s:" "reported in %" "main lock held per report p99" "MB not moved aside (%s)" \
    "the worker released %.0f MB" "reclaim check:" "macOS keeps the pages the VM" "madvise refused: %s"; do
  check "patch logs '$line'" grep -qF "$line" "$P"
done
# Reported MB are what the guest gave QEMU; what the Mac got is the worker's number.
check "no qemu.log line calls reported MB \"back to the Mac\"" bash -c '! grep -q "^+.*back to the Mac" "$1"' _ "$P"
check "qemu.log's p99 is never above the longest hold" \
  grep -qF '+    p99 = MIN((int64_t)(step + 1) * OMACVM_RECLAIM_STEP_NS, s->longest_ns);' "$P"
check "the balloon closes each report for the counters" grep -q '^+            hvf_report_free_pages_done();' "$P"
out=$("$R/app/runtime/Tests/memory/test-reclaim.sh" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
check "test-reclaim.sh on the patch's helper" test "$rc" = 0
echo "memory-reclaim: $((N - FAIL)) of $N ok"
(( FAIL == 0 ))
