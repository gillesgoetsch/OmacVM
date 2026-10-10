#!/bin/bash
# omacvm notch: how an OmacVM.app VM uses the strip beside the notch.
#   omacvm notch --vm NAME                     the setting and what the next start does
#   omacvm notch --vm NAME fullpanel|native    change it (from the VM's next start)
#   --json   the setting as JSON (after a change: "changed": true)
#   --yes    never ask (the control centre's job)
# Native (the default): full screen below the camera housing; Omanotch streams
# Omarchy's bar into the strip. FullPanel (experimental): the VM's full screen
# also covers the strip on the MacBook's own display, and the VM draws its bar
# there, split around the notch; Omanotch is off for such a start and back at
# the next native one. Only in full screen ("Start in full screen" in the app),
# with a notch on this Mac, and once the VM is ready for it (Omanotch on, then
# omacvm apply or Update VM). External displays stay as they are.
# Exit codes: 0 done, 1 failed, 2 usage.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/notch.sh"
VM=""; TYPE=app; SET=""; JSON=0
usage() { echo "omacvm notch: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) [[ $# -ge 2 ]] || usage "--vm needs a name"; VM=$2; shift 2 ;;
    --vm-type) [[ $# -ge 2 ]] || usage "--vm-type needs a value"; TYPE=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --yes|-y) shift ;;
    -h|--help) sed -n '2,14s/^# \{0,1\}//p' "$0"; exit 0 ;;
    fullpanel|native) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
[[ $TYPE == app ]] || usage "the notch area is OmacVM.app's setting (UTM, VMware Fusion and Parallels keep their window below the notch: Omanotch fills the strip there)"
d=$(app_dir "$VM") || usage "no OmacVM.app VM named '$VM' (omacvm vms lists them)"

CHANGED=false; NOTE=""
if [[ -n $SET && $SET != "$(notch_choice "$d")" ]]; then
  notch_set "$d" "$SET" || die "could not write $d/$NOTCH_FILE"
  CHANGED=true
  NOTE="from the VM's next start"
fi

choice=$(notch_choice "$d")
mac=$(mac_tool mac-notch 2>/dev/null || echo none)
full=0; notch_app_full_screen && full=1
next=$(notch_next_start "$d" "$mac" "$full")
last=$(notch_this_start "$d")
ready=false; notch_guest_ready "$d" && ready=true
has=false; [[ $mac == notch ]] && has=true
fs=false; (( full )) && fs=true
if (( JSON )); then
  printf '{"vm": %s, "type": "app", "notch": "%s", "title": "%s", "next_start": %s, "this_start": %s, "mac_has_notch": %s, "full_screen": %s, "vm_ready": %s, "changed": %s%s}\n' \
    "$(json_str "$VM")" "$choice" "$(notch_title "$choice")" "$(json_str "$next")" "$(json_str "$last")" \
    "$has" "$fs" "$ready" "$CHANGED" "$([[ -n $NOTE ]] && printf ', "note": %s' "$(json_str "$NOTE")")"
else
  echo "'$VM': notch area $(notch_title "$choice")${NOTE:+ ($NOTE)}"
  echo "  next start: $next"
  [[ -z $last ]] || echo "  last start: $last"
  [[ -n $SET ]] || echo "Change with: omacvm notch --vm \"$VM\" fullpanel|native"
fi
