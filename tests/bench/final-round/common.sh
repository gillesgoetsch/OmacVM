#!/bin/bash
# Shared by the final-round runners (sourced, not run). macOS's bash 3.2.
# Every result is one JSON line in $OUT with the fairness facts next to it,
# so a number that was taken on a busy, charging or hot Mac shows it, and
# summarize.py keeps it out of the medians.

FR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$FR/../../.." && pwd)
GLMARK2_VERSION=${GLMARK2_VERSION:-2023.01}   # the same glmark2 in every VM
# The agreed setup (docs/benchmarks, 2026-10-03): the VM in full screen on
# the 16" built-in display, so the guest is at least 3000 px wide, and Chrome
# full screen gives every page 1728x1080 at 2x.
MIN_GUEST_WIDTH=${FINAL_ROUND_MIN_GUEST_WIDTH:-3000}
VIEWPORT=${FINAL_ROUND_VIEWPORT:-1728x1080 at 2x}
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
jstr() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# Our temporary files go when the script ends.
FR_TMP=$(mktemp -d)
trap 'rm -rf "$FR_TMP"' EXIT

battery() {   # key -> value from AppleSmartBattery (Yes/No/number)
  ioreg -rw0 -c AppleSmartBattery | tr ',' '\n' | sed -n "s/.*\"$1\" *= *\([A-Za-z0-9]*\).*/\1/p" | head -1
}
# The built-in display's level, read only (the user sets it; never changed
# here), and the thermal state. Built once at load time: they run in subshells.
BRIGHT=$FR_TMP/brightness THERMAL=$FR_TMP/thermal
swiftc -O -o "$BRIGHT" "$REPO/src/bench/brightness.swift" 2>/dev/null || BRIGHT=""
swiftc -O -o "$THERMAL" "$FR/thermal.swift" 2>/dev/null || THERMAL=""
brightness() { if [ -n "$BRIGHT" ]; then "$BRIGHT" 2>/dev/null || echo null; else echo null; fi; }
thermal() { if [ -n "$THERMAL" ]; then "$THERMAL" 2>/dev/null || echo unknown; else echo unknown; fi; }
# pmset's own thermal notes: empty when it has recorded no warning.
thermal_pmset() { pmset -g therm 2>/dev/null | grep -v 'has been recorded' | grep -E '[A-Za-z]' | tr '\n' ';' | sed 's/;$//'; }
# Energy mode: pmset's powermode (0 automatic, 1 low power, 2 high power) and
# lowpowermode on Macs that have only that. Empty when pmset has neither.
pm_value() { pmset -g 2>/dev/null | awk -v k="$1" '$1 == k { print $2; exit }'; }
power_mode() { echo "powermode=$(pm_value powermode) lowpowermode=$(pm_value lowpowermode)"; }
low_power() { [ "$(pm_value powermode)" = 1 ] || [ "$(pm_value lowpowermode)" = 1 ]; }

# Everything that belongs to a hypervisor, by executable path: the apps,
# their VM processes and their background services (Parallels' prl_disp_service
# and prl_naptd, Fusion's vmnet daemons). Only the target's own may run.
HV_PROCS='Parallels Desktop\.app/|VMware Fusion\.app/|UTM\.app/|OmacVM[^/]*\.app/|/prl_|/vmware-|/vmnet-|qemu-system-aarch64|com\.apple\.Virtualization\.VirtualMachine'
VM_PROCS='qemu-system-aarch64|/runtime/bin/OmacVM$|/MacOS/OmacVM-VM$|/prl_vm_app$|/vmware-vmx$|/QEMULauncher$|com\.apple\.Virtualization\.VirtualMachine$'

# Other work on the Mac: hypervisor processes other than the target's, a
# second VM of the target, Claude agents, the bench lock. Prints a JSON
# object; busy=true if anything of it runs.
busy_check() {   # [pattern of the target's processes, kept out of "other"]
  local keep=${1:-NONE} procs other same agents lock load busy=false
  procs=$(ps -axo comm=)
  other=$(echo "$procs" | grep -E "$HV_PROCS" | grep -Ev -- "$keep" | grep -c .)
  same=$(echo "$procs" | grep -E "$VM_PROCS" | grep -E -- "$keep" | grep -c .)
  agents=$(echo "$procs" | grep -Ec '(^|/)claude$')
  lock=$(cat "$HOME/.omacvm-bench.lock/owner" 2>/dev/null)
  load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
  # round.sh holds the lock for the whole round ("final-round ..."): that one is ours.
  if [ "$other" -gt 0 ] || [ "$same" -gt 1 ] || [ "$agents" -gt 1 ]; then busy=true; fi
  case $lock in ''|final-round*) ;; *) busy=true ;; esac
  printf '{"other_vm_processes":%s,"target_vms":%s,"claude_processes":%s,"bench_lock":%s,"load1":%s,"busy":%s}' \
    "$other" "$same" "$agents" "$(jstr "$lock")" "$load" "$busy"
}

# Facts about the Mac for each line.
mac_meta() {
  local disp
  disp=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution:|UI Looks like:/ {gsub(/^ +/, "", $2); printf "%s; ", $2}')
  printf '{"mac":%s,"macos":%s,"display":%s,"brightness":%s,"charging":%s,"external_power":%s,"battery_pct":%s,"power_mode":%s,"thermal":%s,"thermal_pmset":%s}' \
    "$(jstr "$(sysctl -n hw.model)")" "$(jstr "$(sw_vers -productVersion) ($(sw_vers -buildVersion))")" "$(jstr "$disp")" \
    "$(brightness)" "$(jstr "$(battery IsCharging)")" "$(jstr "$(battery ExternalConnected)")" "$(battery CurrentCapacity)" \
    "$(jstr "$(power_mode)")" "$(jstr "$(thermal)")" "$(jstr "$(thermal_pmset)")"
}

# Refuse unless the Mac is as agreed for the final round: on the charger and
# not charging (SystemPowerIn is the whole Mac then), no Low Power Mode, the
# same energy mode as at the round's start, thermal state nominal, nothing
# else busy. The round's energy mode is kept next to OUT (round-state).
# FINAL_ROUND_ALLOW_BUSY=1: run anyway, every line marked "preliminary" with
# the reasons; summarize.py leaves those lines out.
PRELIM=false PRELIM_WHY=""
# preflight_why [target pattern]: what is not as agreed ("; "-separated), empty when all is.
preflight_why() {
  local why="" b state pm t
  [ "$(battery ExternalConnected)" = Yes ] || why="$why; no charger (connect it: SystemPowerIn is the whole Mac only on the charger)"
  [ "$(battery IsCharging)" = No ] || why="$why; the battery is charging (wait until it is full or held)"
  low_power && why="$why; Low Power Mode is on (turn it off in Battery settings)"
  t=$(thermal)
  [ "$t" = nominal ] || why="$why; thermal state $t, not nominal (let the Mac cool down)"
  pm=$(power_mode)
  state=$(dirname "$OUT")/round-state
  if [ -f "$state" ] && [ "$(cat "$state")" != "$pm" ]; then
    why="$why; the energy mode changed in the round ($(cat "$state") at the start, $pm now): set it back"
  fi
  b=$(busy_check "${1:-}")
  case $b in *'"busy":true'*) why="$why; the Mac is not quiet: $b (quit the other VM apps, Parallels' service, agents, test VMs)" ;; esac
  echo "${why#; }"
}
preflight() {   # [target pattern]
  local why state
  why=$(preflight_why "${1:-}")
  state=$(dirname "$OUT")/round-state
  if [ -n "$why" ]; then
    [ "${FINAL_ROUND_ALLOW_BUSY:-0}" = 1 ] || die "$why. (FINAL_ROUND_ALLOW_BUSY=1 runs anyway, marked preliminary)"
    PRELIM=true PRELIM_WHY=$why
    say "numbers marked preliminary: $why"
  elif [ ! -f "$state" ]; then
    power_mode > "$state"
  fi
}

# rec TARGET TEST JSON: one line in $OUT, the result plus the facts.
rec() {
  printf '{"target":"%s","test":"%s","preliminary":%s,"preliminary_why":%s,"result":%s,"mac_state":%s,"quiet":%s,"at":"%s"}\n' \
    "$1" "$2" "$PRELIM" "$(jstr "$PRELIM_WHY")" "$3" "$(mac_meta)" "$(busy_check "${KEEP_VM:-NONE}")" "$(date -u +%FT%TZ)" | tee -a "$OUT"
}

# The VMs the round may use. Only VMs made for the benchmark, named
# "Bench <something>" (the runbook's), never the user's own.
USER_VMS='omarchy|omarchy arm|omacvm test|windows'
bench_vm_ok() {   # NAME -> exit 1 with the reason on stderr
  local lower
  lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if echo "$lower" | grep -Eqx "$USER_VMS"; then echo "\"$1\" is the user's own VM: never benchmark it" >&2; return 1; fi
  case $1 in
    "Bench "?*) return 0 ;;
    *) echo "\"$1\" is not a benchmark VM: the round uses only VMs named \"Bench ...\" (see README.md)" >&2; return 1 ;;
  esac
}

# Is NAME the VM that runs on this hypervisor? (And, for the app, does PORT
# reach it?) Exit 1 with the reason on stderr.
vm_running() {   # app|utm|fusion|parallels NAME [PORT]
  local t=$1 name=$2 port=${3:-} line
  case $t in
    app)
      line=$(ps -axww -o args= | grep -E '(qemu-system-aarch64|/runtime/bin/OmacVM|/MacOS/OmacVM-VM) .*-name ' | grep -F -- "-name $name -" | head -1)
      [ -n "$line" ] || { echo "OmacVM.app runs no VM named \"$name\"" >&2; return 1; }
      case $line in *hostfwd=*) case $line in *":$port-:22"*) ;; *) echo "port $port is not \"$name\"'s SSH" >&2; return 1 ;; esac ;; esac ;;
    parallels)
      prlctl list 2>/dev/null | awk 'NR > 1' | grep -q -- " $name\$" || { echo "Parallels runs no VM named \"$name\"" >&2; return 1; } ;;
    utm)
      /Applications/UTM.app/Contents/MacOS/utmctl list 2>/dev/null | grep -i ' started ' | grep -q -- " $name\$" ||
        { echo "UTM runs no VM named \"$name\"" >&2; return 1; } ;;
    fusion)
      "/Applications/VMware Fusion.app/Contents/Public/vmrun" list 2>/dev/null | grep -qF -- "/$name.vmx" ||
        { echo "VMware Fusion runs no VM named \"$name\"" >&2; return 1; } ;;
    *) echo "unknown target $t" >&2; return 1 ;;
  esac
}
