#!/bin/bash
# Which VM --vm NAME means (src/lib/vm.sh): a name in two apps is refused, not
# guessed. No VM needed: vms_list is replaced by fixed lines.
#   src/tests/vm-names.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
fail=0
LIST=""
vms_list() { printf '%b' "$LIST"; }
vm_pin() { :; }
vm_find_ip() { echo 10.0.0.9; }

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# vm_type: one app, two apps, unknown, an invalid Parallels VM beside a real one.
LIST='Omarchy\tparallels\tstopped\nOmacVM Test\tparallels\tstopped\nOmacVM Test\tapp\trunning\nWork\tutm\trunning\nOld\tparallels\tinvalid\nOld\tapp\tstopped\n'
expect "a name in one app" utm "$(vm_type Work 2>/dev/null)"
t=$(vm_type "OmacVM Test" 2>&1 >/dev/null); rc=$?
expect "a name in two apps: exit 2" 2 "$rc"
expect "a name in two apps: says which" yes "$([[ $t == *"Parallels and OmacVM.app"*"--vm-type parallels or --vm-type app"* ]] && echo yes || echo "$t")"
expect "a name in two apps: no type on stdout" "" "$(vm_type "OmacVM Test" 2>/dev/null)"
vm_type Nope >/dev/null 2>&1; expect "an unknown name: exit 1" 1 $?
expect "an invalid Parallels VM does not count" app "$(vm_type Old 2>/dev/null)"

# resolve_vm: refuses the shared name (exit 2), takes it with --vm-type.
out=$( (VM="OmacVM Test"; TYPE=""; resolve_vm; echo "$TYPE") 2>&1); rc=$?
expect "resolve_vm, shared name: exit 2" 2 "$rc"
expect "resolve_vm, shared name: one message" 1 "$(grep -c "omacvm:" <<<"$out")"
expect "resolve_vm, shared name + --vm-type app" app "$( (VM="OmacVM Test"; TYPE=app; resolve_vm; echo "$TYPE") 2>/dev/null)"
expect "resolve_vm, shared name + --vm-type parallels" parallels "$( (VM="OmacVM Test"; TYPE=parallels; resolve_vm; echo "$TYPE") 2>/dev/null)"
out=$( (VM=Nope; TYPE=""; resolve_vm) 2>&1); rc=$?
expect "resolve_vm, unknown name: exit 2" 2 "$rc"
expect "resolve_vm, unknown name: says so" yes "$([[ $out == *"no Parallels, UTM, VMware Fusion or OmacVM.app VM named 'Nope'"* ]] && echo yes || echo "$out")"

# No --vm: "Omarchy" when there is one; in two apps that is refused too.
expect "no --vm: Omarchy" parallels "$( (VM=""; TYPE=""; resolve_vm; echo "$TYPE") 2>/dev/null)"
LIST='Omarchy\tparallels\tstopped\nOmarchy\tutm\tstopped\n'
( VM=""; TYPE=""; resolve_vm ) >/dev/null 2>&1; expect "no --vm, Omarchy in two apps: exit 2" 2 $?

exit $fail
