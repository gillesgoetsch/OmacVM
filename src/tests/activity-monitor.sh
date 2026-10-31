#!/bin/bash
# omacvm check's "Activity Monitor" row (src/cmd/check.sh): QEMU's footprint,
# Activity Monitor's Memory for an OmacVM.app VM, and what it is made of
# without a guess: VM memory at most QEMU's -m, graphics now from
# logs/gpu-memory, the rest when above 0 (QEMU itself, graphics overhead,
# the VM's pages QEMU touched, which macOS counts twice; with a QEMU that says
# "own-view sweep: on" in qemu.log only those since its last sweep); a warning
# above this Mac's Best tier, never a failure; no line without QEMU, its
# footprint or the file. Stand-ins for QEMU's process, its footprint and the Mac's memory;
# src/lib/footprint.py on real processes. No VM. macOS only.
#   src/tests/activity-monitor.sh
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
row=$(sed -n '/^  # Activity Monitor.s Memory for the VM/,/^  fi   # Activity Monitor$/p' "$C")
expect "check.sh has the row, and it is never bad" "yes 0" "$([[ -n $row ]] && echo yes) $(grep -c 'bad ' <<< "$row")"
source "$R/src/lib/setup.sh"
# amrow VMDIR: the row's text ("" when none), with PID (QEMU's, "" = not running), FP (its footprint in MB, "" =
# unreadable), ARGS (its command line), VMM (vm.env's MEM_MB) and MACGB (the Mac's memory) as the stand-ins say.
amrow() {
  ( ok() { echo "ok $1: $2"; }; warn() { echo "WARN $1: $2"; }
    eval "$(grep -m1 '^  gb() {' "$C")"
    eval "$(grep -m1 '^  gmv() {' "$C")"
    sysctl() { if [[ $2 == hw.memsize ]]; then echo $(( MACGB << 30 )); else echo 10; fi; }
    app_pid_dir() { [[ $1 == "$V" ]] && echo "$PID"; }
    fp_mb() { [[ $1 == "$PID" && -n $FP ]] && echo "$FP"; }
    ps() { [[ "$*" == "-o args= -p $PID" ]] && echo "$ARGS"; }
    VM="Omarchy"; vmm=$VMM
    miclog=$1/logs/qemu.log; gm=$1/logs/gpu-memory
    eval "$row" )
}
V=$T/Omarchy; mkdir -p "$V/logs"; : > "$V/logs/qemu.log"
REST="(QEMU itself, graphics overhead and pages of the VM QEMU touched, which macOS counts twice)"
SWEPT="(QEMU itself, graphics overhead and pages of the VM QEMU touched since its last sweep, counted twice until then)"
# The maintainer's Mac mini, read on 2026-10-30 15:25: 16 GB Mac, the VM at 10 GB, QEMU's footprint 19748 MB,
# 3328 MB of graphics in use.
PID=4242 FP=19748 VMM=10240 MACGB=16
ARGS="/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM-VM -name Omarchy -machine virt -m 10240M -smp 10"
printf 'in_use_mb=3328\npeak_mb=3687\nbudget_mb=12288\npressure=warn\n' > "$V/logs/gpu-memory"
expect "the mini at 10 GB: what the number is made of, and the warning above the Best tier" \
  "WARN Activity Monitor: 19.3 GB for the VM: VM memory at most 10.0 GB, graphics 3.2 GB now, the rest 6.0 GB $REST; 10 GB and the VM's graphics on top leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"Omarchy\" --resources best" \
  "$(amrow "$V")"
VMM=8192
expect "lowered to the Best tier while the VM runs at 10 GB: the warning says the new setting applies at the next start" \
  "WARN Activity Monitor: 19.3 GB for the VM: VM memory at most 10.0 GB, graphics 3.2 GB now, the rest 6.0 GB $REST; 10 GB and the VM's graphics on top leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"Omarchy\" --resources best; 8 GB is set (applies at the next start)" \
  "$(amrow "$V")"
ARGS="OmacVM-VM -name Omarchy -m 8192M -smp 10" FP=11000 VMM=8192
printf 'in_use_mb=2186\npeak_mb=2510\n' > "$V/logs/gpu-memory"
expect "at the Best tier (8 GB on 16): ok, no warning" \
  "ok Activity Monitor: 10.7 GB for the VM: VM memory at most 8.0 GB, graphics 2.1 GB now, the rest 622 MB $REST" "$(amrow "$V")"
FP=5000; printf 'in_use_mb=1200\n' > "$V/logs/gpu-memory"
expect "less than VM memory and graphics (Linux has not touched it all): no rest" \
  "ok Activity Monitor: 4.9 GB for the VM: VM memory at most 8.0 GB, graphics 1.2 GB now" "$(amrow "$V")"
VMM=4096
expect "vm.env changed while the VM runs: QEMU's -m counts, not the next start's" \
  "ok Activity Monitor: 4.9 GB for the VM: VM memory at most 8.0 GB, graphics 1.2 GB now" "$(amrow "$V")"
ARGS="OmacVM-VM -name Omarchy" VMM=12288 FP=23552 MACGB=16
printf 'in_use_mb=4619\n' > "$V/logs/gpu-memory"
expect "no -m on QEMU's line: vm.env's memory (the maintainer's 12 GB run: 23 GB in Activity Monitor)" \
  "WARN Activity Monitor: 23.0 GB for the VM: VM memory at most 12.0 GB, graphics 4.5 GB now, the rest 6.5 GB $REST; 12 GB and the VM's graphics on top leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"Omarchy\" --resources best" \
  "$(amrow "$V")"
MACGB=64
expect "the same on a 64 GB Mac: ok (its Best tier is 48 GB)" "ok" "$(amrow "$V" | cut -d' ' -f1)"
PID=""
expect "QEMU not running: no line" "" "$(amrow "$V")"
# The words come from this QEMU's own line (an omacvm can run beside an older app's QEMU): the first one.
PID=4242
printf '%s\n' "OmacVM-VM: OmacVM: own-view sweep: on: QEMU remaps its view of the VM's 12288 MB every 300 s, so Activity Monitor counts the VM's pages once (OMACVM_DCOUNT_SWEEP=0 turns it off)" > "$V/logs/qemu.log"
expect "a QEMU that sweeps its own view: only what it touched since its last sweep is counted twice" \
  "ok Activity Monitor: 23.0 GB for the VM: VM memory at most 12.0 GB, graphics 4.5 GB now, the rest 6.5 GB $SWEPT" "$(amrow "$V")"
printf '%s\n' "OmacVM-VM: OmacVM: own-view sweep: on: QEMU remaps its view of the VM's 12288 MB every 300 s" \
  "OmacVM-VM: warning: OmacVM: own-view sweep: stopped for this run: a remap at +0 MB failed ((os/kern) no space available, protection 0)" > "$V/logs/qemu.log"
expect "the sweep stopped for the run: counted twice, as before" \
  "ok Activity Monitor: 23.0 GB for the VM: VM memory at most 12.0 GB, graphics 4.5 GB now, the rest 6.5 GB $REST" "$(amrow "$V")"
printf '%s\n' "OmacVM-VM: OmacVM: own-view sweep: off (OMACVM_DCOUNT_SWEEP=0): Activity Monitor counts the VM's pages QEMU touches twice" \
  "guest: OmacVM: own-view sweep: on" > "$V/logs/qemu.log"
expect "the sweep switched off (its first line): counted twice, as before" \
  "ok Activity Monitor: 23.0 GB for the VM: VM memory at most 12.0 GB, graphics 4.5 GB now, the rest 6.5 GB $REST" "$(amrow "$V")"
: > "$V/logs/qemu.log"
PID=4242 FP=""
expect "its footprint not readable (no python3 here, or QEMU just ended): no line" "" "$(amrow "$V")"
FP=23552; rm "$V/logs/gpu-memory"
expect "no logs/gpu-memory (a runtime without it): no line" "" "$(amrow "$V")"
printf 'in_use_mb=4619\n' > "$T/elsewhere"; ln -s "$T/elsewhere" "$V/logs/gpu-memory"
expect "logs/gpu-memory a link, not QEMU's file: no line" "" "$(amrow "$V")"
rm "$V/logs/gpu-memory"; printf 'in_use_mb=1;id\n' > "$V/logs/gpu-memory"
expect "graphics that are not a number: no line, nothing runs" "" "$(amrow "$V")"

# src/lib/footprint.py on real processes (proc_pid_rusage; nothing suspended).
F=$R/src/lib/footprint.py
PY=$(command -v python3)
sleep 30 & SP=$!
fp=$("$PY" -I "$F" "$SP"); rc=$?
expect "footprint.py: a running process's footprint in MB" "0 yes" "$rc $([[ $fp =~ ^[0-9]+$ ]] && echo yes)"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
out=$("$PY" -I "$F" "$SP"); rc=$?
expect "footprint.py: a process that is gone: nothing, exit 1" "1 " "$rc $out"
"$PY" -I "$F" 'x;id' >/dev/null 2>&1; rc=$?
expect "footprint.py: not a PID: exit 2" "2" "$rc"
exit $fail
