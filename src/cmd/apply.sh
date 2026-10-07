#!/bin/bash
# omacvm apply: put OmacVM onto a running VM (Parallels, UTM or VMware Fusion), or bring it up
# to this version: the Mac side the VM's features need, then the VM side. Also
# for an Omarchy you installed by hand from omarchy-mac.
#   omacvm apply [--vm NAME | --ip IP] [--vm-type parallels|utm|fusion|app] [--user NAME]
#                [--feature NAME=on|off]... [--FEATURE | --no-FEATURE]...
#                [--keyboard "LAYOUT [VARIANT]"] [--display WxH@Hz] [--key PRIVATE_KEY] [--no-mac]
#                [--reset-host-key] [--reinstall FEATURE]... [--transaction] [--yes]
# Features: `omacvm features` lists them (src/features.tsv). Not given: what the
# VM has (new to OmacVM: the defaults; a VM from before the control centre is
# asked once whether it gets it, yes with --yes or without a terminal).
# --no-mac leaves the Mac side alone.
# --reinstall FEATURE: repairs that feature only (its Mac helper is built
# again, its VM part installed again); the features stay as they are. A VM
# with another OmacVM version than this Mac gets all of this one (with that
# feature installed again).
# --transaction (the control centre's jobs): the new OmacVM goes into the VM
# beside the old one; if the VM side fails, the old one and the VM's earlier
# features come back and the run ends with exit code 4. A part that would
# only be logged otherwise fails the run too when it belongs to the job: the
# features switched or repaired, or for an update the parts it changes (by
# /etc/omacvm/installed.json); other parts keep being only logged.
# VM: the one named Omarchy, else the only running one. A stopped VM is
# started. User: the VM's desktop user. Key: ~/.ssh/omacvm. Keyboard: the
# Mac's current layout. Display (UTM, Fusion): the Mac's built-in display below
# the notch (no built-in display: the main one). The VM's SSH host key is
# remembered the first time; --reset-host-key forgets it (a rebuilt VM).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person (see the message),
# 4 failed and rolled back (--transaction).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/graphics.sh"
features_load
VM=""; IP=""; TYPE=""; U=""; KEY=~/.ssh/omacvm; KB=""; MODE=""; MAC=1; NAMED=1; TOKEN=1; TOOLS=1; TRANSACTION=0
YES=0; NEWKEY=0; REINSTALL=()
SETN=(); SETV=()
set_feature() {   # NAME on|off (an old name too: idle-lock=off is no-idle-lock=on)
  local n v
  [[ $2 == on || $2 == off ]] || { echo "omacvm apply: --feature $1=$2: on or off" >&2; exit 2; }
  read -r n v <<<"$(feature_alias "$1" "$2")"
  feature_index "$n" >/dev/null || { echo "omacvm apply: unknown feature '$1' (omacvm features lists them)" >&2; exit 2; }
  SETN+=("$n"); SETV+=("$v")
}
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --keyboard) KB=$2; shift 2 ;;
    --display) MODE=$2; shift 2 ;;
    --no-mac) MAC=0; shift ;;
    --reset-host-key) export OMA_PIN_RESET=1; NEWKEY=1; shift ;;
    --transaction) TRANSACTION=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --reinstall) f=$(feature_alias "${2:-}"); f=${f%% *}
                 feature_index "$f" >/dev/null || { echo "omacvm apply: --reinstall: unknown feature '${2:-}' (omacvm features lists them)" >&2; exit 2; }
                 REINSTALL+=("$f"); shift 2 ;;
    --no-token) TOKEN=0; shift ;;   # prebuilt images: no Bridge token in the VM
    --no-tools) TOOLS=0; shift ;;   # prebuilt images: no Parallels Tools
    --feature) set_feature "${2%%=*}" "${2#*=}"; shift 2 ;;
    --no-*) set_feature "${1#--no-}" off; shift ;;
    -h|--help) sed -n '2,26s/^# \{0,1\}//p' "$0"; exit 0 ;;
    --*) f=$(feature_alias "${1#--}"); feature_index "${f%% *}" >/dev/null || { echo "omacvm apply: unknown option $1 (see --help)" >&2; exit 2; }
         set_feature "${1#--}" on; shift ;;
    *) echo "omacvm apply: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
# Steps for the control centre's progress (step, lib/mac.sh).
(( OMA_STEPS )) || OMA_STEPS=$(( MAC ? 4 : 3 ))
macos=$(sw_vers -productVersion 2>/dev/null)
(( ${macos%%.*} >= 14 )) || { echo "omacvm apply: OmacVM needs macOS 14 (Sonoma) or newer; this Mac runs $macos" >&2; exit 3; }
export OMA_KEY=$KEY
[[ -f $KEY ]] || { log "SSH key for the VM: $KEY"; mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"; ssh-keygen -t ed25519 -N "" -C omacvm -f "$KEY" -q; }
NOTCH=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)

# ---------- which VM ----------
# Its SSH host key: remembered now when there is none yet, checked after that.
export OMA_PIN_NEW=1
if [[ -n $IP ]]; then
  [[ -n $TYPE ]] || TYPE=$(vm_type "${VM:-Omarchy}") || { echo "omacvm apply: with --ip, pass --vm-type parallels, utm, fusion or app" >&2; exit 2; }
  if [[ -n $VM ]]; then vm_pin "$VM" "$TYPE"
  else VM="the VM at $IP"; NAMED=0; OMA_PIN=""; OMA_PIN_ARGS="--ip $IP --vm-type $TYPE"; export OMA_PIN OMA_PIN_ARGS; fi   # an address is no identity (DHCP reuses it): no key kept
else
  resolve_vm start
fi
case $TYPE in parallels|utm|fusion|app) ;; *) echo "omacvm apply: --vm-type parallels, utm, fusion or app" >&2; exit 2 ;; esac
vm_network_ok "$TYPE" "$IP" || exit 3
ssh_ok=0; (wait_ssh "$IP" 120) >/dev/null 2>&1 || ssh_ok=$?
(( ssh_ok != 3 )) || { hostkey_error; exit 3; }
if (( ssh_ok )); then
  printf '\033[1;31merror:\033[0m no SSH access to %s (%s).\n' "$VM" "$IP" >&2
  printf 'If OmacVM did not build this VM, open a terminal in it and run this once (it lets\nOmacVM in with its own key, from the Mac only), then run omacvm apply again:\n\n  %s\n\n' "$(ssh_setup_command "$TYPE")" >&2
  exit 3
fi
[[ $TYPE == utm || $TYPE == fusion ]] && [[ -z $MODE ]] && MODE=$(swift "$R/src/display/mac-display.swift")
[[ -z $MODE || $MODE =~ ^[0-9]+x[0-9]+(@[0-9.]+)?$ ]] || die "--display WxH@Hz, not '$MODE'"
# OmacVM.app's VMs keep the layout chosen at setup (vm.env KEYBOARD, as the
# app's own apply-vm.sh passes it): a switch from the control centre or the
# command must not change it to the Mac's. Other VMs follow the Mac.
if [[ -z $KB && $TYPE == app ]] && (( NAMED )) && d=$(app_dir "$VM" 2>/dev/null); then
  KB=$(app_env "$d" KEYBOARD)
fi
[[ -n $KB ]] || KB=$("$R/src/keyboard/mac-layout.sh")
probe=$(vm_probe "$IP")
[[ -n $U ]] || U=$(sed -n 's/^OMACVM_USER=//p' <<<"$probe")
[[ -n $U ]] || die "no desktop user in '$VM' (pass --user NAME)"
had=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")
now=$(cat "$R/src/VERSION")

# ---------- the features it gets ----------
features_read_env "$probe"
PREV=("${FV[@]}")   # what the VM has now: --transaction goes back to it
# New to OmacVM (or a prebuilt VM before its first apply): the defaults,
# Omanotch with a notch.
if [[ -z $had ]] || grep -q '^OMACVM_PREBUILT_FRESH=1' <<<"$probe"; then
  for ((i = 0; i < ${#FN[@]}; i++)); do FV[$i]=$(feature_default "$i"); done
fi
# OmacVM.app: the VM's record (its features file) over the VM's copy.
rd=""
if [[ $TYPE == app ]] && (( NAMED )) && rd=$(app_dir "$VM"); then
  [[ -z $had ]] || features_read_record "$rd"
fi
# What was switched outside OmacVM keeps its real state: the fast network
# (the app's button writes the fast-network file) and autologin (SDDM, also an
# Omarchy install's own file). An apply without --feature for them keeps it.
features_real "$probe" "$rd"
if [[ -n $had ]]; then
  while IFS= read -r l; do [[ -z $l ]] || info "$l"; done < <(features_drift_lines "kept, the record follows")
  # What the VM has now is the real state: a rollback goes back to it, not
  # to the record's mistake (it would set an autologin file aside).
  for x in ${DRIFT[@]+"${DRIFT[@]}"}; do
    IFS=$'\t' read -r n v _ <<<"$x"; PREV[$(feature_index "$n")]=$v
  done
fi
# A VM from before the control centre: one question (yes without a terminal).
cc=$(feature_index control-centre)
if [[ -n $had ]] && ! grep -q '^OMACVM_FEATURE_control_centre=' <<<"$probe" && [[ " ${SETN[*]:-} " != *" control-centre "* ]]; then
  FV[$cc]=on
  if (( ! YES )) && { : < /dev/tty; } 2>/dev/null; then
    source "$R/src/lib/setup.sh"
    ask_yn "Add the OmacVM control centre to '$VM' (omacvm in Omarchy: features, updates, report a problem)?" y || FV[$cc]=off
  fi
fi
for ((k = 0; k < ${#SETN[@]}; k++)); do FV[$(feature_index "${SETN[$k]}")]=${SETV[$k]}; done
before=("${FV[@]}"); features_fix
for ((i = 0; i < ${#FN[@]}; i++)); do
  [[ ${before[$i]} != "${FV[$i]}" ]] && info "${FTITLE[$i]}: off (it needs ${FNEEDS[$i]})"
done
# Parallels shows the Mac's battery itself.
[[ $TYPE == parallels ]] && FV[$(feature_index battery)]=off
on() { [[ ${FV[$(feature_index "$1")]} == on ]]; }
for f in ${REINSTALL[@]+"${REINSTALL[@]}"}; do
  on "$f" || { echo "omacvm apply: --reinstall $f: it is off in '$VM' (omacvm enable $f)" >&2; exit 2; }
done
# UTM and Fusion get the Mac's battery and camera from OmacVM Bridge, also with
# its bar features off (OmacVM.app passes them itself).
battery_via_bridge() { on battery && [[ $TYPE == utm || $TYPE == fusion ]]; }
camera_via_bridge() { on camera && [[ $TYPE == utm || $TYPE == fusion ]]; }
# The control centre asks the Mac through the Bridge (also with its bar features off).
needs_bridge() { on bridge || battery_via_bridge || camera_via_bridge || on control-centre; }
log "$TYPE VM '$VM' at $IP, user $U${had:+, OmacVM $had}"
info "features: $(for ((i = 0; i < ${#FN[@]}; i++)); do printf '%s=%s ' "${FN[$i]}" "${FV[$i]}"; done)"

# ---------- the Mac side ----------
# helper_of FEATURE: the Mac helper it needs built (empty: none).
helper_of() {
  case $1 in
    bridge|control-centre) echo "OmacVM Bridge" ;;   # the control centre asks the Mac through it
    camera|battery) [[ $TYPE == utm || $TYPE == fusion ]] && echo "OmacVM Bridge" ;;
    gestures|scroll-momentum) echo "OmacVM Gestures" ;;
    omanotch) echo Omanotch ;;
  esac
  return 0
}
if (( MAC )); then
  step mac "the Mac side"
  # OmacVM.app's apply (apply-vm.sh, or the app's omacvm the Bridge runs):
  # the Bridge runs the app's own omacvm for the control centre (cli_file_app).
  [[ -n ${OMACVM_APP_CLI:-} ]] && cli_file_app "$OMACVM_APP_CLI"
  args=(--quiet)
  # A repair builds that feature's Mac helper again (the others stay as they are).
  for f in ${REINSTALL[@]+"${REINSTALL[@]}"}; do
    h=$(helper_of "$f"); [[ -n $h ]] && args+=(--force-app "$h")
  done
  # What this run needs from the Mac: the helpers of the features it turns on
  # or repairs. A helper that failed to build with these sources before is
  # not built again for anything else (the control centre's jobs), so a
  # switch that does not need it never stops on it.
  NEED=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    [[ ${FV[$i]} == on && ( ${PREV[$i]} != on || -z $had || " ${REINSTALL[*]:-} " == *" ${FN[$i]} "* ) ]] || continue
    h=$(helper_of "${FN[$i]}"); [[ -n $h && " ${NEED[*]:-} " != *" $h "* ]] && NEED+=("$h")
  done
  if (( TRANSACTION )); then
    args+=(--skip-failed)
    for h in ${NEED[@]+"${NEED[@]}"}; do args+=(--retry-app "$h"); done
  fi
  needs_bridge || args+=(--no-bridge)
  on gestures || args+=(--skip-gestures)
  [[ $TYPE == parallels ]] || args+=(--skip-clip)   # the VM -> Mac clipboard of Parallels' shared folder
  # Omanotch from src/omanotch. OmacVM.app too, as for the other routes: its
  # full screen sits below the camera and Omanotch fills the strip.
  on omanotch && args+=(--omanotch)
  MAC_FAILED=$(mktemp -t omacvm-mac)
  mrc=0; OMACVM_MAC_FAILED_FILE=$MAC_FAILED "$R/src/mac/install.sh" "${args[@]}" || mrc=$?
  if (( mrc == 5 )); then
    # Which helpers did not build: one this run needs stops it (the VM is not
    # changed); the others keep their last build, and the VM side goes on.
    stop=""; others=()
    while IFS= read -r h; do
      [[ -n $h ]] || continue
      if [[ " ${NEED[*]:-} " == *" $h "* ]]; then stop=${stop:-$h}; else others+=("$h"); fi
    done < "$MAC_FAILED"
    rm -f "$MAC_FAILED"
    if [[ -n $stop ]]; then
      failed_part "$(mac_helper_feature "$stop")" "$stop did not build on the Mac" mac
      die "$stop did not build on the Mac (see above); the VM was not changed. On the Mac, omacvm update tries it again"
    fi
    (( ${#others[@]} )) && info "not built on the Mac: $(printf '%s, ' "${others[@]}" | sed 's/, $//') (after a failed build the one installed before keeps running; omacvm update tries again). The VM side goes on."
  elif (( mrc )); then
    rm -f "$MAC_FAILED"
    failed_part "" "the Mac side did not install" mac
    die "the Mac side did not install (see above); the VM was not changed"
  fi
  rm -f "$MAC_FAILED"
  # OmacVM.app's fast network: a system service (macOS asks for the password once).
  if [[ $TYPE == app ]] && on fast-network; then
    rc=0; "$R/src/net/mac/install.sh" || rc=$?
    (( rc == 0 )) || { echo "omacvm apply: the fast network did not install (omacvm disable fast-network keeps QEMU's own network)" >&2; exit "$rc"; }
  fi
  # Chrome in the guest gets no GPU with UTM's "Apple Core OpenGL" renderer.
  if [[ $TYPE == utm ]]; then
    case $(utm_data defaults read com.utmapp.UTM QEMURendererBackend 2>/dev/null || echo 0) in
      0|2) ;;
      *) defaults write com.utmapp.UTM QEMURendererBackend -int 0
         log "UTM renderer set to Default: quit UTM and start the VM again for the GPU in Chrome" ;;
    esac
  fi
fi

# An Omanotch from before OmacVM.app listens only on the other routes' networks.
if on omanotch && [[ $TYPE == app ]]; then
  rc=0; omanotch_serves_app || rc=$?
  (( rc != 1 )) || info "Omanotch on this Mac is too old for OmacVM.app's VMs (it does not serve 127.0.0.1): the strip beside the notch stays empty until it is updated (omacvm update)"
fi

# ---------- the VM side ----------
# Parallels Tools: a prebuilt VM comes without them (they are Parallels' own).
if (( TOOLS )) && [[ $TYPE == parallels ]] && ! gssh "$IP" "systemctl cat prltoolsd >/dev/null 2>&1" < /dev/null; then
  log "Parallels Tools (from this Mac's Parallels Desktop)"
  parallels_tools_install "$IP"
fi
T=$BRIDGE_TOKEN
# A Bridge installed a moment ago writes its token when it first starts.
if (( MAC )) && needs_bridge; then for _ in $(seq 20); do [[ -f $T ]] && break; sleep 1; done; fi
# External display brightness: a switch in the Bridge's config, which it takes
# within seconds. One Bridge serves every VM: the last apply sets it.
if (( MAC )) && needs_bridge; then
  c="$(dirname "$T")/config.json"
  want=$(on external-brightness && echo true || echo false)
  if [[ -f $c ]]; then
    [[ $(plutil -extract external_brightness raw -o - "$c" 2>/dev/null) == "$want" ]] ||
      plutil -replace external_brightness -bool "$want" "$c"
  elif [[ $want == false ]]; then
    mkdir -p "$(dirname "$c")" && echo '{"external_brightness": false}' > "$c"   # the Bridge adds the rest
  fi
fi
# The gestures daemon says it too (OmacVM.app's VMs show it on 127.0.0.1 even
# without the Bridge).
if (( TOKEN )) && on gestures; then bridge_token_ensure; fi
if (( ! TOKEN )); then
  :
elif [[ -f $T ]]; then
  log "bridge token -> $IP"
  gssh "$IP" "set -e; H=\$(getent passwd '$U' | cut -d: -f6)
    install -d -m700 -o '$U' -g '$U' \"\$H/.config/omacvm-bridge\"
    install -m600 -o '$U' -g '$U' /dev/stdin \"\$H/.config/omacvm-bridge/token\"" < "$T"
elif needs_bridge; then
  die "no bridge token yet: the Mac side did not install (run omacvm apply without --no-mac)"
fi
# The VM's own key for the control centre (vm_key_ensure in lib/mac.sh).
if (( TOKEN && NAMED )) && on control-centre; then
  vk=$(vm_key_ensure "$TYPE" "$VM" "$( (( NEWKEY )) && echo new)")
  gssh "$IP" "set -e; H=\$(getent passwd '$U' | cut -d: -f6)
    install -d -m700 -o '$U' -g '$U' \"\$H/.config/omacvm-bridge\"
    install -m600 -o '$U' -g '$U' /dev/stdin \"\$H/.config/omacvm-bridge/vm-key\"" < "$vk"
fi
# Touch ID (ADR 0041): its own key, root's alone in the VM (PAM asks as
# root), and for Parallels/UTM/Fusion the Bridge token (they reach the Bridge
# over the network). OmacVM.app's VMs ask through the app's port: no Bridge
# token in them. Off: the Mac's copy goes (the VM's goes in guest/install.sh).
if (( TOKEN && NAMED )) && on touch-id; then
  tk=$(touchid_key_ensure "$TYPE" "$VM" "$( (( NEWKEY )) && echo new)")
  gssh "$IP" "set -e; install -d -m755 /etc/omacvm; install -m600 -o root -g root /dev/stdin /etc/omacvm/touchid-key" < "$tk"
  if [[ $TYPE == app ]]; then gssh "$IP" "rm -f /etc/omacvm/touchid-token" < /dev/null
  else gssh "$IP" "set -e; install -m600 -o root -g root /dev/stdin /etc/omacvm/touchid-token" < "$T"; fi
else
  # The key, and the theme the VM sent for the Bridge's Touch ID panel.
  if (( NAMED )); then
    rm -f "$(vm_key_file "$TYPE" "$VM").touchid" "$OMA_BRIDGE_SUPPORT/touchid-theme/$(basename "$(vm_key_file "$TYPE" "$VM")").json"
  fi
  # On without a key: the VM's PAM line gets 403 and the password comes.
  if on touch-id; then log "Touch ID: not set up (it needs the VM by name and the Bridge token: not --ip, not --no-token)"; fi
fi
step copy "OmacVM into the VM"
log "OmacVM -> $IP:/usr/local/share/omacvm"
# Unpacked beside the one there; swapped in only once it is all there. The
# old one stays as omacvm.old until the VM side is done (--transaction goes
# back to it).
S=/usr/local/share/omacvm
COPYFILE_DISABLE=1 tar --no-xattrs -C "$R/src" --exclude build --exclude __pycache__ -czf - . |
  gssh "$IP" "set -e; rm -rf $S.new $S.old; mkdir -p $S.new
              tar --no-same-owner -C $S.new -xzf - 2>/dev/null
              if [ -d $S ]; then mv $S $S.old; fi; mv $S.new $S" ||
  die "OmacVM did not get into the VM (see above): nothing changed there"
# guest_install VALUE...: guest/install.sh with these features (one on|off per
# FN), and GI_ARGS. KNOWN: the feature names the VM's copy knows (a copy of an
# older OmacVM, when going back), all when empty.
GI_ARGS=""; KNOWN=""
guest_install() {
  local fargs="" i v=("$@")
  for ((i = 0; i < ${#FN[@]}; i++)); do
    if [[ -n $KNOWN && $'\n'$KNOWN$'\n' != *$'\n'${FN[$i]}$'\n'* ]]; then
      # A copy from before 3.0.1 knows no-idle-lock by its old name.
      [[ ${FN[$i]} == no-idle-lock && $'\n'$KNOWN$'\n' == *$'\n'idle-lock$'\n'* ]] &&
        fargs+=" --feature idle-lock=$(feature_flip "${v[$i]}")"
      continue
    fi
    fargs+=" --feature ${FN[$i]}=${v[$i]}"
  done
  [[ $TYPE == fusion ]] && fargs+=" --host $(fusion_host)"
  [[ ${v[$(feature_index mac-clock)]} == on ]] && fargs+=" --clock-format-b64 $(swift "$R/src/clock/mac-clock.swift" | base64)"
  # Its name, so the Mac's gestures helper tells it from another VM in the same app.
  (( NAMED )) && fargs+=" --vm-name-b64 $(printf %s "$VM" | base64 | tr -d '\n')"
  gssh "$IP" "/usr/local/share/omacvm/guest/install.sh --user '$U' --keyboard '$KB' --vm-type $TYPE ${MODE:+--display $MODE}$fargs$GI_ARGS" < /dev/null
}
step vm "the VM side"
# OmacVM.app: what the VM's Graphics setting gives it on this Mac; with
# Vulkan the VM builds its Venus driver now (a copy of an older OmacVM,
# when going back, does not know the option).
GRAPHICS=""
if [[ $TYPE == app ]] && (( NAMED )) && gd=$(app_dir "$VM" 2>/dev/null); then
  GRAPHICS=$(graphics_wants "$gd")
  GI_ARGS+=" --graphics $GRAPHICS"
fi
# A repair installs only those features' parts again (all of OmacVM when the
# VM has another version: its other parts would not match the new copy).
ONLY=""
if (( ${#REINSTALL[@]} )); then
  if [[ -n $had && $had != "$now" ]]; then
    info "'$VM' has OmacVM $had: all of OmacVM $now goes in, $(IFS=,; echo "${REINSTALL[*]}") installed again"
  else
    ONLY=$(IFS=,; echo "${REINSTALL[*]}"); GI_ARGS+=" --only $ONLY"
  fi
# A feature switch (--feature that changes what the VM has) on a VM with
# this OmacVM: only the parts of the features that change (and parts this
# copy changed), not the whole VM side, which reloads Hyprland and its
# displays (lib/features.sh, feature_switch_parts). The same features again
# (apply-vm.sh passes them all) is a whole apply, as before; so is a switch
# while the VM's Graphics changed (the app step builds its Vulkan driver).
elif (( ${#SETN[@]} )) && [[ -n $had && $had == "$now" ]] && ! grep -q '^OMACVM_PREBUILT_FRESH=1' <<<"$probe" &&
     [[ $(sed -n 's/^OMACVM_GRAPHICS=//p' <<<"$probe" | tail -1) == "$GRAPHICS" ]]; then
  sw=""; switched=0
  for ((i = 0; i < ${#FN[@]}; i++)); do
    [[ ${FV[$i]} != "${PREV[$i]}" ]] || continue
    sw+=" ${FN[$i]}"
    [[ " ${SETN[*]} " == *" ${FN[$i]} "* ]] && switched=1
  done
  if (( switched )); then
    inst=$(gssh "$IP" "cat /etc/omacvm/installed.json 2>/dev/null" < /dev/null) || inst=""
    if ONLY=$(feature_switch_parts "$inst" "$("$R/src/release/manifest.py" digests --src "$R/src")" "$sw" "${FN[*]}"); then
      GI_ARGS+=" --only $ONLY"
    else
      ONLY=""
    fi
  fi
fi
# changed_features: the features whose part the VM has another digest of (its
# /etc/omacvm/installed.json); none when it does not say.
changed_features() {
  local inst
  inst=$(gssh "$IP" "cat /etc/omacvm/installed.json 2>/dev/null" < /dev/null) || inst=""
  [[ -n $inst ]] || return 0
  "$R/src/release/manifest.py" digests --src "$R/src" | python3 -c '
import json, sys
new = json.load(sys.stdin)["parts"]
try:
    old = json.loads(sys.argv[1]).get("parts") or {}
except ValueError:
    sys.exit(0)
feats = set(sys.argv[2].split())
print(",".join(sorted(k for k, v in new.items() if k in feats and (old.get(k) or {}).get("digest") != v["digest"])))
' "$inst" "${FN[*]}"
}
# A job fails also when a part that belongs to it was only logged as not set
# up: what it switches or repairs; for an update, the parts it changes. Parts
# that only failed quietly before keep doing so (an update never gets stuck
# on a part it does not touch).
if (( TRANSACTION )); then
  if (( ${#REINSTALL[@]} )); then strict=$(IFS=,; echo "${REINSTALL[*]}")
  elif (( ${#SETN[@]} )); then strict=$(IFS=,; echo "${SETN[*]}")
  else strict=$(changed_features) || strict=""; fi
  [[ -z $strict ]] || GI_ARGS+=" --strict $strict"
fi
# What the guest said, to name what failed.
GI_LOG=$(mktemp -t omacvm-apply); trap 'rm -f "$GI_LOG"' EXIT
what_failed() {
  local l part=""
  l=$(sed "s/"$'\033'"\[[0-9;]*m//g" "$GI_LOG" | grep -E '^guest/install\.sh: ' | tail -1) || l=""
  if [[ $l =~ ^guest/install\.sh:\ ([a-z][a-z0-9-]*)\ was\ not\ set\ up ]] && feature_index "${BASH_REMATCH[1]}" >/dev/null; then
    part=${BASH_REMATCH[1]}
    failed_part "$part" "${FTITLE[$(feature_index "$part")]} was not set up"
  elif [[ $l =~ ^guest/install\.sh:\ failed\ during:\ (.*)$ ]]; then
    failed_part "" "the VM side stopped at: ${BASH_REMATCH[1]}"
  else
    l=$(sed "s/"$'\033'"\[[0-9;]*m//g" "$GI_LOG" | grep -v '^[[:space:]]*$' | tail -1) || l=""
    failed_part "" "${l:-the VM side failed}"
  fi
}
if ! guest_install "${FV[@]}" 2>&1 | tee "$GI_LOG"; then
  what_failed
  if (( TRANSACTION )) && [[ -n $had ]] && gssh "$IP" "test -d $S.old" < /dev/null; then
    step rollback "back to what '$VM' had"
    log "the VM side failed: back to the OmacVM and the features '$VM' had"
    gssh "$IP" "set -e; rm -rf $S.failed; mv $S $S.failed; mv $S.old $S; rm -rf $S.failed" < /dev/null ||
      die "the VM side failed, and going back failed too: run omacvm apply --vm \"$VM\" again"
    KNOWN=$(gssh "$IP" "grep -v '^#' $S/features.tsv | cut -f1" < /dev/null) || KNOWN=""
    # A repair of the same version changed only those parts: only they go back.
    GI_ARGS=""; [[ -n $ONLY ]] && GI_ARGS=" --only $ONLY"
    guest_install "${PREV[@]}" || die "the VM side failed, and going back failed too: run omacvm apply --vm \"$VM\" again"
    if [[ $had != "$now" ]]; then
      echo "omacvm apply: rolled back: '$VM' has OmacVM $had and its features again; this Mac keeps OmacVM $now. To go on: turn off or repair what failed, or omacvm apply --vm \"$VM\" again" >&2
    else
      echo "omacvm apply: rolled back: '$VM' has its features from before again (what failed is above)" >&2
    fi
    exit 4
  fi
  gssh "$IP" "rm -rf $S.old" < /dev/null || true
  die "the VM side failed (see above)"
fi
gssh "$IP" "rm -rf $S.old" < /dev/null || true
step finish "finishing"
# What it has now, per part (src/release/parts.tsv): the control centre
# compares it with an update's manifest.
# A part the last verified manifest has unchanged keeps its own release.
"$R/src/release/manifest.py" digests --src "$R/src" --manifest "$OMA_SUPPORT/updates.json" 2>/dev/null |
  gssh "$IP" "install -Dm644 /dev/stdin /etc/omacvm/installed.json" || info "installed.json not written (the update list may show every part)"
# OmacVM.app: this VM now draws Omarchy's own pointer. The app hides the Mac's
# over the window only for a VM with this file; VMs set up by older versions
# hid Omarchy's pointer and need the Mac's until they get this apply.
if [[ $TYPE == app ]] && (( NAMED )) && d=$(app_dir "$VM"); then
  echo omarchy > "$d/guest-pointer"
  # Which OmacVM the VM has now: the app offers "Update VM" while it has
  # an older one (or none recorded: made by an app before 3.0.1).
  echo "$now" > "$d/omacvm-version"
  # The app reads them at each start of the VM: a feature that is off gets
  # no port to the Mac's helpers and nothing on its virtio port (MacLinks.swift).
  # Vulkan without OmacVM's Mesa in the VM is off, in the record too: else it
  # says on, and `omacvm enable vulkan` finds nothing to change. Without it
  # the distro's venus (Mesa 26.2.3) gets the device, and every Vulkan app
  # fails with ERROR_OUT_OF_HOST_MEMORY.
  # (Only when the VM says it is missing: a failed SSH call changes nothing.)
  vk=0; on vulkan && { gssh "$IP" "test -f /etc/vulkan/icd.d/omacvm_venus_icd.json" < /dev/null 2>/dev/null || vk=$?; }
  if (( vk == 1 )); then
    info "Vulkan: not turned on, OmacVM's Mesa did not build in the VM (see above; the VM keeps OpenGL)"
    FV[$(feature_index vulkan)]=off
    gssh "$IP" "f=/etc/omacvm/env; [ ! -f \$f ] || sed -i 's/^OMACVM_FEATURE_vulkan=.*/OMACVM_FEATURE_vulkan=off/' \$f" < /dev/null 2>/dev/null || true
  fi
  feats=$(for ((i = 0; i < ${#FN[@]}; i++)); do printf '%s=%s ' "${FN[$i]}" "${FV[$i]}"; done)
  # The app reads them only when the VM starts: say which ones wait for that.
  app_features_write "$d" "${feats% }" || true   # 1 = unchanged (set -e)
  if app_running_dir "$d"; then
    l=$(app_links_stale "$d" "${feats% }" on)
    [[ -z $l ]] || info "OmacVM.app: $l only from the VM's next start: shut it down and start it again"
    l=$(app_links_stale "$d" "${feats% }" off)
    [[ -z $l ]] || info "OmacVM.app: $l off in the VM now; the Mac stops serving it at the VM's next start"
  fi
  # The fast network from the VM's next start: its own MAC address (the VMs
  # share vmnet's network), kept in fast-network, which the app reads.
  if on fast-network; then
    [[ -s $d/fast-network ]] ||
      printf 'mac=52:54:00:%02x:%02x:%02x\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) > "$d/fast-network"
    [[ $(app_net "$d") == vmnet ]] || info "fast network: from the VM's next start (shut it down, then start it again)"
  elif [[ -e $d/fast-network ]]; then
    rm -f "$d/fast-network"
    # The root service only while one of this user's app VMs has the fast
    # network; without it a VM still running on it switches to the user
    # network within seconds, else at its next start.
    if (( MAC )) && ! app_any_fast_network; then
      if "$R/src/net/mac/install.sh" --remove; then
        [[ $(app_net "$d") == vmnet ]] && info "fast network: off (the running VM switches to QEMU's own network now)"
      else
        info "the fast network's service stays installed (omacvm uninstall, or src/net/mac/install.sh --remove, takes it off)"
        [[ $(app_net "$d") == vmnet ]] && info "fast network: off from the VM's next start"
      fi
    elif [[ $(app_net "$d") == vmnet ]]; then
      info "fast network: off from the VM's next start"
    fi
  fi
  # Vulkan (Venus) from the VM's next start: the app reads the vulkan file
  # (on only with OmacVM's Mesa in the VM, see above).
  if on vulkan; then
    [[ -e $d/vulkan ]] || { : > "$d/vulkan"; [[ -z $(app_pid_dir "$d" 2>/dev/null) ]] ||
      info "WebGPU and GPU compute (Vulkan): from the VM's next start (shut it down, then start it again)"; }
  elif [[ -e $d/vulkan ]]; then
    rm -f "$d/vulkan"
    [[ -z $(app_pid_dir "$d" 2>/dev/null) ]] || info "Vulkan: off from the VM's next start"
  fi
  # Graphics: Automatic gives Vulkan only to a VM whose Venus driver sizes
  # GPU memory to the Mac's 16 KiB pages (the app reads venus-ready).
  if gssh "$IP" "/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh --ready" < /dev/null 2>/dev/null; then
    : > "$d/venus-ready"
  else
    rm -f "$d/venus-ready"
    if [[ $GRAPHICS == vulkan ]] && ! graphics_forced "$d"; then
      info "Graphics: the VM's Vulkan driver did not build (see above): the VM runs on OpenGL until an apply builds it"
    fi
  fi
  # Its VA-API shim keeps AV1 to Chromium-based browsers (FFmpeg's AV1 cannot
  # go to the Mac's decoder): the app may offer AV1 to this VM.
  gssh "$IP" "test -x /usr/local/lib/dri/omacvm_drv_video.so" < /dev/null 2>/dev/null &&
    echo av1 > "$d/video-decode"
fi

if [[ $TYPE == parallels ]]; then
  PVM=$(vm_bundle "$VM")
  [[ -d $PVM ]] && { log "Dock icon"; "$R/src/icon/set-vm-icon.sh" "$PVM"; }
  if (( MAC )) && ! parallels_sends_shortcuts; then
    info "Parallels: set Settings > Shortcuts > macOS System Shortcuts > Send macOS system shortcuts: Always"
    parallels_shortcuts_alert
  fi
fi
log "done$( [[ -n $had && $had != "$now" ]] && echo " (OmacVM $had -> $now)"): kernel, memory and keyboard changes apply after a reboot of the VM"
