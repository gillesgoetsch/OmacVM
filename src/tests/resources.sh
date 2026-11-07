#!/bin/bash
# Tests for omacvm resources (src/cmd/resources.sh, src/lib/resources.sh):
# vm.env's writer on fixture files, the tiers, the memory warning and the
# command on a stand-in Mac with a VMs folder of its own.
#   src/tests/resources.sh
# Exit 0 when every test passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/resources.sh"
T=$(mktemp -d); FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
eq() { [[ $1 == "$2" ]] || { echo "        got '$1', want '$2'" >&2; return 1; }; }

echo "fixtures"
# OmacVM.app: vm.env as the app and omacvm build write it (quotes kept elsewhere).
cat > "$T/vm.env" <<'EOF'
NAME='It'\''s mine'
CPUS='8'
MEM_MB=16384
DISK_GB=64
FEATURES='bridge=on wallpaper=on'
EOF
res_env_set "$T/vm.env" 4 6144
check "vm.env: CPUS and MEM_MB changed" eq "$(grep -E '^(CPUS|MEM_MB)=' "$T/vm.env" | paste -sd' ' -)" "CPUS=4 MEM_MB=6144"
check "vm.env: the other lines as they were" eq "$(grep -vE '^(CPUS|MEM_MB)=' "$T/vm.env" | paste -sd'|' -)" "NAME='It'\\''s mine'|DISK_GB=64|FEATURES='bridge=on wallpaper=on'"
printf "NAME='x'\n" > "$T/old.env"; res_env_set "$T/old.env" 2 4096
check "vm.env without the keys: added" eq "$(paste -sd' ' - < "$T/old.env")" "NAME='x' CPUS=2 MEM_MB=4096"
check "vm.env: no temporary file left" eq "$(ls "$T" | grep -c 'env\.')" 0

# Tiers as omacvm build gives them, for a few Macs (OmacVM.app's Mac.tier is the same rule).
tiers() {   # CORES PERF EFF MEM_GB -> the four tiers, "cpus/gb" each
  local t out=""
  mac_cores=$1 mac_perf=$2 mac_eff=$3 mac_mem_gb=$4 CAP_CPUS=$1 CAP_MEM_GB=$4
  for t in 0 1 2 3; do tier_values "$t"; out+="$T_CPUS/$T_MEM "; done
  echo "${out% }"
}
check "tiers: M4 Max 16 cores 64 GB" eq "$(tiers 16 12 4 64)" "6/16 12/32 14/40 16/48"
check "tiers: M1 8 cores 8 GB" eq "$(tiers 8 4 4 8)" "2/4 4/4 6/4 8/4"
check "tiers: M2 8 cores 16 GB" eq "$(tiers 8 4 4 16)" "2/4 4/8 6/8 8/8"

echo "memory above the Best tier"
# The maintainer's Mac mini (16 GB, 2026-10-30): 12 GB set, graphics peak 4619 MB, Activity Monitor 23 GB. A warning
# that says what comes on top for each app, the Best tier and the command; none at or below it. Never a change.
warn_on() { mac_mem_gb=$1; shift; mem_warning "$@"; }   # MAC_GB TYPE MB VM [PEAK_MB]
check "the Best tier: 8 GB Mac 4, 16 GB 8, 64 GB 48, 128 GB 96 (as the app's)" eq "$(for m in 8 16 64 128; do mac_mem_gb=$m; tier_best_mem; done | paste -sd' ' -)" "4 8 48 96"
check "16 GB Mac, app VM at 12 GB: the graphics on top with the last run's peak" eq "$(warn_on 16 app 12288 Omarchy 4619)" \
  "12 GB and the VM's graphics on top (peak 4.5 GB last run) leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"Omarchy\" --resources best"
check "app VM before its first run (no peak, or 0): no peak said" eq "$(warn_on 16 app 9216 A)|$(warn_on 16 app 9216 A 0)" \
  "9 GB and the VM's graphics on top leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"A\" --resources best|9 GB and the VM's graphics on top leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"A\" --resources best"
check "another VM type at 12 GB: the warning, nothing about graphics on top" eq "$(warn_on 16 other 12288 Omarchy)" \
  "12 GB leaves macOS too little of this Mac's 16 GB: the Mac can slow down or swap. 8 GB is this Mac's Best tier: omacvm resources --vm \"Omarchy\" --resources best"
check "at the Best tier and below: nothing (8 GB on 16, 4 GB on 8, 48 GB on 64)" eq "$(warn_on 16 app 8192 X 4619; warn_on 8 app 4096 X; warn_on 64 app 49152 X)" ""
check "not whole GB (a VM set up by hand): in MB" eq "$(warn_on 8 app 6000 X | cut -d' ' -f1-2)" "6000 MB"
check "a peak that is not a number: not said" eq "$(warn_on 16 app 12288 X '1;rm' | grep -c peak)" 0

# The command, OmacVM.app route, on a stand-in 16 GB Mac (sysctl), in a VMs folder of the test's own (the test
# identity's under a HOME of its own: no other app's VMs are read, nothing else is written).
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/sysctl" <<'S'
#!/bin/bash
case "$*" in
  "-n hw.memsize") echo 17179869184 ;;
  "-n hw.ncpu") echo 10 ;;
  "-n hw.perflevel0.physicalcpu") echo 4 ;;
  "-n hw.perflevel1.physicalcpu") echo 6 ;;
  *) exec /usr/sbin/sysctl "$@" ;;
esac
S
chmod +x "$T/bin/sysctl"
MV="$T/home/OmacVM Test VMs/Mini"; mkdir -p "$MV/logs"; : > "$MV/disk.img"
printf "NAME='Mini'\nCPUS=10\nMEM_MB=12288\nDISK_GB=64\n" > "$MV/vm.env"
printf 'in_use_mb=2186\npeak_mb=4619\n' > "$MV/logs/gpu-memory"
mini() { HOME=$T/home PATH=$T/bin:$PATH OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=org.omacvm.app.test.resources-fixture \
  OMACVM_APP_NEWER_SAID=1 "$R/omacvm" resources --vm Mini --vm-type app "$@" 2>&1; }
jget() { python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d.get("memory_gb"), d.get("warning", "-"))' "$1"; }
out=$(mini --yes); rc=$?
check "command: a VM already above the Best tier says so when read (exit 0)" eq "$rc $(grep -c "^Warning: 12 GB and the VM's graphics on top (peak 4.5 GB last run) leave macOS too little of this Mac's 16 GB" <<<"$out")" "0 1"
check "command --json: the same warning, nothing else new" eq "$(jget "$(mini --json)")" \
  "12 12 GB and the VM's graphics on top (peak 4.5 GB last run) leave macOS too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. 8 GB is this Mac's Best tier: omacvm resources --vm \"Mini\" --resources best"
out=$(mini --resources best); rc=$?
check "command --resources best: 8 GB, no warning" eq "$rc $(app_env "$MV" MEM_MB) $(grep -c Warning <<<"$out")" "0 8192 0"
check "command --json at 8 GB: no warning key" eq "$(jget "$(mini --json)")" "8 -"
out=$(mini --memory-gb 12); rc=$?
check "command: a change above the Best tier is made, with the warning" eq "$rc $(app_env "$MV" MEM_MB) $(grep -c '^Warning: 12 GB' <<<"$out")" "0 12288 1"

echo "$((N - FAIL)) of $N passed"
(( FAIL == 0 ))
