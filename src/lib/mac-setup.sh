# What an OmacVM VM needs from the Mac it runs on, and whether this Mac has
# it (sourced after mac.sh and features.sh; macOS's bash 3.2). One map of
# features to Mac helpers for omacvm apply (what it installs), omacvm check
# (its "Mac setup" line) and OmacVM.app (src/mac/install.sh --status: the
# message before a start and in the window).
#   mac_helper_of FEATURE   MAC_HELPER: the helper it needs ("": none)
#   mac_helpers_needed      MAC_NEEDED: "|NAME|NAME|", the helpers of the
#                           features on in FV (features_fix first)
#   mac_needs NAME          true when MAC_NEEDED has it
#   mac_token_hash FILE     a Bridge token's short hash (16 hex)
#   mac_setup_write DIR TOKEN_FILE
#                           DIR/mac-setup: the VM in DIR has that token
#   mac_setup_state DIR     MS_*: is this Mac set up for the OmacVM.app VM in DIR:
#                           MS_VERDICT ok, none (no helper needed), setup (MS_FIX
#                           update-vm, or update-app for a VM with a newer
#                           OmacVM; MS_WHY other-mac, not-installed,
#                           not-running, too-old), login-items, permission
#                           (MS_MISSING); MS_HELPERS the ones concerned
#                           ("|"-joined), MS_NEEDED, MS_LINES, MS_TEXT
#   mac_setup_print         MS_* as `src/mac/install.sh --status DIR` prints them
#
# A VM folder copied from another Mac runs without its helpers (only Update VM,
# a build or omacvm apply install them) and with the other Mac's token, and
# nothing said so (2026-10-20). DIR/mac-setup ("token <hash>", omacvm apply)
# says which Mac's token the VM has: a Mac moved with Migration Assistant
# keeps its token, so its VMs count as set up. A VM from before that record:
# its control centre key (vm-keys) is made per Mac, so none here means set up
# elsewhere (only when the control centre is on).
MAC_SETUP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAC_SETUP_FILE=mac-setup
# Seconds a helper may wait for its permissions before it counts as not
# allowed: right after its first start, macOS is asking.
MAC_SETUP_WAIT=${OMACVM_HELPER_WAIT:-60}

mac_helper_of() {   # FEATURE
  MAC_HELPER=""
  case $1 in
    bridge|control-centre) MAC_HELPER="OmacVM Bridge" ;;   # the control centre asks the Mac through it
    gestures|scroll-momentum) MAC_HELPER="OmacVM Gestures" ;;
    omanotch) MAC_HELPER=Omanotch ;;
  esac
  return 0
}

mac_helpers_needed() {
  local i
  MAC_NEEDED="|"
  for ((i = 0; i < ${#FN[@]}; i++)); do
    [[ ${FV[$i]:-} == on ]] || continue
    mac_helper_of "${FN[$i]}"
    if [[ -n $MAC_HELPER && $MAC_NEEDED != *"|$MAC_HELPER|"* ]]; then MAC_NEEDED+="$MAC_HELPER|"; fi
  done
  return 0
}

mac_needs() { [[ $MAC_NEEDED == *"|$1|"* ]]; }

mac_token_hash() {   # FILE: nothing and status 1 without a token
  local t
  [[ -r $1 ]] || return 1
  t=$(tr -d '[:space:]' < "$1") || return 1
  [[ -n $t ]] || return 1
  printf 'omacvm-bridge-token\n%s' "$t" | shasum -a 256 | cut -c1-16
}

mac_setup_write() {   # DIR TOKEN_FILE
  local h
  h=$(mac_token_hash "$2") || return 1
  printf 'token %s\n' "$h" > "$1/$MAC_SETUP_FILE.new" && mv -f "$1/$MAC_SETUP_FILE.new" "$1/$MAC_SETUP_FILE"
}

# mac_helper_state NAME: MH_STATE and MH_DETAIL for one helper on this Mac:
#   ok, waiting (for its permissions, under MAC_SETUP_WAIT s), starting
#   (launchd has it and starts it again), permission (MH_MISSING: the ones
#   off), missing (not installed), stopped (the test identity's: not
#   running), disabled (its LaunchAgent is there and launchd does not load
#   it: switched off in Login Items), old (Omanotch too old for app VMs).
# The Bridge and Gestures are found by their process, whichever job started
# them (helper_pid), and their permissions read only from what the running
# one logged (helper_log; one macOS started writes no log: no verdict).
mac_helper_state() {
  local key label plist bundle pid="" log="" l age rc=0 test=""
  MH_STATE=ok MH_DETAIL="" MH_MISSING=""
  [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && test="test"
  case $1 in
    "OmacVM Bridge") key=bridge bundle=OmacVMBridge.app ;;
    "OmacVM Gestures") key=gestures bundle=OmacVMGestures.app ;;
    Omanotch) key=omanotch bundle=Omanotch.app ;;
    *) MH_STATE=missing MH_DETAIL="unknown helper"; return 0 ;;
  esac
  if [[ $key == omanotch ]]; then
    pid=$(LC_ALL=C pgrep -a -o -u "$(id -u)" -f "Omanotch\.app/Contents/MacOS/omanotch") || pid=""
    omanotch_serves_app || rc=$?
    if (( rc == 1 )); then MH_STATE=old MH_DETAIL="too old for OmacVM.app's VMs"; return 0; fi
  else
    pid=$(helper_pid "$key" $test) || pid=""
  fi
  if [[ -n $pid ]]; then
    MH_DETAIL="running (pid $pid)"
    [[ $key == omanotch ]] && return 0
    log=$HOME/Library/Logs/omacvm-${test:+test-}$key.log
    l=$(helper_log "$pid" "$log" 2>/dev/null | grep -E "omacvm-$key: permissions: " | tail -1) || l=""
    l=${l#*permissions: }
    case $key in
      gestures) MH_MISSING=$(sed -E 's/[A-Za-z ]+ granted(, )?//g; s/ MISSING//g; s/[, ]+$//' <<<"$l") ;;
      bridge) [[ $l == *"Accessibility MISSING"* ]] && MH_MISSING=Accessibility ;;
    esac
    [[ $l == *MISSING* ]] || MH_MISSING=""
    if [[ -n $MH_MISSING ]]; then
      age=$(( $(date +%s) - $(proc_started "$pid" 2>/dev/null || date +%s) ))
      if (( age > MAC_SETUP_WAIT )); then MH_STATE=permission MH_DETAIL="running, but $MH_MISSING is off"
      else MH_STATE=waiting MH_DETAIL="running, macOS asks for $MH_MISSING"; fi
    fi
    return 0
  fi
  # The test identity's helpers are no LaunchAgents: Update VM (its
  # src/mac/install.sh) starts them.
  if [[ -n $test ]]; then MH_STATE=stopped MH_DETAIL="not running"; return 0; fi
  label=$(omacvm_label "$key")
  plist=$HOME/Library/LaunchAgents/$label.plist
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    MH_STATE=starting MH_DETAIL="not running now, launchd starts it"
  elif [[ ! -d $HOME/Applications/$bundle || ! -f $plist ]]; then
    MH_STATE=missing MH_DETAIL="not installed"
  else
    # Installed, and launchd does not load it: macOS's Login Items switch
    # (Allow in the Background) is off for it, or it was taken out by hand.
    # Update VM would not change that.
    MH_STATE=disabled MH_DETAIL="installed, but macOS does not start it (Login Items)"
  fi
  return 0
}

mac_setup_state() {   # DIR
  local d=$1 i v rec name have want other=0 vmv now h hs why="" setup="" disabled="" perm="" miss="" lines=""
  # Its own FV, TYPE and NOTCH: the caller's (omacvm check) stay as they are.
  local TYPE=app test="" FV NOTCH=${NOTCH:-}
  [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && test="test"
  MS_VERDICT=ok MS_FIX="" MS_WHY="" MS_HELPERS="" MS_NEEDED="" MS_MISSING="" MS_LINES="" MS_TEXT=""
  vmv=$(head -1 "$d/omacvm-version" 2>/dev/null | tr -d '[:space:]') || vmv=""
  now=$(head -1 "$MAC_SETUP_SRC/VERSION" 2>/dev/null | tr -d '[:space:]') || now=""
  MS_VMVERSION=$vmv MS_VERSION=$now
  # The VM's features: its record (the app reads it at each start), before
  # the first apply the setup's choice (vm.env FEATURES), else the defaults.
  rec=$(cat "$d/features" 2>/dev/null) || rec=""
  [[ -n $rec ]] || rec=$(app_env "$d" FEATURES 2>/dev/null) || rec=""
  rec=" $(printf '%s' "$rec" | tr '\n\t' '  ') "
  FV=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    v=${rec#* "${FN[$i]}="}
    if [[ $v == "$rec" ]]; then v=""; else v=${v%% *}; fi
    [[ $v == on || $v == off ]] || v=$(feature_default "$i")
    FV[$i]=$v
  done
  features_fix
  mac_helpers_needed
  # Omanotch: only for a start that links it (a notch now, not FullPanel), and
  # never for the test identity (no Omanotch of its own).
  if mac_needs Omanotch; then
    [[ -n ${NOTCH:-} ]] || NOTCH=$(mac_tool mac-notch 2>/dev/null || echo none)
    if [[ -n $test || $NOTCH != notch ]] ||
       [[ $(notch_next_start "$d" "$NOTCH" "$(notch_app_full_screen && echo 1 || echo 0)") == fullpanel ]]; then
      MAC_NEEDED=${MAC_NEEDED/|Omanotch|/|}
    fi
  fi
  MS_NEEDED=$(printf '%s' "${MAC_NEEDED#|}" | sed 's/|$//')
  [[ -n $MS_NEEDED ]] || { MS_VERDICT=none MS_TEXT="no Mac helpers needed (their features are off)"; return 0; }
  # This Mac's token in the VM (Gestures and the Bridge check it).
  if mac_needs "OmacVM Bridge" || mac_needs "OmacVM Gestures"; then
    have=$(mac_token_hash "$BRIDGE_TOKEN") || have=""
    want=$(sed -n 's/^token //p' "$d/$MAC_SETUP_FILE" 2>/dev/null | head -1) || want=""
    name=$(app_env "$d" NAME 2>/dev/null) || name=""
    [[ -n $name ]] || name=$(basename "$d")
    if [[ -n $want ]]; then
      [[ $want == "$have" ]] || other=1
    elif mac_needs "OmacVM Bridge" && [[ ${FV[$(feature_index control-centre)]} == on && ! -s $(vm_key_file app "$name") ]]; then
      other=1
    fi
  fi
  IFS='|' read -r -a hs <<<"$MS_NEEDED"
  for h in "${hs[@]}"; do
    mac_helper_state "$h"
    lines+="$h"$'\t'"$MH_STATE"$'\t'"$MH_DETAIL"$'\n'
    case $MH_STATE in
      missing|stopped|old)
        setup+="$h|"
        case $MH_STATE in missing) why=${why:-not-installed} ;; stopped) why=${why:-not-running} ;; old) why=${why:-too-old} ;; esac ;;
      disabled) disabled+="$h|" ;;
      permission)
        perm+="$h|"
        [[ $MH_MISSING == *Accessibility* && $miss != *Accessibility* ]] && miss+="Accessibility, "
        [[ $MH_MISSING == *"Input Monitoring"* && $miss != *"Input Monitoring"* ]] && miss+="Input Monitoring, " ;;
    esac
  done
  MS_LINES=${lines%$'\n'}
  if (( other )); then
    why="other-mac"
    # The helpers that use the token, when they are all there.
    [[ -n $setup ]] || for h in "OmacVM Gestures" "OmacVM Bridge"; do mac_needs "$h" && setup+="$h|"; done
  fi
  if [[ -n $setup ]]; then
    MS_VERDICT=setup MS_WHY=$why MS_HELPERS=${setup%|} MS_FIX=update-vm
    # Update VM stops before the Mac side for a VM with a newer OmacVM (#233):
    # OmacVM itself first.
    [[ -n $vmv && -n $now ]] && version_lt "$now" "$vmv" && MS_FIX=update-app
    case $why in
      other-mac) MS_TEXT="set up on another Mac: $(printf '%s' "$MS_HELPERS" | sed 's/|/, /g') not set up for this Mac" ;;
      not-installed) MS_TEXT="$(printf '%s' "$MS_HELPERS" | sed 's/|/, /g') not installed on this Mac" ;;
      not-running) MS_TEXT="$(printf '%s' "$MS_HELPERS" | sed 's/|/, /g') not running" ;;
      too-old) MS_TEXT="$(printf '%s' "$MS_HELPERS" | sed 's/|/, /g') too old for OmacVM.app's VMs" ;;
    esac
    [[ $MS_FIX == update-app ]] && MS_TEXT+=" (the VM has OmacVM $vmv, this is $now: update OmacVM first)"
  elif [[ -n $disabled ]]; then
    MS_VERDICT=login-items MS_FIX=login-items MS_HELPERS=${disabled%|}
    MS_TEXT="$(printf '%s' "$MS_HELPERS" | sed 's/|/, /g') installed, but macOS does not start it: switched off in System Settings > General > Login Items"
  elif [[ -n $perm ]]; then
    MS_VERDICT=permission MS_FIX=settings MS_HELPERS=${perm%|} MS_MISSING=${miss%, }
    MS_TEXT="$(printf '%s' "$MS_HELPERS" | sed 's/|/, /g'): $MS_MISSING not allowed (System Settings > Privacy & Security)"
  else
    MS_TEXT="set up for this Mac: $(printf '%s' "$MS_NEEDED" | sed 's/|/, /g')"
  fi
  return 0
}

mac_setup_print() {
  printf 'verdict\t%s\nfix\t%s\nwhy\t%s\nhelpers\t%s\nneeded\t%s\nmissing\t%s\nversion\t%s\nvm-version\t%s\ntext\t%s\n' \
    "$MS_VERDICT" "$MS_FIX" "$MS_WHY" "$MS_HELPERS" "$MS_NEEDED" "$MS_MISSING" "$MS_VERSION" "$MS_VMVERSION" "$MS_TEXT"
  [[ -z $MS_LINES ]] || printf '%s\n' "$MS_LINES" | sed 's/^/helper\t/'
}
