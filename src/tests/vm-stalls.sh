#!/bin/bash
# omacvm check's "VM stalls" row (src/cmd/check.sh) from QEMU's logs/vm-stalls
# (qemu-hvf-vcpu-stall-note.patch, ADR 0060): a warning when the VM stood
# still this run (macOS out of memory, no Mac core, or QEMU's graphics thread),
# ok when it did not, no line without the file (a runtime without the note),
# never a failure, nothing taken from the file but numbers and a short where.
# The app's side (VMStalls) is in desktop-tests, the VM's note in
# app-desktop-recovery.sh. No VM. macOS only.
#   src/tests/vm-stalls.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ $(uname -s) == Darwin ]] || { echo "skip: macOS only"; exit 0; }
C=$R/src/cmd/check.sh
row=$(sed -n '/^  # When the VM stood still this run/,/^    else ok "VM stalls"/p' "$C")
expect "check.sh has the row, and it is never bad" "yes 0" "$([[ -n $row ]] && echo yes) $(grep -c 'bad ' <<< "$row")"
stallrow() {   # VMDIR: the row's text ("" when none)
  ( ok() { echo "ok $1: $2"; }; warn() { echo "WARN $1: $2"; }
    eval "$(grep -m1 '^  gb() {' "$C")"
    sysctl() { [[ $2 == hw.memsize ]] && echo $((64 << 30)); }
    VM="Omarchy"; vmm=43008; peak=8708
    miclog=$1/logs/qemu.log; eval "$row
  fi" )
}
V=$T/vm; mkdir -p "$V/logs"; : > "$V/logs/qemu.log"
expect "no file (a runtime without the note): no line" "" "$(stallrow "$V")"
printf 'stalls=0\nlongest_ms=0\nlongest_cause=none\nlast_ms=0\nlast_cause=none\nlast_vcpus=\nlast_at=0\nlast_vm_mb=0\nlast_free_mb=0\nlast_compressed_mb=0\ngpu_stalls=0\ngpu_longest_ms=0\ngpu_last_where=\n' > "$V/logs/vm-stalls"
expect "QEMU's start, nothing since: ok" "ok VM stalls: the VM did not stand still this run" "$(stallrow "$V")"
cat > "$V/logs/vm-stalls" <<'S'
stalls=2
longest_ms=58000
longest_cause=memory
last_ms=58000
last_cause=memory
last_vcpus=1,2,3,8
last_at=1761637419
last_vm_mb=52224
last_free_mb=300
last_compressed_mb=20480
gpu_stalls=0
gpu_longest_ms=0
gpu_last_where=
S
expect "the user's 58 s: a warning with what helps" \
  "WARN VM stalls: stood still 2 time(s) this run (longest 58 s): the Mac ran out of memory (VM memory 42.0 GB, graphics peak 8.5 GB, Mac 64 GB); give the VM less: omacvm resources --vm \"Omarchy\"" \
  "$(stallrow "$V")"
sed -i.bak 's/^longest_cause=.*/longest_cause=cpu/; s/^longest_ms=.*/longest_ms=2100/; s/^stalls=.*/stalls=1/' "$V/logs/vm-stalls"
expect "no Mac core: a warning about the CPUs" "WARN VM stalls: waited for the Mac's CPUs 1 time(s) this run (longest 2.1 s)" "$(stallrow "$V")"
printf 'stalls=0\ngpu_stalls=3\ngpu_longest_ms=2500\ngpu_last_where=VTDecompressionSessionCreate (from session_create)\n' > "$V/logs/vm-stalls"
expect "only the graphics thread: a warning that names the call" \
  "WARN VM stalls: QEMU's graphics thread stood still 3 time(s) (longest 2.5 s, in VTDecompressionSessionCreate (from session_create))" \
  "$(stallrow "$V")"
printf 'stalls=$(id)\nlongest_ms=x;rm -rf /\ngpu_stalls=1\ngpu_longest_ms=99999999999999999\ngpu_last_where=\033[31m`id`$(rm -rf /)\n' > "$V/logs/vm-stalls"
expect "a file that is not numbers: nothing from it runs or prints raw" \
  "WARN VM stalls: QEMU's graphics thread stood still 1 time(s) (longest 0.0 s, in 31mid(rm -rf ))" \
  "$(stallrow "$V")"
ln -sf /etc/passwd "$T/link"; rm -f "$V/logs/vm-stalls"; ln -s "$T/link" "$V/logs/vm-stalls"
expect "a link, not QEMU's file: no line" "" "$(stallrow "$V")"
exit $fail
