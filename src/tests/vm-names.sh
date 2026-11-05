#!/bin/bash
# Which VM --vm NAME means (src/lib/vm.sh) beside retired Parallels, UTM and
# VMware Fusion VMs (src/lib/retired.sh): an OmacVM.app VM wins over a retired
# one of the same name, a retired one is refused with exit 3, never started or
# reached. No VM needed: vms_list is replaced by fixed lines.
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
vm_boot() { echo "STARTED $1" >&2; return 1; }

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

LIST='Omarchy\tparallels\tretired\nOmacVM Test\tfusion\tretired\nOmacVM Test\tapp\trunning\nWork\tutm\tretired\nNew\tapp\tstopped\n'
# vm_type: an app VM wins; a retired VM is named by its old type.
expect "a name in OmacVM.app and a retired app: OmacVM.app" app "$(vm_type "OmacVM Test" 2>/dev/null)"
expect "a retired name: its old type" utm "$(vm_type Work 2>/dev/null)"
vm_type Nope >/dev/null 2>&1; expect "an unknown name: exit 1" 1 $?

# resolve_vm
expect "resolve_vm, shared with a retired VM: the app's" app "$( (VM="OmacVM Test"; TYPE=""; resolve_vm; echo "$TYPE") 2>/dev/null)"
out=$( (VM=Work; TYPE=""; resolve_vm start; echo "TYPE=$TYPE") 2>&1); rc=$?
expect "resolve_vm, a retired VM: exit 3" 3 "$rc"
expect "resolve_vm, a retired VM: the retired text, nothing started" yes \
  "$([[ $out == *"'Work' is a UTM VM. OmacVM 3.4.0 retired"*"#retired-routes"* && $out != *STARTED* && $out != *TYPE=* ]] && echo yes || echo "$out")"
( VM="OmacVM Test"; TYPE=fusion; resolve_vm ) >/dev/null 2>&1; expect "resolve_vm, --vm-type fusion: exit 3" 3 $?
( VM="New"; TYPE=parallels; resolve_vm ) >/dev/null 2>&1; expect "resolve_vm, --vm-type parallels for an app VM: exit 2" 2 $?
out=$( (VM=Nope; TYPE=""; resolve_vm) 2>&1); rc=$?
expect "resolve_vm, unknown name: exit 2" 2 "$rc"
expect "resolve_vm, unknown name: says so" yes "$([[ $out == *"no OmacVM.app VM named 'Nope'"* ]] && echo yes || echo "$out")"
out=$( (JSON=1; VM=Work; TYPE=""; resolve_vm) 2>/dev/null); rc=$?
expect "resolve_vm with JSON=1: exit 3" 3 "$rc"
expect "resolve_vm with JSON=1: route-retired JSON" "route-retired utm Work 3.4.0" \
  "$(python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["error"], d["route"], d["vm"], d["retired_in"])' "$out" 2>&1)"

# No --vm: only OmacVM.app VMs are picked.
expect "no --vm: the only running app VM (a retired Omarchy is not picked)" "OmacVM Test" "$( (VM=""; TYPE=""; resolve_vm; echo "$VM") 2>/dev/null)"
LIST='Omarchy\tparallels\tretired\nNew\tapp\tstopped\n'
( VM=""; TYPE=""; resolve_vm ) >/dev/null 2>&1; expect "no --vm, the only Omarchy is retired: exit 3" 3 $?
LIST='Omarchy\tparallels\tretired\nOmarchy\tapp\tstopped\n'
expect "no --vm: the app's Omarchy over a retired one" "Omarchy app" "$( (VM=""; TYPE=""; resolve_vm; echo "$VM $TYPE") 2>/dev/null)"
LIST='A\tapp\tstopped\nB\tapp\tstopped\n'
( VM=""; TYPE=""; resolve_vm ) >/dev/null 2>&1; expect "no --vm, two stopped app VMs: exit 2" 2 $?

exit $fail
