#!/bin/bash
# Tests for omacvm resources (src/cmd/resources.sh, src/lib/resources.sh).
#   src/tests/resources.sh          the settings writers on fixture files only
#   src/tests/resources.sh --live   also the command on throwaway VMs named
#                                   "OmacVM T-resources": a Parallels VM without
#                                   a disk (prlctl create), a UTM VM without
#                                   drives (UTM's scripting; UTM opens if it is
#                                   not running), a Fusion .vmx and an OmacVM.app
#                                   folder (fixtures). Only the UTM VM is
#                                   started, without a display (it has no
#                                   disk), to suspend it; all are deleted at
#                                   the end.
# Exit 0 when every test passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
source "$R/src/vm/utm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/lib/resources.sh"
LIVE=0; [[ ${1:-} == --live ]] && LIVE=1
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

# UTM: config.plist's System dictionary.
cat > "$T/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>System</key><dict><key>Architecture</key><string>aarch64</string><key>CPUCount</key><integer>6</integer><key>MemorySize</key><integer>8192</integer></dict>
</dict></plist>
EOF
res_plist_set "$T/config.plist" 3 5120
check "config.plist: CPUCount and MemorySize" eq "$(plutil -extract System.CPUCount raw "$T/config.plist") $(plutil -extract System.MemorySize raw "$T/config.plist")" "3 5120"
check "config.plist: integers, the rest kept" eq "$(plutil -extract System.CPUCount xml1 -o - "$T/config.plist" | grep -c '<integer>') $(plutil -extract System.Architecture raw "$T/config.plist")" "1 aarch64"

# VMware Fusion: the .vmx, and its graphics memory that comes out of the VM's.
cat > "$T/x.vmx" <<'EOF'
.encoding = "UTF-8"
displayName = "Fixture"
numvcpus = "16"
memsize = "49152"
svga.graphicsMemoryKB = "8388608"
vmotion.svga.graphicsMemoryKB = "8388608"
EOF
RES_NOTE=""; res_vmx_set "$T/x.vmx" 4 16384
check "vmx: numvcpus and memsize" eq "$(vmx_get "$T/x.vmx" numvcpus) $(vmx_get "$T/x.vmx" memsize)" "4 16384"
check "vmx: graphics memory kept while it fits" eq "$(vmx_get "$T/x.vmx" svga.graphicsMemoryKB) ${RES_NOTE:-none}" "8388608 none"
RES_NOTE=""; res_vmx_set "$T/x.vmx" 2 4096
check "vmx: graphics memory lowered when it no longer fits" eq "$(vmx_get "$T/x.vmx" svga.graphicsMemoryKB) $(vmx_get "$T/x.vmx" vmotion.svga.graphicsMemoryKB)" "1048576 1048576"
check "vmx: and says so" eq "$RES_NOTE" "graphics memory down to 1 GB (part of the VM's memory)"
check "vmx: one line per key" eq "$(grep -c '^memsize' "$T/x.vmx")" 1

# Parallels: config.pvs (the path Parallels Desktop Standard takes).
cat > "$T/config.pvs" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<ParallelsVirtualMachine><Hardware><Cpu><Number>4</Number><AutoCountEnabled>1</AutoCountEnabled></Cpu><Memory><RAM>8192</RAM><RamAutoSizeEnabled>1</RamAutoSizeEnabled></Memory></Hardware></ParallelsVirtualMachine>
EOF
res_pvs_set "$T/config.pvs" 6 12288
check "config.pvs: CPUs, memory, automatic sizing off" eq "$(for p in Cpu/Number Cpu/AutoCountEnabled Memory/RAM Memory/RamAutoSizeEnabled; do python3 "$PVS" "$T/config.pvs" get "Hardware/$p"; done | paste -sd' ' -)" "6 0 12288 0"

# Parallels Pro (and Business): a failing prlctl set is the real error, shown
# as it is; only Standard edits config.pvs (a prlctl that logs its calls).
printf '#!/bin/bash\necho "$*" >> "%s/prl.log"\n[[ $1 == set ]] && { echo "The VM is busy" >&2; exit 1; }\nexit 0\n' "$T" > "$T/prl-pro"; chmod +x "$T/prl-pro"
err=$(PRLCTL=$T/prl-pro; P_EDITION=pro; res_set "Some VM" parallels 2 4096 2>&1); rc=$?
check "parallels pro: prlctl set fails -> its error, exit 1" eq "$rc $err" "1 Parallels: The VM is busy"
check "parallels pro: no unregister, no settings file edit" eq "$(cut -d' ' -f1 "$T/prl.log" | paste -sd' ' -)" "set"

# UTM closed (also when it runs on this Mac): its registry says which VMs it
# suspended (saved state).
mkdir -p "$T/utm/A.utm" "$T/utm/B.utm"
for v in A B; do plutil -create xml1 "$T/utm/$v.utm/config.plist"; plutil -insert Information -dictionary "$T/utm/$v.utm/config.plist"; plutil -insert Information.Name -string "Fixture $v" "$T/utm/$v.utm/config.plist"; done
python3 - "$T" <<'PY'
import plistlib, sys
t = sys.argv[1]
reg = {"1": {"Package": {"Path": f"{t}/utm/A.utm"}, "Suspended": True},
       "2": {"Package": {"Path": f"{t}/utm/B.utm"}, "Suspended": False}}
plistlib.dump({"Registry": reg}, open(f"{t}/utm.plist", "wb"))
PY
got=$(UTMCTL=/nonexistent; UTM_PREFS=$T/utm.plist; pgrep() { [[ "$*" == "-xq UTM" ]] && return 1; command pgrep "$@"; }; vms_list 2>/dev/null | awk -F'\t' '$2 == "utm" && $1 ~ /^Fixture/ { print $1 "=" $3 }' | sort | paste -sd' ' -)
check "UTM closed: a suspended VM is listed suspended, not stopped" eq "$got" "Fixture A=suspended Fixture B=stopped"

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

if (( LIVE )); then
  echo "throwaway VMs (OmacVM T-resources)"
  NAME="OmacVM T-resources"
  O="$R/omacvm"
  APPDIR="$(app_vms_root)/$NAME"
  export OMACVM_FUSION_DIR=$T/fusion
  FUSION_DIR=$OMACVM_FUSION_DIR
  UTM_ID=""
  utm_status() { "$UTMCTL" status "$UTM_ID" 2>/dev/null; }
  utm_wait() { local i; for ((i = 0; i < 30; i++)); do [[ $(utm_status) == "$1" ]] && return 0; sleep 1; done; return 1; }
  cleanup() {
    "$PRLCTL" delete "$NAME" >/dev/null 2>&1
    if [[ -n $UTM_ID ]]; then
      # A suspended VM is deleted only once stopped: resume it, then stop it.
      [[ $(utm_status) == paused ]] && { "$UTMCTL" start --hide "$UTM_ID" >/dev/null 2>&1; utm_wait started; }
      [[ $(utm_status) == stopped ]] || { "$UTMCTL" stop "$UTM_ID" >/dev/null 2>&1; utm_wait stopped; }
      osascript -e "tell application \"UTM\" to delete virtual machine id \"$UTM_ID\"" >/dev/null 2>&1
    fi
    [[ -f $APPDIR/vm.env && $(app_env "$APPDIR" NAME) == "$NAME" ]] && rm -rf "$APPDIR"
    [[ -n ${FAKE_PID:-} ]] && kill "$FAKE_PID" 2>/dev/null
    rm -rf "$T"
  }
  trap cleanup EXIT
  [[ -e $APPDIR ]] && { echo "  $APPDIR exists already: not touching it" >&2; exit 1; }

  "$PRLCTL" create "$NAME" --ostype linux --distribution ubuntu --no-hdd >/dev/null || bad "Parallels: throwaway VM"
  mkdir -p "$OMACVM_FUSION_DIR/$NAME.vmwarevm"
  printf '.encoding = "UTF-8"\ndisplayName = "%s"\nnumvcpus = "4"\nmemsize = "8192"\nsvga.graphicsMemoryKB = "2097152"\n' "$NAME" > "$OMACVM_FUSION_DIR/$NAME.vmwarevm/$NAME.vmx"
  mkdir -p "$APPDIR"; : > "$APPDIR/disk.img"
  printf "NAME='%s'\nCPUS=4\nMEM_MB=8192\nDISK_GB=64\nSSH_PORT=52399\nVM_USER='t'\n" "$NAME" > "$APPDIR/vm.env"
  UTM_ID=$(utm_osa -e 'tell application "UTM" to return id of (make new virtual machine with properties {backend:qemu, configuration:{name:"'"$NAME"'", architecture:"aarch64", memory:4096, cpu cores:2, hypervisor:true, uefi:true, notes:"omacvm resources test, deleted after it"}})')
  [[ $UTM_ID =~ ^[0-9A-F-]{36}$ ]] || { bad "UTM: throwaway VM ($UTM_ID)"; UTM_ID=""; }

  out=$("$O" resources --vm "$NAME" --cpus 2 2>&1); rc=$?
  check "a name in four apps is refused (exit 2)" eq "$rc" 2
  check "and the message names --vm-type" eq "$(grep -c -- '--vm-type' <<<"$out")" 1

  for t in parallels utm fusion app; do
    [[ $t == utm && -z $UTM_ID ]] && continue
    "$O" resources --vm "$NAME" --vm-type $t --cpus 3 --memory-gb 5 >/dev/null; rc=$?
    check "$t: --cpus 3 --memory-gb 5" eq "$rc $(res_get "$NAME" $t)" "0 3 5120"
    "$O" resources --vm "$NAME" --vm-type $t --resources low >/dev/null
    mac_specs; CAP_CPUS=$mac_cores; CAP_MEM_GB=$mac_mem_gb; tier_values 0
    check "$t: --resources low" eq "$(res_get "$NAME" $t)" "$T_CPUS $((T_MEM * 1024))"
    "$O" resources --vm "$NAME" --vm-type $t --cpus 999 >/dev/null 2>&1; rc=$?
    check "$t: more CPUs than the Mac has is refused" eq "$rc $(res_get "$NAME" $t)" "2 $T_CPUS $((T_MEM * 1024))"
    j=$("$O" resources --vm "$NAME" --vm-type $t --memory-gb 4 --json)
    check "$t: --json after a change" eq "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["type"], d["memory_gb"], d["changed"])' "$j")" "$t 4 True"
  done

  # Parallels Desktop Standard: no prlctl set, the settings file instead.
  printf '#!/bin/bash\n[[ $1 == set ]] && { echo "only in Pro" >&2; exit 1; }\nexec /usr/local/bin/prlctl "$@"\n' > "$T/prlctl"; chmod +x "$T/prlctl"
  REAL=$PRLCTL; PRLCTL=$T/prlctl
  P_EDITION=standard res_set "$NAME" parallels 2 6144; rc=$?
  PRLCTL=$REAL
  check "parallels without prlctl set: config.pvs while unregistered" eq "$rc $(res_get "$NAME" parallels)" "0 2 6144"
  check "parallels: registered again" eq "$(vm_state "$NAME")" stopped
  check "parallels: Parallels reads the new values" eq "$("$PRLCTL" list -i "$NAME" | awk '$1 == "cpu" { print $2 } $1 == "memory" { print $2 }' | paste -sd' ' -)" "cpus=2 size=6144Mb"

  # Pro: the same refusal is shown, and the VM stays as it is and registered.
  PRLCTL=$T/prlctl
  err=$(P_EDITION=pro res_set "$NAME" parallels 3 8192 2>&1); rc=$?
  PRLCTL=$REAL
  check "parallels pro: prlctl's error shown, nothing changed" eq "$rc $err $(res_get "$NAME" parallels) $(vm_state "$NAME")" "1 Parallels: only in Pro 2 6144 stopped"

  # In a terminal (expect): --yes never asks; Custom with Return keeps the
  # memory exactly, also under 4 GB.
  cat > "$T/drive.exp" <<'EXP'
set timeout 15
spawn {*}[lrange $argv 1 end]
foreach k [split [lindex $argv 0] ","] {
  if {$k eq ""} continue
  lassign [split $k "="] what answer
  if {$what eq "menu"} { expect "should"; sleep 0.3; send -- $answer; sleep 0.3; send "\r" } else { expect $what; send -- "$answer\r" }
}
expect { timeout { puts "\nTIMEOUT"; exit 124 } eof }
exit [lindex [wait] 3]
EXP
  drive() { expect -f "$T/drive.exp" "$1" "$O" resources --vm "$NAME" --vm-type app "${@:2}"; }
  out=$(drive "" --yes 2>&1); rc=$?
  check "app, in a terminal, --yes: says what it has, asks nothing" eq "$rc $(grep -c 'Change with' <<<"$out") $(grep -c 'How much' <<<"$out")" "0 1 0"
  res_env_set "$APPDIR/vm.env" 4 6000
  out=$(drive "menu=5,CPUs=,memory in GB=" 2>&1); rc=$?
  check "app, Custom, Return twice: 6000 MB stays 6000 MB" eq "$rc $(res_get "$NAME" app) $(grep -c 'nothing changed' <<<"$out")" "0 4 6000 1"
  res_env_set "$APPDIR/vm.env" 4 3072
  out=$(drive "menu=5,CPUs=,memory in GB=" 2>&1); rc=$?
  check "app, Custom, Return under 4 GB: kept, no error" eq "$rc $(res_get "$NAME" app)" "0 4 3072"
  out=$(drive "menu=5,CPUs=3,memory in GB=5" 2>&1); rc=$?
  check "app, Custom, typed: 3 CPUs and 5 GB" eq "$rc $(res_get "$NAME" app)" "0 3 5120"

  # UTM with a saved state: refused while UTM runs ("paused") and while it is
  # closed (its registry; UTM "closed" through a pgrep that does not see it).
  if [[ -n $UTM_ID && ! -e $HOME/.omacvm-user-testing ]]; then
    "$UTMCTL" start --hide "$UTM_ID" >/dev/null 2>&1; utm_wait started
    "$UTMCTL" suspend --save-state "$UTM_ID" >/dev/null 2>&1; utm_wait paused
    for ((i = 0; i < 20; i++)); do [[ $(plutil -extract "Registry.$UTM_ID.Suspended" raw "$UTM_PREFS" 2>/dev/null) == true ]] && break; sleep 1; done
    before=$(res_get "$NAME" utm)
    out=$("$O" resources --vm "$NAME" --vm-type utm --cpus 1 2>&1); rc=$?
    check "utm suspended, UTM running: refused (exit 3), unchanged" eq "$rc $(res_get "$NAME" utm) $(grep -c paused <<<"$out")" "3 $before 1"
    mkdir -p "$T/bin"; printf '#!/bin/bash\n[[ "$*" == "-xq UTM" ]] && exit 1\nexec /usr/bin/pgrep "$@"\n' > "$T/bin/pgrep"; chmod +x "$T/bin/pgrep"
    out=$(PATH=$T/bin:$PATH "$O" resources --vm "$NAME" --vm-type utm --cpus 1 2>&1); rc=$?
    check "utm suspended, UTM closed: refused (exit 3), unchanged" eq "$rc $(res_get "$NAME" utm) $(grep -c suspended <<<"$out")" "3 $before 1"
  elif [[ -n $UTM_ID ]]; then
    echo "  skip  UTM suspended: the user is testing (~/.omacvm-user-testing), no VM starts"
  fi

  # OmacVM.app while its VM runs: written, for the next start (a stand-in
  # process with the VM's disk on its command line, as QEMU has).
  (exec -a "qemu-stand-in -drive file=$APPDIR/disk.img,format=raw" sleep 60) & FAKE_PID=$!
  sleep 1
  out=$("$O" resources --vm "$NAME" --vm-type app --cpus 2 2>&1); rc=$?
  check "app, running: changed for the next start" eq "$rc $(grep -c 'applies on the next start' <<<"$out")" "0 1"
  kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""
fi
echo "$((N - FAIL)) of $N passed"
(( FAIL == 0 ))
