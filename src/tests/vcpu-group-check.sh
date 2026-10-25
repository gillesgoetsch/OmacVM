#!/bin/bash
# omacvm check's vCPU clock line (src/cmd/check.sh, ADR 0055) on made-up
# qemu.logs: on, why not, nothing when the switch is off or the runtime is
# older. The block is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../cmd/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcpu-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^# The vCPUs. clock by their own work this run/ {on=1} on {print} on && /^fi$/ {exit}' "$check" > "$T/block.sh"
[[ -s $T/block.sh ]] || { echo "FAIL: no vCPU clock block in check.sh"; exit 1; }
fail=0
read_line() {
  (
    ok() { echo "ok   | $1 | $2"; }
    warn() { echo "warn | $1 | $2"; }
    TYPE=app miclog=$1
    # shellcheck disable=SC1091
    source "$T/block.sh"
  )
}
expect() {   # what, want (a prefix of the line, or "" for none), log lines...
  local what=$1 want=$2 got; shift 2
  printf '%s\n' "$@" > "$T/qemu.log"
  got=$(read_line "$T/qemu.log")
  if [[ -z $want && -z $got ]] || [[ -n $want && $got == "$want"* ]]; then echo "ok   $what"
  else echo "FAIL $what: got '$got', want '$want'"; fail=1; fi
}
expect "on" "ok   | vCPU clock | the VM's CPUs run at the clock of their own work" "OmacVM: vCPU group: on"
expect "on (always): ok, not a warning" "ok   | vCPU clock | the VM's CPUs run at the clock of their own work" \
  "OmacVM: vCPU group: on (always)"
expect "off: nothing" "" "OmacVM: vCPU group: off"
expect "an older runtime: nothing" "" "OmacVM: network: user"
expect "refused: says why" "warn | vCPU clock | vcpuGroup is on, but the work interval was refused: the CPUs run as before" \
  "OmacVM: vCPU group: the work interval was refused"
expect "the last start wins" "ok   | vCPU clock |" "OmacVM: vCPU group: off" "OmacVM: vCPU group: on"
(( fail == 0 )) && echo "vcpu-group-check: all passed"
exit $fail
