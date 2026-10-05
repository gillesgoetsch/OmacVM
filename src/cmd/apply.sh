#!/bin/bash
# omacvm apply: put OmacVM onto a running VM (Parallels, UTM or VMware Fusion), or bring it up
# to this version: the Mac side the VM's features need, then the VM side. Also
# for an Omarchy you installed by hand from omarchy-mac.
#   omacvm apply [--vm NAME | --ip IP] [--vm-type parallels|utm|fusion|app] [--user NAME]
#                [--feature NAME=on|off]... [--FEATURE | --no-FEATURE]...
#                [--keyboard "LAYOUT [VARIANT]"] [--display WxH@Hz] [--key PRIVATE_KEY] [--no-mac]
#                [--reset-host-key]
# Features: `omacvm features` lists them (src/features.tsv). Not given: what the
# VM has (new to OmacVM: the defaults). --no-mac leaves the Mac side alone.
# VM: the one named Omarchy, else the only running one. A stopped VM is
# started. User: the VM's desktop user. Key: ~/.ssh/omacvm. Keyboard: the
# Mac's current layout. Display (UTM, Fusion): the Mac's built-in display below
# the notch (no built-in display: the main one). The VM's SSH host key is
# remembered the first time; --reset-host-key forgets it (a rebuilt VM).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person (see the message).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
features_load
VM=""; IP=""; TYPE=""; U=""; KEY=~/.ssh/omacvm; KB=""; MODE=""; MAC=1; NAMED=1; TOKEN=1; TOOLS=1
SETN=(); SETV=()
set_feature() {   # NAME on|off
  feature_index "$1" >/dev/null || { echo "omacvm apply: unknown feature '$1' (omacvm features lists them)" >&2; exit 2; }
  [[ $2 == on || $2 == off ]] || { echo "omacvm apply: --feature $1=$2: on or off" >&2; exit 2; }
  SETN+=("$1"); SETV+=("$2")
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
    --reset-host-key) export OMA_PIN_RESET=1; shift ;;
    --no-token) TOKEN=0; shift ;;   # prebuilt images: no Bridge token in the VM
    --no-tools) TOOLS=0; shift ;;   # prebuilt images: no Parallels Tools
    --feature) set_feature "${2%%=*}" "${2#*=}"; shift 2 ;;
    --no-*) set_feature "${1#--no-}" off; shift ;;
    -h|--help) sed -n '2,16s/^# \{0,1\}//p' "$0"; exit 0 ;;
    --*) f=${1#--}; feature_index "$f" >/dev/null || { echo "omacvm apply: unknown option $1 (see --help)" >&2; exit 2; }
         set_feature "$f" on; shift ;;
    *) echo "omacvm apply: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
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
[[ -n $KB ]] || KB=$("$R/src/keyboard/mac-layout.sh")
probe=$(vm_probe "$IP")
[[ -n $U ]] || U=$(sed -n 's/^OMACVM_USER=//p' <<<"$probe")
[[ -n $U ]] || die "no desktop user in '$VM' (pass --user NAME)"
had=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")

# ---------- the features it gets ----------
features_read_env "$probe"
notch_had=$(sed -n 's/^OMACVM_FEATURE_omanotch=//p' <<<"$probe" | tail -1)   # OmacVM.app: see below
# New to OmacVM (or a prebuilt VM before its first apply): the defaults,
# Omanotch with a notch.
if [[ -z $had ]] || grep -q '^OMACVM_PREBUILT_FRESH=1' <<<"$probe"; then
  for ((i = 0; i < ${#FN[@]}; i++)); do FV[$i]=$(feature_default "$i"); done
fi
for ((k = 0; k < ${#SETN[@]}; k++)); do FV[$(feature_index "${SETN[$k]}")]=${SETV[$k]}; done
before=("${FV[@]}"); features_fix
for ((i = 0; i < ${#FN[@]}; i++)); do
  [[ ${before[$i]} != "${FV[$i]}" ]] && info "${FTITLE[$i]}: off (it needs ${FNEEDS[$i]})"
done
# Parallels shows the Mac's battery itself.
[[ $TYPE == parallels ]] && FV[$(feature_index battery)]=off
on() { [[ ${FV[$(feature_index "$1")]} == on ]]; }
# UTM and Fusion get the Mac's battery and camera from OmacVM Bridge, also with
# its bar features off (OmacVM.app passes them itself).
battery_via_bridge() { on battery && [[ $TYPE == utm || $TYPE == fusion ]]; }
camera_via_bridge() { on camera && [[ $TYPE == utm || $TYPE == fusion ]]; }
needs_bridge() { on bridge || battery_via_bridge || camera_via_bridge; }
log "$TYPE VM '$VM' at $IP, user $U${had:+, OmacVM $had}"
info "features: $(for ((i = 0; i < ${#FN[@]}; i++)); do printf '%s=%s ' "${FN[$i]}" "${FV[$i]}"; done)"

# ---------- the Mac side ----------
if (( MAC )); then
  args=(--quiet)
  needs_bridge || args+=(--no-bridge)
  { on gestures || [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; } || args+=(--skip-gestures)   # on UTM and Fusion it also types Cmd as Super
  [[ $TYPE == parallels ]] || args+=(--skip-clip)   # the VM -> Mac clipboard of Parallels' shared folder
  # Omanotch from src/omanotch. OmacVM.app too, as for the other routes (the
  # app's own notch-strip mode is a separate switch in the app, which apply
  # leaves alone).
  on omanotch && args+=(--omanotch)
  "$R/src/mac/install.sh" "${args[@]}"
  # Chrome in the guest gets no GPU with UTM's "Apple Core OpenGL" renderer.
  if [[ $TYPE == utm ]]; then
    case $(defaults read com.utmapp.UTM QEMURendererBackend 2>/dev/null || echo 0) in
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
# The gestures daemon says it too (on UTM, Fusion and OmacVM.app it always
# runs; OmacVM.app's VMs show it on 127.0.0.1 even without the Bridge).
if (( TOKEN )) && { on gestures || [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; }; then bridge_token_ensure; fi
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
log "OmacVM -> $IP:/usr/local/share/omacvm"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$R/src" --exclude build --exclude __pycache__ -czf - . |
  gssh "$IP" "rm -rf /usr/local/share/omacvm && mkdir -p /usr/local/share/omacvm &&
              tar --no-same-owner -C /usr/local/share/omacvm -xzf - 2>/dev/null"
fargs=""
for ((i = 0; i < ${#FN[@]}; i++)); do fargs+=" --feature ${FN[$i]}=${FV[$i]}"; done
[[ $TYPE == fusion ]] && fargs+=" --host $(fusion_host)"
on mac-clock && fargs+=" --clock-format-b64 $(swift "$R/src/clock/mac-clock.swift" | base64)"
# Its name, so the Mac's gestures helper tells it from another VM in the same app.
(( NAMED )) && fargs+=" --vm-name-b64 $(printf %s "$VM" | base64 | tr -d '\n')"
gssh "$IP" "/usr/local/share/omacvm/guest/install.sh --user '$U' --keyboard '$KB' --vm-type $TYPE ${MODE:+--display $MODE}$fargs" < /dev/null
# OmacVM.app: this VM now draws Omarchy's own pointer. The app hides the Mac's
# over the window only for a VM with this file; VMs set up by older versions
# hid Omarchy's pointer and need the Mac's until they get this apply.
if [[ $TYPE == app ]] && (( NAMED )) && d=$(app_dir "$VM"); then
  echo omarchy > "$d/guest-pointer"
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
now=$(cat "$R/src/VERSION")
log "done$( [[ -n $had && $had != "$now" ]] && echo " (OmacVM $had -> $now)"): kernel, memory and keyboard changes apply after a reboot of the VM"
