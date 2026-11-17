#!/bin/bash
# omacvm check's VM CPU clock saver line (src/cmd/check.sh, ADR 0073) on
# made-up qemu.logs: on with every vCPU, only some, not available, nothing
# when the switch is off or the runtime is older, the last line wins (the
# switch changes while the VM runs). The block is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../cmd/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-vcs-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^# VM CPU clock saver this run/ {on=1} on {print} on && /^fi$/ {exit}' "$check" > "$T/block.sh"
[[ -s $T/block.sh ]] || { echo "FAIL: no VM CPU clock saver block in check.sh"; exit 1; }
fail=0
read_line() {
  (
    ok() { echo "ok   | $1 | $2"; }
    warn() { echo "warn | $1 | $2"; }
    TYPE=app miclog=$1
    # shellcheck disable=SC1090,SC1091
    source "$T/block.sh"
  )
}
expect() {   # what, want (the whole line, or "" for none), log lines...
  local what=$1 want=$2 got; shift 2
  printf '%s\n' "$@" > "$T/qemu.log"
  got=$(read_line "$T/qemu.log")
  if [[ $got == "$want" ]]; then echo "ok   $what"
  else echo "FAIL $what: got '$got', want '$want'"; fail=1; fi
}
p="2026-11-14T19:00:00.000000Z qemu-system-aarch64: info: OmacVM: vCPU clock saver:"
expect "on, every vCPU" "ok   | VM CPU clock saver | on: the VM's CPUs run at the clock of their own work (experimental)" \
  "$p on, 10 of 10 vCPUs (the switch)"
expect "on, some vCPUs" "warn | VM CPU clock saver | on, but only 8 of 10 VM CPUs joined: the others run as before" \
  "$p on, 8 of 10 vCPUs (the switch)"
expect "on, none" "warn | VM CPU clock saver | on, but only 0 of 4 VM CPUs joined: the others run as before" \
  "$p on, 0 of 4 vCPUs (OMACVM_VCPU_CLOCK_SAVER)"
expect "not available: says why" \
  "warn | VM CPU clock saver | on, but not available (no work interval on this macOS): the VM's CPUs run as before" \
  "$p not available: no work interval on this macOS (the switch)"
expect "off: nothing" "" "$p off (the switch)"
expect "off by GPU safe mode: nothing" "" "$p off (OMACVM_VCPU_CLOCK_SAVER)"
expect "an older runtime: nothing" "" "OmacVM: network: user"
expect "switched on while running: the last line" \
  "ok   | VM CPU clock saver | on: the VM's CPUs run at the clock of their own work (experimental)" \
  "$p off (the switch)" "$p on, 4 of 4 vCPUs (the switch)"
expect "switched off while running: nothing" "" "$p on, 4 of 4 vCPUs (the switch)" "$p off (the switch)"
(( fail == 0 )) && echo "vcpu-clock-saver-check: all passed"
exit $fail
