#!/bin/bash
# The vCPU group (ADR 0055, qemu-hvf-vcpu-group-logic.patch, qemu-hvf-vcpu-group.patch):
# the logic patch makes include/qemu/omacvm-vcpu-group.h in an empty folder and
# test-vcpu-group.c runs its rules on threads like QEMU's vCPU threads. With
# accel/hvf/hvf-accel-ops.c as argument (the runtime build, after the wiring
# patch): also that the vCPU thread takes its place after it is set up and on
# every pass of its loop, leaves before it ends, that the thread that decides
# starts before the first vCPU, and QEMU's log says which way it went.
#   test-vcpu-group.sh                                (CI)
#   test-vcpu-group.sh <patched accel/hvf/hvf-accel-ops.c>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcpu-group.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/qemu-hvf-vcpu-group-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/include" "$here/test-vcpu-group.c" -o "$work/t"
"$work/t"

problems() {
  local f=$1 fn
  fn=$(awk '/^static void \*hvf_cpu_thread_fn\(void \*arg\)$/ {on=1} on {print} on && /^}$/ {exit}' "$f")
  [[ -n $fn ]] || { echo "no hvf_cpu_thread_fn"; return; }
  grep -q '#include "qemu/omacvm-vcpu-group.h"' "$f" || echo "the vCPU group header is not used"
  awk '/hvf_init_vcpu\(cpu\);/ {a=NR} /omacvm_vcpu_group_follow\(&group, omacvm_vg_wants\(cpu\)\);/ && !b {b=NR} /cpu_thread_signal_created\(cpu\);/ {c=NR}
       END {exit !(a && b && c && a < b && b < c)}' <<<"$fn" ||
    echo "the vCPU does not take its place after it is set up and before it counts as created"
  awk '/qemu_process_cpu_events\(cpu\);/ {a=NR} /omacvm_vcpu_group_follow\(&group, omacvm_vg_wants\(cpu\)\);/ {b=NR} /hvf_arch_vcpu_exec\(cpu\);/ {c=NR}
       END {exit !(a && b && c && a < b && b < c)}' <<<"$fn" ||
    echo "the vCPU does not follow its place on each pass of its loop (a kick changes nothing)"
  st=$(awk '/^static void hvf_start_vcpu_thread\(CPUState \*cpu\)$/ {on=1} on {print} on && /^}$/ {exit}' "$f")
  awk '/omacvm_vg_start\(\);/ {a=NR} /qemu_thread_create\(cpu->thread/ {b=NR} END {exit !(a && b && a < b)}' <<<"$st" ||
    echo "the thread that decides does not start before the first vCPU"
  grep -q 'want = omacvm_vcpu_group_decide(used, wall, now, input, &out_until\[i\]);' "$f" &&
    grep -q 'qemu_cpu_kick(cpu);' <<<"$(awk '/^static void \*omacvm_vg_thread_fn/ {on=1} on {print} on && /^}$/ {exit}' "$f")" ||
    echo "the deciding thread does not use the tested rule or does not kick the vCPU"
  awk '/omacvm_vcpu_group_leave\(&group\);/ {a=NR} /hvf_vcpu_destroy\(cpu\);/ {b=NR} /while \(!cpu->unplug/ {c=NR}
       END {exit !(a && b && c && c < a && a < b)}' <<<"$fn" ||
    echo "the vCPU thread does not leave the group before it ends (libdispatch would stop QEMU)"
  grep -q 'OmacVM: vCPU group: %s' <<<"$fn" && grep -q 'omacvm_vcpu_group_state()' <<<"$fn" ||
    echo "QEMU's log does not say which way the vCPUs went"
  [[ $(grep -c 'omacvm_vcpu_group_join\|os_workgroup_join' "$f") == 0 ]] || echo "the group is joined outside the tested rules"
}
if [[ $# -ge 1 ]]; then
  p=$(problems "$1")
  [[ -z $p ]] || { echo "$p" >&2; exit 1; }
  # The checks catch the file without the wiring and with the leave missing.
  cp "$1" "$work/stock.c"
  sed -i.bak -e '/omacvm_vcpu_group_follow(&group/d' -e '/omacvm_vcpu_group_leave(&group);/d' "$work/stock.c"
  [[ -n $(problems "$work/stock.c") ]] || { echo "the checks pass a file without the wiring" >&2; exit 1; }
  cp "$1" "$work/noleave.c"; sed -i.bak '/omacvm_vcpu_group_leave(&group);/d' "$work/noleave.c"
  [[ $(problems "$work/noleave.c") == *leave* ]] || { echo "the checks miss a missing leave" >&2; exit 1; }
  echo "vcpu-group wiring: ok"
fi
