#!/bin/bash
# Test for qemu-hvf-own-view-sweep.patch (no VM): after a sweep, Activity
# Monitor counts guest RAM once, and QEMU and the guest still see the same
# memory (test-dcount.c says how).
#   test-dcount.sh [QEMU_SOURCE_DIR [WORK_DIR]]
# With a source dir (the runtime build): the sweep and the free page reclaim
# from the patched accel/hvf/hvf-all.c, and they must be wired in. Without
# (CI): both from their patches. Runs the patch's sweep (must pass) and
# main's, which has none (must fail: the footprint stays about twice what
# the Mac holds), each with a second mapping standing in for the
# hypervisor's and, where this Mac lets a process make a VM, a real one
# (--hv). Then --predicate (which RAM blocks a free page report may replace
# and the sweep may remap: never the Venus host memory window's blobs, pflash
# or ROM) and --diverge (a remap that changes QEMU's view in the first pass:
# QEMU must stop).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-} work=${2:-}
(( $# <= 2 )) || { echo "usage: test-dcount.sh [QEMU_SOURCE_DIR [WORK_DIR]]" >&2; exit 2; }
work=${work:-$(mktemp -d "${TMPDIR:-/tmp}/omacvm-test-dcount.XXXXXX")}
mkdir -p "$work"
# block NAME FILE [patch]: the lines between "/* omacvm-NAME: begin" and "/* omacvm-NAME: end */".
block() {
  local b="/* omacvm-$1: begin" e="/* omacvm-$1: end */"
  if [[ ${3:-} == patch ]]; then
    B=$b E=$e awk '{ l = $0; if (substr(l, 1, 1) != "+") { if (on) exit; next }; l = substr(l, 2) }
      index(l, ENVIRON["B"]) == 1 { on = 1 } on { print l } on && l == ENVIRON["E"] { exit }' "$2"
  else
    B=$b E=$e awk 'index($0, ENVIRON["B"]) == 1 { on = 1 } on { print } on && $0 == ENVIRON["E"] { exit }' "$2"
  fi
}
if [[ -n $src ]]; then
  f=$src/accel/hvf/hvf-all.c
  block reclaim "$f" > "$work/reclaim.inc"
  block sweep "$f" > "$work/sweep.inc"
  # Wired in: a free page report goes by the sweep's rule for QEMU's private
  # RAM; the sweep starts with the machine, from its own timer under the BQL,
  # over the machine's main RAM only, and checks the rule at every step.
  body=$(awk '/^void hvf_report_free_pages\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $body == *"if (!omacvm_ram_private(mr) ||"* && $body != *"rb->flags"* ]] || \
    { echo "FAIL: hvf_report_free_pages() does not go by omacvm_ram_private()"; exit 1; }
  init=$(awk '/^static int hvf_accel_init\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $init == *"qemu_add_machine_init_done_notifier(&omacvm_sweep_init);"* ]] || \
    { echo "FAIL: hvf_accel_init() does not start the sweep with the machine"; exit 1; }
  tick=$(awk '/^static void omacvm_sweep_tick\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $tick == *"assert(bql_locked());"* &&
     $tick == *"MemoryRegion *mr = current_machine->ram;"* &&
     $tick == *"omacvm_sweep_step(&omacvm_sweep, get_clock(), omacvm_ram_private(mr));"* ]] || \
    { echo "FAIL: the sweep's timer does not step under the BQL over the machine's RAM with the rule"; exit 1; }
  start=$(awk '/^static void omacvm_sweep_start\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$f")
  [[ $start == *"MemoryRegion *mr = current_machine ? current_machine->ram : NULL;"* &&
     $start == *"!omacvm_ram_private(mr)"* &&
     $start == *'getenv("OMACVM_DCOUNT_SWEEP")'* &&
     $start == *"timer_new_ns(QEMU_CLOCK_REALTIME, omacvm_sweep_tick, NULL);"* &&
     $start == *'"OmacVM: own-view sweep: on: '* ]] || \
    { echo "FAIL: the sweep does not start over the machine's main RAM, with its switch and start line"; exit 1; }
else
  block reclaim "$here/../../patches/qemu-hvf-free-page-reclaim-reusable.patch" patch > "$work/reclaim.inc"
  block sweep "$here/../../patches/qemu-hvf-own-view-sweep.patch" patch > "$work/sweep.inc"
fi
grep -q 'omacvm-reclaim: end' "$work/reclaim.inc" || \
  { echo "FAIL: no free page reclaim (omacvm-reclaim: begin ... end) in ${src:-its patch}"; exit 1; }
grep -q 'omacvm-sweep: end' "$work/sweep.inc" || \
  { echo "FAIL: no sweep (omacvm-sweep: begin ... end) in ${src:-its patch}"; exit 1; }
cat > "$work/hv.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
EOF
for v in patch main; do
  def=(); [[ $v == main ]] && def=(-DSWEEP_MAIN)
  cc -O1 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function ${def[@]+"${def[@]}"} -I"$work" \
    "$here/test-dcount.c" -framework Hypervisor -o "$work/test-$v"
  codesign -s - -f --entitlements "$work/hv.plist" "$work/test-$v" 2>/dev/null
done
fail=0
run() {   # WANT(pass|fail|abort) BINARY [ARGS...]
  local want=$1 bin=$2 rc out; shift 2
  rc=0; out=$(TEST_DCOUNT_DIR=$work "$work/$bin" "$@" 2>&1) || rc=$?
  local what="$bin${*:+ $*}"
  if (( rc == 2 )) && [[ $out == *"SKIP"* ]]; then
    echo "  $what: skipped, $(grep -m1 -o 'SKIP.*' <<< "$out")"
  elif [[ $want == pass && $rc == 0 ]] || [[ $want == fail && $rc == 1 && $out == *"COUNTED TWICE"* ]] ||
       [[ $want == abort && $rc -ge 128 && $out == *"maps other memory than the guest's"* ]]; then
    echo "  $what: ${want}ed as it should ($(grep -c '^  ok' <<< "$out") ok rows${out:+; $(grep -m1 -o 'after pass 2: [^:]*' <<< "$out" || true)})"
  else
    echo "FAIL $what (exit $rc, want $want):"; grep -v '^  ok' <<< "$out" | sed 's/^/    /' | tail -25; fail=1
  fi
}
for hv in "" --hv; do
  run pass test-patch ${hv:+"$hv"}
  run fail test-main ${hv:+"$hv"}
done
run pass test-patch --predicate
run abort test-patch --diverge
rm -f "$work/io-in" "$work/io-out"
(( fail == 0 )) && echo "test-dcount: all ok" || { echo "test-dcount: FAILED"; exit 1; }
