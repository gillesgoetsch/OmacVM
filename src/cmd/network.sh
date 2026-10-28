#!/bin/bash
# omacvm network: an OmacVM.app VM's network from its next start.
#   omacvm network --vm NAME [--json]                 read the setting
#   omacvm network --vm NAME bridged --interface enN  add a LAN NIC (experimental)
#   omacvm network --vm NAME shared                   restore the shared setting
#   omacvm network --interfaces [--json]              supported physical interfaces
# Bridged LAN keeps a separate private management NIC for SSH and Mac services.
# The VM must run once to install its guest service; changing this setting
# never starts or restarts a VM. Shut down, then start to apply it.
# --yes accepts the guest installation; administrator permission is still
# the person's. OMACVM_ADMIN_PROMPT=none returns 3 if installation is needed.
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person, 4 cancelled.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/network.sh"
VM=""; TYPE=app; SET=""; INTERFACE=""; JSON=0; LIST=0; DIR=""
usage() { echo "omacvm network: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm|--vm-type|--interface|--vm-dir) [[ $# -ge 2 ]] || usage "$1 needs a value"
      case $1 in --vm) VM=$2 ;; --vm-type) TYPE=$2 ;; --interface) INTERFACE=$2 ;; --vm-dir) DIR=$2 ;; esac; shift 2 ;;
    --json) JSON=1; shift ;;
    --interfaces) LIST=1; shift ;;
    --yes|-y) shift ;;
    shared|bridged) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ $TYPE == app ]] || usage "this setting is OmacVM.app only"
if (( LIST )); then
  [[ -z $SET && -z $INTERFACE && -z $VM && -z $DIR ]] || usage "--interfaces is a separate listing"
  interfaces=$("$R/src/net/mac/install.sh" --interfaces) || exit $?
  if (( JSON )); then
    printf '{"interfaces": ['; comma=""
    while IFS= read -r ifc; do
      [[ -z $ifc ]] && continue
      network_interface_valid "$ifc" || continue
      printf '%s%s' "$comma" "$(json_str "$ifc")"; comma=", "
    done <<<"$interfaces"
    printf ']}\n'
  else printf '%s\n' "$interfaces"; fi
  exit 0
fi
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
if [[ -n $DIR ]]; then export OMACVM_APP_VM_DIR=$DIR; fi
d=$(app_dir "$VM") || usage "no unique OmacVM.app VM named '$VM' (omacvm vms lists them)"
[[ -z $INTERFACE || $SET == bridged ]] || usage "--interface goes with bridged"
if [[ $SET == bridged ]]; then
  [[ -n $INTERFACE ]] || usage "bridged needs --interface IF (omacvm network --interfaces lists them)"
  network_interface_valid "$INTERFACE" || usage "--interface must be a physical interface name (enN)"
  interfaces=$("$R/src/net/mac/install.sh" --interfaces) || exit $?
  supported=0
  while IFS= read -r ifc; do [[ $ifc != "$INTERFACE" ]] || supported=1; done <<<"$interfaces"
  (( supported )) || usage "'$INTERFACE' is not a bridge-capable interface (omacvm network --interfaces lists them)"
fi
CHANGED=false
old=$(cat "$d/bridged-network" 2>/dev/null) || old=""
case $SET in
  bridged) network_enable "$d" "$VM" "$INTERFACE" >&2 || exit $? ;;
  shared) network_disable "$d" || exit $? ;;
esac
new=$(cat "$d/bridged-network" 2>/dev/null) || new=""
[[ $old == "$new" ]] || CHANGED=true
network_read "$d" || usage "malformed bridged-network setting; choose shared to remove it"
helper=not-needed
if [[ $NETWORK_MODE == bridged ]]; then
  st=$("$R/src/net/mac/install.sh" --status --bridged-interface "$NETWORK_INTERFACE" 2>/dev/null) || st=missing
  helper=${st%%$'\n'*}
fi
this_start=$(sed -n '1p' "$d/logs/bridged-network" 2>/dev/null) || this_start=""
if (( JSON )); then
  printf '{"vm": %s, "type": "app", "network": "%s", "interface": %s, "mac": %s, "helper": %s, "next_start": "%s", "this_start": %s, "changed": %s, "restart_required": %s}\n' \
    "$(json_str "$VM")" "$NETWORK_MODE" "$(json_str "$NETWORK_INTERFACE")" "$(json_str "$NETWORK_MAC")" "$(json_str "$helper")" "$NETWORK_MODE" "$(json_str "$this_start")" "$CHANGED" "$CHANGED"
else
  echo "'$VM': $NETWORK_MODE${NETWORK_INTERFACE:+ on $NETWORK_INTERFACE} (from the VM's next start)"
  [[ -z $NETWORK_MAC ]] || echo "  LAN MAC: $NETWORK_MAC; helper: $helper; private Mac services: 10.0.2.2"
  [[ -z $this_start ]] || echo "  this start: $this_start"
  [[ -z $SET ]] || echo "Shut the VM down, then start it again to apply the setting; it was not restarted."
fi
