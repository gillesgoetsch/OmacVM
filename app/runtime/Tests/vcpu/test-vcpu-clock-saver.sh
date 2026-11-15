#!/bin/bash
# VM CPU clock saver (ADR 0073; qemu-hvf-vcpu-clock-saver-logic.patch,
# qemu-hvf-vcpu-clock-saver.patch, omacvm-cocoa-vcpu-clock-saver.patch).
#   test-vcpu-clock-saver.sh                     (CI) the logic patch makes
#       include/qemu/omacvm-vcpu-clock-saver.h in an empty folder and
#       test-vcpu-clock-saver.c runs its rules on threads like QEMU's vCPUs.
#   test-vcpu-clock-saver.sh HVF COCOA           (the runtime build, after the
#       wiring patches) also: each vCPU follows a change as queued work on its
#       own thread (so a halted or stopped vCPU follows too), joins at its
#       start, leaves before it ends, nothing joins outside the tested rules
#       (no thread of ui/cocoa.m: main, present, display link, sound),
#       and the app's switch is read and watched as tested; the checks also
#       catch each piece taken out again.
#   test-vcpu-clock-saver.sh --self-test HVF COCOA   (the runtime build, before
#       the wiring patches) the checks fail on the files without the wiring.
# HVF = accel/hvf/hvf-accel-ops.c, COCOA = ui/cocoa.m of the patched QEMU.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcpu-clock-saver.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/qemu-hvf-vcpu-clock-saver-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/include" "$here/test-vcpu-clock-saver.c" -o "$work/t"
"$work/t"

self=0
[[ ${1:-} == --self-test ]] && { self=1; shift; }
(( $# )) || exit 0
[[ $# == 2 ]] || { echo "usage: $0 [--self-test] HVF COCOA" >&2; exit 2; }

body() { awk -v h="$1" 'index($0, h) == 1 && !/;$/ {on=1} on {print} on && /^}$/ {exit}' "$2"; }
problems() {   # HVF COCOA: one line per piece of the wiring that is not as tested
  local h=$1 m=$2 fn set work_fn sw init kvo disp
  fn=$(body 'static void *hvf_cpu_thread_fn(void *arg)' "$h")
  set=$(body 'void omacvm_vcpu_clock_saver_set(bool on, const char *why)' "$h")
  work_fn=$(body 'static void omacvm_vcs_follow_work(CPUState *cpu, run_on_cpu_data arg)' "$h")
  sw=$(body 'static void omacvm_vcs_read_switch(void)' "$m")
  init=$(body 'static void omacvm_vcs_init(void)' "$m")
  kvo=$(awk '/^@implementation OmacVMVcpuClockSaverWatch$/ {on=1} on {print} on && /^@end$/ {exit}' "$m")
  disp=$(body 'static void omacvm_displays_init(void)' "$m")
  [[ -n $fn ]] || { echo "no hvf_cpu_thread_fn"; return; }
  grep -q '#include "qemu/omacvm-vcpu-clock-saver.h"' "$h" || echo "hvf: the rules are not included"
  grep -q '^static __thread OmacvmVcs omacvm_vcs_self;$' "$h" || echo "hvf: a vCPU's place is not its own thread's"
  # A new vCPU joins after it is set up and before it counts as created; it leaves before it ends.
  awk '/hvf_init_vcpu\(cpu\);/ {a=NR} /omacvm_vcs_follow\(&omacvm_vcs_self, omacvm_vcs_on\);/ && !b {b=NR}
       /cpu_thread_signal_created\(cpu\);/ {c=NR} END {exit !(a && b && c && a < b && b < c)}' <<<"$fn" ||
    echo "hvf: a vCPU does not take its place after it is set up and before it counts as created"
  awk '/while \(!cpu->unplug/ {a=NR} /omacvm_vcs_follow\(&omacvm_vcs_self, false\);/ {b=NR}
       /hvf_vcpu_destroy\(cpu\);/ {c=NR} END {exit !(a && b && c && a < b && b < c)}' <<<"$fn" ||
    echo "hvf: a vCPU thread does not leave the group before it ends (libdispatch would stop QEMU)"
  # A change reaches every vCPU as queued work (it wakes halted and stopped vCPUs), never as a direct join.
  grep -q 'async_run_on_cpu(cpu, omacvm_vcs_follow_work, RUN_ON_CPU_HOST_INT(gen));' <<<"$set" &&
    grep -q 'gen = omacvm_vcs_tally_begin(&omacvm_vcs_tally, n);' <<<"$set" &&
    grep -q 'omacvm_vcs_on = on;' <<<"$set" ||
    echo "hvf: a change does not reach every vCPU as queued work"
  # Never on: nothing queued, nothing loaded (off stays today's behaviour).
  awk '/if \(!on && !asked\) \{/ {a=NR; on=1} on && /return;/ {b=NR} on && /^    }$/ {on=0} /async_run_on_cpu/ {c=NR}
       END {exit !(a && b && c && a < b && b < c)}' <<<"$set" ||
    echo "hvf: a switch that was never on still queues work"
  grep -q 'bool in = omacvm_vcs_follow(&omacvm_vcs_self, omacvm_vcs_on);' <<<"$work_fn" &&
    grep -q 'if (omacvm_vcs_tally_done(&omacvm_vcs_tally, arg.host_int, in)) {' <<<"$work_fn" &&
    grep -q 'info_report("OmacVM: vCPU clock saver: %s", line);' <<<"$work_fn" ||
    echo "hvf: a vCPU does not follow on its own thread, or the last one does not log what they did"
  [[ $(grep -c 'os_workgroup_join\|os_workgroup_leave\|omacvm_vcs_group()' "$h") == 0 ]] ||
    echo "hvf: the group is joined outside the tested rules"
  [[ $(grep -c 'omacvm_vcs_follow(' "$h") == 3 ]] ||
    echo "hvf: a vCPU follows the switch somewhere not tested (at its start, in the queued work, before it ends)"
  # The app's switch: OMACVM_VCPU_CLOCK_SAVER wins, else the app's key as the app; watched; handed over with the BQL.
  grep -q '#include "qemu/omacvm-vcpu-clock-saver.h"' "$m" || echo "cocoa: the rules are not included"
  # Only vCPU threads join (USER-1114c): the main thread, present, display link and sound never do.
  [[ $(grep -c 'os_workgroup_join\|omacvm_vcs_follow(\|omacvm_vcs_group()' "$m") == 0 ]] ||
    echo "cocoa: a thread that is not a vCPU joins the group"
  grep -q 'int e = omacvm_vcs_env();' <<<"$sw" && grep -q 'boolForKey:@"vcpuClockSaver"' <<<"$sw" &&
    grep -q 'omacvm_bright_as_app()' <<<"$sw" || echo "cocoa: the switch is not read as tested"
  grep -q 'forKeyPath:@"vcpuClockSaver"' <<<"$init" && grep -q 'if (omacvm_bright_as_app() && !env) {' <<<"$init" &&
    grep -q 'omacvm_vcpu_clock_saver_set(omacvm_vcs_switch == 1, env ? "OMACVM_VCPU_CLOCK_SAVER" :' <<<"$init" ||
    echo "cocoa: the switch at start is not handed over or watched as tested"
  grep -q 'with_bql(^{' <<<"$kvo" && grep -q 'omacvm_vcpu_clock_saver_set(on, "the switch");' <<<"$kvo" &&
    grep -q 'if (was != omacvm_vcs_switch) {' <<<"$kvo" || echo "cocoa: a change of the switch is not handed over with the BQL"
  grep -q 'omacvm_vcs_init();' <<<"$disp" || echo "cocoa: the switch is not read at start"
}

h=$1; m=$2
if (( self )); then
  p=$(problems "$h" "$m")
  [[ -n $p ]] || { echo "test-vcpu-clock-saver: the wiring checks pass the files without the wiring" >&2; exit 1; }
  echo "test-vcpu-clock-saver: self-test ok (the checks fail before the wiring)"
  exit 0
fi
p=$(problems "$h" "$m")
[[ -z $p ]] || { echo "$p" >&2; exit 1; }
# The checks catch each piece taken out again.
cut_out() {   # NAME FILE SED-EXPR WANT: the checks name WANT once the file is changed by SED-EXPR
  local f=$work/$1; cp "$2" "$f"; sed -i.bak "$3" "$f"
  local hh=$h mm=$m; [[ $2 == "$h" ]] && hh=$f || mm=$f
  [[ $(problems "$hh" "$mm") == *"$4"* ]] || { echo "test-vcpu-clock-saver: the checks miss: $4" >&2; exit 1; }
}
cut_out noleave.c "$h" '/omacvm_vcs_follow(&omacvm_vcs_self, false);/d' 'leave the group before it ends'
cut_out nostart.c "$h" '/hvf_init_vcpu(cpu);/{n;n;d;}' 'after it is set up'
cut_out direct.c "$h" 's/async_run_on_cpu(cpu, omacvm_vcs_follow_work/run_on_cpu(cpu, omacvm_vcs_follow_work/' 'queued work'
cut_out queued.c "$h" '/if (!on \&\& !asked) {/,/return;/{/return;/d;}' 'never on still queues'
cut_out mainjoin.m "$m" 's/omacvm_vcs_init();/omacvm_vcs_follow(NULL, true); omacvm_vcs_init();/' 'not a vCPU joins'
cut_out nokvo.m "$m" 's/forKeyPath:@"vcpuClockSaver"/forKeyPath:@"vcpuClockSaverX"/' 'watched as tested'
cut_out nobql.m "$m" '/^@implementation OmacVMVcpuClockSaverWatch$/,/^@end$/s/with_bql(^{/dispatch_async(dispatch_get_main_queue(), ^{/' 'with the BQL'
echo "test-vcpu-clock-saver: wiring ok"
