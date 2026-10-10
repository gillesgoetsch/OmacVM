#!/bin/bash
# omacvm fullscreen (or omacvm notch): an OmacVM.app VM's full screen and the notch.
#   omacvm fullscreen --vm NAME                  the setting and what the next start does
#   omacvm fullscreen --vm NAME notch|standard   change it (from the VM's next start)
#   omacvm notch --vm NAME fullpanel|native      the same (fullpanel = notch, native = standard)
#   --json   the setting as JSON (after a change: "changed": true)
#   --yes    never ask (the control centre's job)
# standard (the default; "Full screen, notch via Omanotch" in the app): full
# screen below the camera notch; Omanotch streams Omarchy's bar into the strip.
# notch ("Full screen including notch, no Omanotch needed", experimental): the
# VM uses the whole built-in display, including the strip beside the camera
# notch, and draws its bar there itself; Omanotch is off for such a start and
# back at the next standard one. Only when the app starts VMs in full screen
# (Start in, not Window), with a notch on this Mac, and once the VM is ready
# for it (Omanotch on, then omacvm apply or Update VM). External displays stay
# as they are. Exit codes: 0 done, 1 failed, 2 usage.
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
    -h|--help) sed -n '2,16s/^# \{0,1\}//p' "$0"; exit 0 ;;
    fullpanel|native) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    notch) [[ -z $SET ]] || usage "one setting"; SET=fullpanel; shift ;;
    standard) [[ -z $SET ]] || usage "one setting"; SET=native; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
[[ $TYPE == app ]] || usage "full screen including notch is OmacVM.app's setting (UTM, VMware Fusion and Parallels keep their window below the notch: Omanotch fills the strip there)"
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
  echo "'$VM': $(notch_title "$choice")${NOTE:+ ($NOTE)}"
  (( full )) || echo "  the app starts VMs in a window now (Start in: Window)"
  echo "  next start: $next"
  [[ -z $last ]] || echo "  last start: $last"
  [[ -n $SET ]] || echo "Change with: omacvm fullscreen --vm \"$VM\" notch|standard"
fi
