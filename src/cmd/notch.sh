#!/bin/bash
# omacvm fullscreen (or omacvm notch): an OmacVM.app VM's full screen and the notch.
#   omacvm fullscreen --vm NAME                  the setting and what the next start does
#   omacvm fullscreen --vm NAME notch|standard   change it (from the VM's next start)
#   omacvm notch --vm NAME fullpanel|native      the same (fullpanel = notch, native = standard)
#   omacvm notch --vm NAME --skip on|off         Skip the notch (off by default)
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
# as they are. Skip the notch: on the bar beside the notch (either full screen),
# items that do not fit on their side continue on its other side; at once in a
# running VM. Exit codes: 0 done, 1 failed, 2 usage.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/notch.sh"
VM=""; TYPE=app; SET=""; SKIP=""; JSON=0
usage() { echo "omacvm notch: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) [[ $# -ge 2 ]] || usage "--vm needs a name"; VM=$2; shift 2 ;;
    --vm-type) [[ $# -ge 2 ]] || usage "--vm-type needs a value"; TYPE=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --skip) [[ ${2:-} == on || ${2:-} == off ]] || usage "--skip needs on or off"; SKIP=$2; shift 2 ;;
    --yes|-y) shift ;;
    -h|--help) sed -n '2,19s/^# \{0,1\}//p' "$0"; exit 0 ;;
    fullpanel|native) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    notch) [[ -z $SET ]] || usage "one setting"; SET=fullpanel; shift ;;
    standard) [[ -z $SET ]] || usage "one setting"; SET=native; shift ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
[[ -n $VM ]] || usage "which VM? --vm NAME (omacvm vms lists them)"
# A retired VM (src/lib/retired.sh): exit 3 with what to do.
retired_check() {
  local t
  t=$(retired_list | awk -F'\t' -v n="$VM" -v t="$TYPE" '$1 == n && (t == "app" || $2 == t) { print $2; exit }')
  [[ -n $t ]] && retired_stop "$VM" "$t"
  return 0
}
route_retired "$TYPE" && retired_check
[[ $TYPE == app ]] || usage "--vm-type app (the only one)"
d=$(app_dir "$VM" 2>/dev/null) || { retired_check; usage "no OmacVM.app VM named '$VM' (omacvm vms lists them)"; }

CHANGED=false; NOTE=""
if [[ -n $SET && $SET != "$(notch_choice "$d")" ]]; then
  notch_set "$d" "$SET" || die "could not write $d/$NOTCH_FILE"
  CHANGED=true
  NOTE="from the VM's next start"
fi
if [[ -n $SKIP && $SKIP != "$(notch_skip "$d")" ]]; then
  notch_skip_set "$d" "$SKIP" || die "could not write $d/$NOTCH_SKIP_FILE"
  CHANGED=true
fi

choice=$(notch_choice "$d")
mac=$(notch_mac_state)
full=0; notch_app_full_screen && full=1
next=$(notch_next_start "$d" "$mac" "$full")
last=$(notch_this_start "$d")
ready=false; notch_guest_ready "$d" && ready=true
has=false; [[ $mac == notch ]] && has=true
fs=false; (( full )) && fs=true
skip=$(notch_skip "$d")
skip_ready=false; notch_skip_ready "$d" && skip_ready=true
if (( JSON )); then
  printf '{"vm": %s, "type": "app", "notch": "%s", "title": "%s", "next_start": %s, "this_start": %s, "mac_has_notch": %s, "full_screen": %s, "vm_ready": %s, "skip": "%s", "skip_ready": %s, "changed": %s%s}\n' \
    "$(json_str "$VM")" "$choice" "$(notch_title "$choice")" "$(json_str "$next")" "$(json_str "$last")" \
    "$has" "$fs" "$ready" "$skip" "$skip_ready" "$CHANGED" "$([[ -n $NOTE ]] && printf ', "note": %s' "$(json_str "$NOTE")")"
else
  echo "'$VM': $(notch_title "$choice")${NOTE:+ ($NOTE)}"
  (( full )) || echo "  the app starts VMs in a window now (Start in: Window)"
  echo "  next start: $next"
  [[ -z $last ]] || echo "  last start: $last"
  echo "  skip the notch: $skip$([[ $skip_ready == true ]] || echo " (the VM needs an update first: Update VM or omacvm apply)")"
  [[ -n $SET$SKIP ]] || echo "Change with: omacvm fullscreen --vm \"$VM\" notch|standard (or --skip on|off)"
fi
