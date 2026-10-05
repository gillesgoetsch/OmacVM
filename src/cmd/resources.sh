#!/bin/bash
# omacvm resources: the CPUs and memory of an existing VM.
#   omacvm resources --vm NAME                  what it has, and what each tier gives
#   omacvm resources --vm NAME --resources low|balanced|high|best
#   omacvm resources --vm NAME --cpus N --memory-gb N   (either one alone too)
#   --vm-type parallels|utm|fusion|app   when the name is used in more than one app
#   --json   the VM's resources, the limits and the tiers (after a change: the
#            new ones and "changed": true; a change applies on the next start)
# The same tiers and limits as omacvm build: 1 CPU up to this Mac's, 4 GB up
# to its memory, within the Parallels licence. Parallels, UTM and VMware Fusion
# change a stopped VM only (shut it down first); OmacVM.app's VM takes the
# change at its next start. In a terminal without a change it asks (not with
# --yes or --json).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person (shut the VM down).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/ui.sh"
source "$R/src/vm/utm.sh"
source "$R/src/vm/fusion.sh"
source "$R/src/lib/resources.sh"
VM=""; TYPE=""; RES=""; CPUS=""; MEM_GB=""; JSON=0; YES=0
usage() { echo "omacvm resources: $*" >&2; exit 2; }
needs_person() { printf '\033[1;31mneeds you:\033[0m %s\n' "$*" >&2; exit 3; }
while (( $# )); do
  case $1 in
    --vm|--vm-type|--resources|--cpus|--memory-gb) [[ $# -ge 2 ]] || usage "$1 needs a value" ;;
  esac
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --resources) RES=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory-gb) MEM_GB=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,14s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
case $TYPE in ""|parallels|utm|fusion|app) ;; *) usage "--vm-type parallels, utm, fusion or app" ;; esac
case $RES in ""|low|balanced|high|best) ;; *) usage "--resources low, balanced, high or best" ;; esac
[[ -z $CPUS || $CPUS =~ ^[0-9]+$ ]] || usage "--cpus: a number"
[[ -z $MEM_GB || $MEM_GB =~ ^[0-9]+$ ]] || usage "--memory-gb: a number of GB"
app_label() { case $1 in parallels) echo Parallels ;; utm) echo UTM ;; fusion) echo "VMware Fusion" ;; app) echo OmacVM.app ;; *) echo "$1" ;; esac; }

# The one VM of that name (and type). A name in two apps, or twice in one
# app, is refused: changing the wrong VM is worse than asking.
hits=$(vms_list | awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && (t == "" || $2 == t) { print $2 "\t" $3 }')
count=$(grep -c . <<<"$hits" || true)
if (( count == 0 )); then
  usage "no ${TYPE:+$(app_label "$TYPE") }VM named '$VM' (omacvm vms lists them)"
elif (( count > 1 )); then
  types=$(cut -f1 <<<"$hits" | sort -u)
  if [[ $(grep -c . <<<"$types") == 1 ]]; then
    usage "$(app_label "$types") has $count VMs named '$VM': rename one first"
  fi
  usage "'$VM' is the name of a VM in $(while read -r t; do app_label "$t"; done <<<"$types" | paste -sd, - | sed 's/,/ and /g'): add --vm-type $(paste -sd'|' - <<<"$types")"
fi
TYPE=${hits%%$'\t'*}; STATE=${hits#*$'\t'}
[[ $STATE != invalid ]] || die "Parallels lists '$VM' as invalid (its files are gone)"

# Limits as omacvm build has them: this Mac, and the Parallels licence.
mac_specs
CAP_CPUS=$mac_cores; CAP_MEM_GB=$mac_mem_gb; LIMITED=""
if [[ $TYPE == parallels ]]; then
  parallels_limits || parallels_standard_limits
  (( CAP_CPUS > mac_cores )) && CAP_CPUS=$mac_cores
  (( CAP_MEM_GB > mac_mem_gb )) && CAP_MEM_GB=$mac_mem_gb
  [[ $P_EDITION == standard ]] && LIMITED=" (Parallels Desktop Standard: $CAP_CPUS CPUs / $CAP_MEM_GB GB per VM)"
fi

now=$(res_get "$VM" "$TYPE") || die "could not read the CPUs and memory of '$VM' from its $(app_label "$TYPE") settings"
OLD_CPUS=${now% *}; OLD_MB=${now#* }

show_json() {   # CHANGED
  local t
  printf '{"vm": %s, "type": "%s", "state": %s, "cpus": %s, "memory_gb": %s, "memory_mb": %s, "changed": %s,\n' \
    "$(json_str "$VM")" "$TYPE" "$(json_str "$STATE")" "$OLD_CPUS" "$(( OLD_MB / 1024 ))" "$OLD_MB" "$1"
  printf '  "limits": {"cpus": %s, "memory_gb": %s},\n  "resource_tiers": {' "$CAP_CPUS" "$CAP_MEM_GB"
  for t in 0 1 2 3; do
    tier_values "$t"
    printf '%s"%s": {"cpus": %s, "memory_gb": %s}' "$( ((t)) && echo ', ')" "$(tr '[:upper:]' '[:lower:]' <<<"${TIERS[$t]}")" "$T_CPUS" "$T_MEM"
  done
  printf '}'
  [[ -n ${RES_NOTE:-} ]] && printf ',\n  "note": %s' "$(json_str "$RES_NOTE")"
  printf '}\n'
}
cpus_text() { (( $1 )) && echo "$1 CPUs" || echo "UTM's default CPUs"; }
mem_text() { (( $1 % 1024 )) && echo "$1 MB" || echo "$(( $1 / 1024 )) GB"; }   # MB -> "6 GB", or "6000 MB" when not whole GB

# No change asked: in a terminal, ask; else (or with --yes) say what it has.
if [[ -z $RES$CPUS$MEM_GB ]]; then
  if (( JSON || YES )) || ! { : < "$TTY"; } 2>/dev/null; then
    if (( JSON )); then show_json false
    else
      echo "'$VM' ($(app_label "$TYPE"), $STATE): $(cpus_text "$OLD_CPUS"), $(mem_text "$OLD_MB") memory"
      echo "This Mac: $mac_cores CPUs, $mac_mem_gb GB${LIMITED}. Change with --resources low|balanced|high|best, --cpus N or --memory-gb N."
    fi
    exit 0
  fi
  opts=()
  for t in 0 1 2 3; do tier_values "$t"; opts+=("${TIERS[$t]}|$T_CPUS CPUs, $T_MEM GB memory"); done
  opts+=("Custom|choose CPUs and memory" "Keep|$(cpus_text "$OLD_CPUS"), $(mem_text "$OLD_MB") memory, as it is")
  ui_select tier "How much of this Mac ($mac_cores CPUs, $mac_mem_gb GB${LIMITED}) should '$VM' get?" 5 "${opts[@]}"
  case $tier in
    5) exit 0 ;;
    4) CPUS=$(ask_value "CPUs (1-$CAP_CPUS)" "$OLD_CPUS" '^[0-9]+$')
       # Return keeps the memory exactly as it is (6000 MB stays 6000 MB, and
       # a VM under 4 GB keeps what it has).
       cur=$(mem_text "$OLD_MB"); cur=${cur% GB}
       MEM_GB=$(ask_value "memory in GB (4-$CAP_MEM_GB)" "$cur" "^([0-9]+|$cur)\$")
       [[ $MEM_GB == "$cur" ]] && MEM_GB="" ;;
    *) RES=$(tr '[:upper:]' '[:lower:]' <<<"${TIERS[$tier]}") ;;
  esac
fi

# The new values: a tier, then explicit ones over it; what is not given stays.
NEW_CPUS=$OLD_CPUS; NEW_MB=$OLD_MB
if [[ -n $RES ]]; then
  case $RES in low) tier_values 0 ;; balanced) tier_values 1 ;; high) tier_values 2 ;; best) tier_values 3 ;; esac
  NEW_CPUS=$T_CPUS; NEW_MB=$(( T_MEM * 1024 ))
fi
[[ -n $CPUS ]] && NEW_CPUS=$CPUS
[[ -n $MEM_GB ]] && NEW_MB=$(( MEM_GB * 1024 ))
# Only what changes is checked: a VM set up by hand keeps what it had.
[[ $NEW_CPUS == "$OLD_CPUS" ]] || (( NEW_CPUS >= 1 && NEW_CPUS <= CAP_CPUS )) || usage "--cpus: 1 to $CAP_CPUS$LIMITED"
[[ $NEW_MB == "$OLD_MB" ]] || (( NEW_MB >= 4096 && NEW_MB <= CAP_MEM_GB * 1024 )) || usage "--memory-gb: 4 to $CAP_MEM_GB GB$LIMITED"

if [[ $NEW_CPUS == "$OLD_CPUS" && $NEW_MB == "$OLD_MB" ]]; then
  if (( JSON )); then show_json false; else echo "'$VM' already has $(cpus_text "$NEW_CPUS") and $(mem_text "$NEW_MB") memory: nothing changed"; fi
  exit 0
fi

# Parallels, UTM and Fusion keep a running VM's settings in memory and would
# refuse or overwrite the change: stopped only. OmacVM.app reads vm.env at
# each start.
if [[ $TYPE != app ]]; then
  [[ $STATE == stopped ]] || needs_person "'$VM' is $STATE: shut it down in $(app_label "$TYPE") first (a suspended VM too: resume it, then shut it down), then run this again"
  if [[ $TYPE == fusion ]]; then
    x=$(fusion_vmx "$VM")
    if compgen -G "$(dirname "$x")/*.vmss" >/dev/null; then
      needs_person "'$VM' is suspended in VMware Fusion: resume it, shut it down, then run this again"
    fi
  fi
fi
res_set "$VM" "$TYPE" "$NEW_CPUS" "$NEW_MB" || die "could not change the CPUs and memory of '$VM' in its $(app_label "$TYPE") settings"
OLD_CPUS=$NEW_CPUS; OLD_MB=$NEW_MB
if (( JSON )); then show_json true; exit 0; fi
msg="'$VM' now has $(cpus_text "$NEW_CPUS") and $(mem_text "$NEW_MB") memory"
[[ -n ${RES_NOTE:-} ]] && msg+="; $RES_NOTE"
if [[ $STATE == running ]]; then echo "$msg. It runs now: this applies on the next start."
else echo "$msg. This applies on the next start."; fi
