#!/bin/bash
# Offline checks for QEMU's own-view sweep (no VM, no QEMU build): Activity
# Monitor counts guest RAM once. The patch is pinned, applied right after the
# free page reclaim it shares its rule with, and tested by the runtime build;
# before the machine starts it runs a trial on scratch memory and is off for
# the run when that does not do what ADR 0066 expects; under the main lock it
# remaps QEMU's view of main RAM over itself in 128 MB chunks, checks every
# map entry first, makes a spare, reads the chunk again at once after the
# remap and maps it back from the spare if it changed, stops QEMU only when
# that fails, and logs what it did; its test hook only in test mode, dropped
# by the app in a release build: app/runtime/Tests/memory/test-dcount.sh,
# here on the sweep taken from the patch (the runtime build runs it on the
# patched QEMU source).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-hvf-own-view-sweep.patch
B=$R/app/runtime/build-qemu-gpu-runtime.sh
S=$R/app/runtime/patches/SHA256SUMS
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
# fn NAME: the patch's added lines of one function, from its signature to its closing brace.
fn() { awk -v f="$1" '$0 ~ ("^\\+[a-z].*[ *]" f "\\(") && !/;$/ { on = 1 } on { print } on && /^\+}$/ { exit }' "$P"; }

sum=$(shasum -a 256 "$P" | cut -d' ' -f1)
check "patch is pinned in SHA256SUMS" grep -q "^$sum  qemu-hvf-own-view-sweep.patch$" "$S"
check "runtime build pins the same SHA-256" grep -q "^own_view_sweep_patch_sha256=$sum$" "$B"
check "runtime build checks its SHA-256" grep -q 'verify_file_sha .*"$own_view_sweep_patch" "$own_view_sweep_patch_sha256"' \
  <<<"$(tr -d '\\\n' < "$B")"
order=$(grep -n -e '-i "$reclaim_reusable_patch"' -e 'Tests/memory/test-reclaim.sh" "$source_dir"' \
  -e '-i "$own_view_sweep_patch"' -e 'Tests/memory/test-dcount.sh" "$source_dir"' "$B" | cut -d: -f1 | tr '\n' ' ')
check "runtime build applies it after the free page reclaim and its test, then runs its own test on the patched source" \
  awk -v o="$order" 'BEGIN { n = split(o, a, " "); exit !(n == 4 && a[1] < a[2] && a[2] < a[3] && a[3] < a[4]) }'
check "the test's files are in the runtime inputs" grep -q 'Tests/memory/\*' "$R/app/scripts/build-app.sh"
# One rule for QEMU's private RAM: a free page report and the sweep.
check "free page reports go by the sweep's rule (omacvm_ram_private)" grep -q '^+    if (!omacvm_ram_private(mr) ||$' "$P"
rule=$(fn omacvm_ram_private)
check "the rule: RAM, not read-only, not a ROM device (pflash), not a RAM device" \
  grep -q 'return memory_region_is_ram(mr) && !mr->readonly && !mr->rom_device &&' <<<"$rule"
check "  not file-backed, shared or given by pointer (RAM_PREALLOC: the Venus host memory window's blobs), no dirty logging" \
  bash -c 'grep -q "rb && rb->fd < 0 &&" <<<"$1" && grep -q "!(rb->flags & (RAM_SHARED | RAM_PREALLOC)) &&" <<<"$1" &&
           grep -q "!memory_region_get_dirty_log_mask(mr);" <<<"$1"' _ "$rule"
# Main RAM only, from the machine's start, from its own timer under the BQL.
check "it sweeps the machine's main RAM only" grep -q '^+    MemoryRegion \*mr = current_machine ? current_machine->ram : NULL;$' "$P"
check "it starts when the machine is ready" grep -q '^+    qemu_add_machine_init_done_notifier(&omacvm_sweep_init);$' "$P"
check "its timer steps under the BQL, with the rule each time" \
  bash -c 'grep -q "^+    assert(bql_locked());$" <<<"$1" && grep -q "omacvm_sweep_step(&omacvm_sweep, get_clock(), omacvm_ram_private(mr));" <<<"$1"' \
  _ "$(fn omacvm_sweep_tick)"
check "128 MB chunks, 20 ms apart, a pass every 5 minutes, skipped below 64 MB of growth, twice in a row at most" \
  bash -c 'grep -q "^+#define OMACVM_SWEEP_CHUNK (128ull << 20)$" "$1" && grep -q "^+#define OMACVM_SWEEP_GAP_NS (20 \* 1000000LL)$" "$1" &&
           grep -q "^+#define OMACVM_SWEEP_PERIOD_S 300$" "$1" && grep -q "^+#define OMACVM_SWEEP_GROWTH (64ull << 20)$" "$1" &&
           grep -q "^+#define OMACVM_SWEEP_SKIPS 2 " "$1" && grep -q "^+            s->skipped < OMACVM_SWEEP_SKIPS) {$" "$1"' _ "$P"
# Before the machine starts: the trial on scratch memory, within its time limit; off for the run with why.
start=$(fn omacvm_sweep_start)
check "before the machine starts, a trial on scratch memory at a free IPA, at most 3 s; else off with why" \
  bash -c 'grep -q "^+    if (!omacvm_sweep_canary(&omacvm_sweep, omacvm_sweep_free_ipa(OMACVM_SWEEP_TRIAL),$" <<<"$1" &&
           grep -q "OmacVM: own-view sweep: off (%s): Activity Monitor counts the VM" <<<"$1" &&
           grep -q "^+#define OMACVM_SWEEP_TRIAL_MS 3000 " "$2" && grep -q "omacvm_sweep_ipa_bits = pa_range;" "$2"' _ "$start" "$P"
trial=$(fn omacvm_sweep_trial_run)
check "  the trial: hv_vm_map as guest RAM (else a second mapping), a piece given new memory, the same remap, both ways" \
  bash -c 'grep -q "hv_vm_map(scratch, t->ipa, OMACVM_SWEEP_TRIAL, flags) == HV_SUCCESS" <<<"$1" &&
           grep -q "hv_vm_map(scratch + cut, t->ipa + cut, piece, flags)" <<<"$1" &&
           grep -q "r = omacvm_sweep_remap(&b, mode, view, view, OMACVM_SWEEP_CHUNK, &less, &wrong, what," <<<"$1" &&
           grep -q "omacvm_sweep_trial_same(" <<<"$1"' _ "$trial"
check "  -overcommit mem-lock turns it off" grep -q '^+    if (should_mlock(mlock_state)) {$' "$P"
# Each chunk: every map entry has the trial's share mode first; a spare; the remap keeps the objects (copy=FALSE) at
# the same address; read again at once on every pass; mapped back from the spare if it changed.
chunk=$(fn omacvm_sweep_remap)
seq=$(grep -o -e 'omacvm_sweep_entries(' -e 'omacvm_sweep_test_remap(' -e 'omacvm_sweep_same(' -e 'omacvm_sweep_restore(' \
  -e 'omacvm_sweep_footprint(' <<<"$chunk" | tr '\n' ' ')
check "a chunk: entries checked, a spare made and checked, remapped, read again at once, else mapped back (was: $seq)" \
  test "$seq" = "omacvm_sweep_entries( omacvm_sweep_test_remap( omacvm_sweep_same( omacvm_sweep_same( omacvm_sweep_restore( omacvm_sweep_footprint( omacvm_sweep_test_remap( omacvm_sweep_same( omacvm_sweep_footprint( omacvm_sweep_restore( "
check "  the remap: same task and address, no copy, fixed over itself, then the check before anything else" \
  bash -c 'grep -A2 "VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), at,$" <<<"$1" | grep -q "^+                                     FALSE, &cur, &max, inherit);$" &&
           grep -q "^+        same = omacvm_sweep_same(b, at, at, len, n, base, what, sizeof(what));  /\* at once \*/$" <<<"$1"' _ "$chunk"
check "  the spare: no copy, anywhere, not inherited, gone on every path" \
  bash -c 'grep -q "mach_task_self(), at, FALSE, &cur, &max,$" <<<"$1" && grep -q "VM_INHERIT_NONE) != KERN_SUCCESS) {$" <<<"$1" &&
           grep -q "^+        mach_vm_deallocate(mach_task_self(), spare, len);$" <<<"$1"' _ "$chunk"
entries=$(fn omacvm_sweep_entries)
check "  before: the trial's share mode, an object, read-write, not wired; after: same objects (private passes), short info" \
  bash -c 'grep -q "shared = want >= 0 ? info.share_mode == want && !info.user_wired_count :" <<<"$1" &&
           grep -q "info.share_mode != SM_COW && info.share_mode != SM_EMPTY;" <<<"$1" && grep -q "!info.object_id ||" <<<"$1" &&
           grep -q "info.is_submap ||" <<<"$1" && grep -q "count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;" <<<"$1"' _ "$entries"
check "  mapped back over what is mapped, into what is not (no delete across a hole)" \
  bash -c 'grep -q "^+            flags = VM_FLAGS_FIXED;$" <<<"$1" && grep -q "^+            flags = VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE;$" <<<"$1"' \
  _ "$(fn omacvm_sweep_map_back)"
check "  mapped back or no spare: the sweep stops for the run; QEMU stops only when it could not be mapped back" \
  bash -c 'grep -A6 "case OMACVM_SWEEP_MAPPED_BACK:" <<<"$1" | grep -q "omacvm_sweep_stop(s, stop);" &&
           grep -A4 "case OMACVM_SWEEP_LOST:" <<<"$1" | grep -q "abort();" &&
           test "$(grep -c "abort()" <<<"$2")" = 1' _ "$(fn omacvm_sweep_chunk)" "$(awk '/omacvm-sweep: begin/,/omacvm-sweep: end/' "$P")"
check "  a failed remap stops the sweep for the run" grep -q '^+        omacvm_sweep_stop(s, why);$' "$P"
check "  no madvise, no page touched" bash -c '! grep -q "^+.*madvise(" <<<"$1"' _ "$(awk '/omacvm-sweep: begin/,/omacvm-sweep: end/' "$P")"
# The test hook: only in test mode (QEMU), and the app drops its variable in a release build.
check "its test hook only in test mode, and the app drops it in a release build" \
  bash -c 'grep -q "^+    if (test && test_mode && \*test_mode) {$" "$1" && grep -q "getenv(\"OMACVM_TEST_SKIP_DISPLAYS\")" "$1" &&
           grep -A2 "TestHooks.value(\"OMACVM_TEST_SWEEP_DIVERGE\"" "$2" | grep -q "env.removeValue(forKey: \"OMACVM_TEST_SWEEP_DIVERGE\")"' \
  _ "$P" "$R/app/app/Sources/OmacVM/Runner.swift"
check "OMACVM_DCOUNT_SWEEP=0 turns it off" grep -q 'omacvm_sweep_period(getenv("OMACVM_DCOUNT_SWEEP"))' "$P"
check "OMACVM_DCOUNT_SWEEP_CHECK=1 for tests" grep -q 'getenv("OMACVM_DCOUNT_SWEEP_CHECK")' "$P"
# qemu.log: the start line omacvm check reads, its own hourly line and the run's at exit.
for line in "OmacVM: own-view sweep: on: QEMU remaps its view of the VM's %.0f MB " "OmacVM: own-view sweep: off (" \
    "OmacVM: own-view sweep %s: %\" PRIu64 \" passes over %.0f MB of guest " "chunks remapped%s; Activity Monitor %.0f MB less; main lock per " \
    "left as they were " "OmacVM: own-view sweep: stopped for this run: %s" "stays as it is " "mapped back after %lld us: %s; a disk, network " \
    "could not be \"" "a trial remap on scratch memory took longer than %lld ms"; do
  check "patch logs '$line'" grep -qF "$line" "$P"
done
check "its hour's line comes from its own timer, the run's at exit" \
  bash -c 'grep -q "omacvm_sweep_log(s, \"in the last hour\", &s->hour);" "$1" && grep -q "omacvm_sweep_log(&omacvm_sweep, \"this run\", &omacvm_sweep.run);" "$1" &&
           grep -q "^+    qemu_add_exit_notifier(&omacvm_sweep_exit);$" "$1"' _ "$P"
check "no word of it calls it memory back to the Mac" bash -c '! grep -qiE "back to the Mac|gives? (it |them )?back|memory back|frees" <<<"$1"' \
  _ "$(awk '/omacvm-sweep: begin/,/omacvm-sweep: end/' "$P")"
check "omacvm check picks its words from this QEMU's line" grep -qF "'OmacVM: own-view sweep: (on|off)'" "$R/src/cmd/check.sh"
out=$("$R/app/runtime/Tests/memory/test-dcount.sh" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
check "test-dcount.sh on the patch's sweep" test "$rc" = 0
echo "memory-dcount: $((N - FAIL)) of $N ok"
(( FAIL == 0 ))
