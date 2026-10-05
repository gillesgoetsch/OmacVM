#!/bin/bash
# omacvm check: is every OmacVM feature in place and working, on the Mac and
# in a running VM (Parallels, UTM or VMware Fusion)? Read-only; run it after a build or an
# apply, or whenever something seems off:
#   omacvm check [--vm NAME | --ip IP] [--vm-type parallels|utm|fusion|app] [--user NAME] [--key PRIVATE_KEY] [--json]
# VM, user and key as in omacvm apply (a stopped VM is not started). One line
# per feature (ok / FAIL / skip); exits 1 if anything failed. The desktop user
# must be logged in to the VM.
# --json: {"vm", "type", "ip", "ok", "checks": [{"section", "name", "status",
# "detail", "needs_human"}]}; needs_human = only a person can fix it (a macOS
# permission, a Parallels setting).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
VM=""; IP=""; TYPE=""; U=""; KEY=~/.ssh/omacvm; JSON=0
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm check: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
export OMA_KEY=$KEY
# stop RC MESSAGE: no VM to check. With --json also the JSON, one failed check.
stop() {
  if (( JSON )); then
    printf '{"vm": %s, "type": %s, "ip": "", "ok": false, "checks": [\n  {"section": "Mac", "name": "VM", "status": "fail", "detail": %s, "needs_human": false}\n]}\n' \
      "$( [[ -n $VM ]] && json_str "$VM" || echo null)" "$( [[ -n $TYPE ]] && json_str "$TYPE" || echo null)" "$(json_str "$2")"
  fi
  echo "omacvm check: $2" >&2
  exit "$1"
}
if [[ -z $IP ]]; then
  # resolve_vm exits when it cannot tell which VM: in a subshell, to say so.
  err=$(mktemp)
  r=$(resolve_vm 2>"$err" && printf '%s\t%s\t%s' "$VM" "$TYPE" "$IP"); rc=$?
  msg=$(sed 's/^omacvm: //' "$err"); rm -f "$err"
  (( rc == 0 )) || stop "$rc" "${msg:-no VM}"
  IFS=$'\t' read -r VM TYPE IP <<<"$r"
  # An app VM whose fast network did not come up has no address: say why.
  if [[ -z $IP && $TYPE == app ]] && d=$(app_dir "$VM") && app_running_dir "$d" &&
     n=$(head -1 "$d/logs/network" 2>/dev/null) && [[ $n == vmnet-down* ]]; then
    stop 1 "fast network: ${n#vmnet-down }"
  fi
  [[ -n $IP ]] || stop 1 "'$VM' is not running (start it, or omacvm apply --vm \"$VM\" starts it)"
fi
if [[ -z $TYPE ]]; then
  TYPE=$(vm_type "$VM" 2>/dev/null) || {
    (( $? == 2 )) && stop 2 "there is more than one VM named '$VM': pass --vm-type parallels, utm, fusion or app"
    stop 1 "no Parallels, UTM, VMware Fusion or OmacVM.app VM named '$VM' (or pass --vm-type and --ip)"; }
fi
case $TYPE in
  parallels) HOST=10.211.55.2
             [[ -n $IP ]] || IP=$(vm_ip "$(vm_bundle "$VM")") || stop 1 "no IP for VM '$VM' (is it running?)" ;;
  utm) HOST=192.168.64.1
       [[ -n $IP ]] || IP=$(utm_ip "$VM" 10) || stop 1 "no IP for UTM VM '$VM' (is it running?)" ;;
  fusion) HOST=$(fusion_host)
          [[ -n $IP ]] || IP=$(fusion_ip "$VM" 10) || stop 1 "no IP for VMware Fusion VM '$VM' (is it running?)" ;;
  app) [[ -n $IP ]] || IP=$(app_ip "$VM") || stop 1 "OmacVM.app VM '$VM' is not running"
       # OmacVM.app: QEMU's user network reaches the Mac's 127.0.0.1 as 10.0.2.2;
       # on its fast network (vmnet) the Mac is 192.168.77.1.
       if [[ $IP == 127.0.0.1:* ]]; then HOST=127.0.0.1; else HOST=192.168.77.1; fi ;;
  *) stop 2 "--vm-type parallels, utm, fusion or app" ;;
esac
export OMA_KEY=$KEY

fails=0; ROWS=""; SECTION=Mac
# line STATUS LABEL NAME DETAIL [human]
line() {
  if (( JSON )); then ROWS+="$1"$'\t'"$SECTION"$'\t'"$3"$'\t'"$4"$'\t'"${5:+1}"$'\n'
  else printf '  %-5s %-24s %s\n' "$2" "$3" "$4"; fi
}
ok()   { line ok ok "$1" "${2:-}"; }
bad()  { line fail FAIL "$1" "${2:-}" "${3:-}"; fails=$((fails + 1)); }
skip() { line skip skip "$1" "${2:-}" "${3:-}"; }
say_() { (( JSON )) || echo "$@"; }
json_out() {   # the collected rows as JSON
  local first=1 st sec name detail human
  printf '{"vm": %s, "type": "%s", "ip": %s, "ok": %s, "checks": [' "$(json_str "${VM:-}")" "$TYPE" "$(json_str "${IP:-}")" "$1"
  while IFS=$'\t' read -r st sec name detail human; do
    [[ -n $st ]] || continue
    printf '%s\n  {"section": %s, "name": %s, "status": "%s", "detail": %s, "needs_human": %s}' \
      "$( ((first)) || echo ,)" "$(json_str "$sec")" "$(json_str "$name")" "$st" "$(json_str "$detail")" "$( [[ $human == 1 ]] && echo true || echo false)"
    first=0
  done <<<"$ROWS"
  printf '\n]}\n'
}
running() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'state = running'; }
# listeners PORT: the addresses something listens on for that port
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { sub(/:[0-9]+$/, "", $9); print $9 }' | sort -u | tr '\n' ' '; }
last_line() { grep -E "$2" "$1" 2>/dev/null | tail -1 | sed 's/^.*omacvm-[a-z]*: //'; }

say_ "Mac"
L=~/Library/Logs
# The VM network's Mac address exists only while a VM of that type runs.
if ! msg=$(vm_network_ok "$TYPE" "$IP" 2>&1); then
  bad "VM network" "$msg" human
  (( JSON )) && json_out false
  exit 1
fi
# OmacVM.app on the fast network: 192.168.77.1 being up proves little (it
# stays while any app VM uses it). The app must still say vmnet (it watches
# the link the whole run), the VM's address must route to a Mac interface
# with 192.168.77.1, and the VM must answer there.
fast_net_down() {   # -> why, when the VM's fast network is not working
  local d n ifc
  d=$(app_dir "$VM" 2>/dev/null); n=$(head -1 "$d/logs/network" 2>/dev/null)
  [[ $n == vmnet ]] || { echo "${n:-the app did not say which network it took}"; return 0; }
  ifc=$(route -n get "$IP" 2>/dev/null | awk '/interface:/ { print $2 }')
  [[ -n $ifc ]] && ifconfig "$ifc" 2>/dev/null | grep -q "inet 192.168.77.1 " ||
    { echo "no Mac interface with 192.168.77.1 leads to the VM's $IP"; return 0; }
  ping -c 1 -t 3 -q "$IP" >/dev/null 2>&1 || { echo "the VM does not answer at $IP"; return 0; }
  return 1
}
if [[ $TYPE == app && $HOST == 192.168.77.1 ]] && why=$(fast_net_down); then
  bad "VM network" "the fast network is not working: $why (omacvm-netd's log: /var/log/org.omacvm.netd.log)"
  (( JSON )) && json_out false
  exit 1
fi
if ! ifconfig | grep -q "inet $HOST "; then
  bad "VM network" "$HOST is not up on this Mac: start the VM, then run omacvm check again"
  (( JSON )) && json_out false
  exit 1
fi
[[ -n ${OMA_PIN:-} || -z ${VM:-} ]] || vm_pin "$VM" "$TYPE"   # --ip alone: no key kept (DHCP reuses addresses)
ssh_ok=0; (wait_ssh "$IP" 30) >/dev/null 2>&1 || ssh_ok=$?
if (( ssh_ok == 3 )); then
  bad "SSH" "$IP answers with another SSH host key than the one OmacVM remembered (rebuilt? omacvm apply ${OMA_PIN_ARGS:-} --reset-host-key)"
  (( JSON )) && json_out false; exit 1
elif (( ssh_ok )); then
  bad "SSH" "no SSH to $IP with $KEY (omacvm apply shows how to let OmacVM in)"; (( JSON )) && json_out false; exit 1
fi
[[ -n $U ]] || U=$(vm_probe "$IP" | sed -n 's/^OMACVM_USER=//p')
# What was chosen at setup for this VM (defaults for VMs from before the choices).
envf=$(gssh "$IP" cat /etc/omacvm/env 2>/dev/null)
feat() { local v; v=$(sed -n "s/^OMACVM_FEATURE_$1=//p" <<<"$envf" | tail -1); echo "${v:-${2:-on}}"; }
BRIDGE=$(feat bridge); GESTURES=$(feat gestures); GLIDE=$(feat scroll_momentum "$(feat glide off)")

# OmacVM.app's fast network: the service on the Mac, and which network this
# start of the VM took (the app writes it to logs/network).
netd_said() {   # omacvm-netd's last refusal or failure of the last 10 minutes, as "; omacvm-netd: ..."
  local l t
  l=$(grep -E 'refused|failed|did not|kept failing|stopped' /var/log/org.omacvm.netd.log 2>/dev/null | tail -1)
  t=$(date -j -f '%Y-%m-%d %H:%M:%S' "${l:0:19}" +%s 2>/dev/null) || return 0
  (( $(date +%s) - t < 600 )) && printf '; %s' "$(cut -d' ' -f3- <<<"$l")"
  return 0
}
if [[ $TYPE == app ]]; then
  if [[ $(feat fast_network off) == on ]]; then
    case $("$R/src/net/mac/install.sh" --status 2>/dev/null) in
      ok) ok "fast network service" "omacvm-netd, for this OmacVM.app" ;;
      old) bad "fast network service" "for another build of the app, or older: omacvm enable fast-network --vm \"$VM\"" ;;
      down) bad "fast network service" "installed, but launchd does not run it: sudo launchctl bootstrap system /Library/LaunchDaemons/org.omacvm.netd.plist" ;;
      stopped) bad "fast network service" "vmnet failed too often in a row, so omacvm-netd stopped trying (each failure costs macOS's vmnet service for good): restart the Mac, or omacvm enable fast-network --vm \"$VM\" again" ;;
      *) bad "fast network service" "not installed: omacvm enable fast-network --vm \"$VM\"" ;;
    esac
    d=$(app_dir "$VM" 2>/dev/null); net=$(head -1 "$d/logs/network" 2>/dev/null)
    case $net in
      vmnet) ok "fast network" "on (vmnet), the VM is $IP" ;;
      slirp\ fallback*) bad "fast network" "${net#slirp fallback: }$(netd_said)" ;;
      slirp*) bad "fast network" "this start took QEMU's user network: ${net#slirp }" ;;
      vmnet-down*) bad "fast network" "${net#vmnet-down }$(netd_said)" ;;
      *) bad "fast network" "the app did not say which network it took (from before the fast network? omacvm update)" ;;
    esac
  else skip "fast network" "off (experimental: omacvm enable fast-network)"; fi
fi

if [[ $BRIDGE == on ]]; then
  if running org.omacvm.bridge; then
    a=$(listeners 47831)
    if [[ " $a " == *" * "* || $a == *0.0.0.0* ]]; then bad "Bridge" "listens on every interface: $a"
    elif [[ " $a " == *" $HOST "* ]]; then ok "Bridge" "listening on $a"
    else bad "Bridge" "not listening on $HOST (only: ${a:-nothing})"; fi
  else bad "Bridge" "OmacVM Bridge is not running (src/mac/install.sh)"; fi
  T=~/Library/Application\ Support/omacvm-bridge/token
  if [[ -s $T ]]; then
    [[ $(stat -f %Lp "$T") == 600 ]] && ok "token" "private (600)" || bad "token" "readable by others: chmod 600"
    # The token only to this user's Bridge (on 127.0.0.1 any Mac program could
    # listen), and through a header file, never on a command line.
    bget() { curl -s -m 3 -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$T")") "http://$HOST:47831$1"; }
    lsof -nP -a -u "$(id -u)" -c omacvm-bridge -iTCP@"$HOST":47831 -sTCP:LISTEN >/dev/null 2>&1 ||
      { bad "Bridge" "$HOST:47831 is not held by this user's OmacVM Bridge: token not sent"; bget() { :; }; }
    st=$(bget /state)
    if jq -e .location_authorized <<<"$st" >/dev/null 2>&1; then ok "Location Services" "granted (Wi-Fi names)"
    else bad "Location Services" "not granted to OmacVM Bridge (System Settings > Privacy & Security > Location Services)" human; fi
    bt=$(bget /bluetooth)
    case $(jq -r '.permission // empty' <<<"$bt" 2>/dev/null) in
      granted) ok "Bluetooth" "granted (connect devices from the VM)" ;;
      "") bad "Bluetooth" "the Bridge does not answer /bluetooth: src/mac/install.sh" ;;
      *) bad "Bluetooth" "not granted to OmacVM Bridge (System Settings > Privacy & Security > Bluetooth)" human ;;
    esac
  else bad "token" "missing (src/mac/install.sh)"; fi
  m=$(last_line "$L/omacvm-bridge.log" 'media keys: (event tap|waiting|cannot)')
  [[ $m == *installed* ]] && ok "media keys" "event tap installed" || bad "media keys" "${m:-no event tap yet}"
  # Dimmer keyboard light steps (config.json); flicker is for a person to judge.
  c=~/Library/Application\ Support/omacvm-bridge/config.json
  if [[ $(last_line "$L/omacvm-bridge.log" 'keyboard light: ') == *none* ]]; then
    skip "keyboard light" "this Mac has none (Shift + brightness keys stay macOS's)"
  elif [[ $(jq -r '.keyboard_low_steps == false' "$c" 2>/dev/null) == true ]]; then
    skip "keyboard light" "macOS's 1/16 steps (keyboard_low_steps off in $c)"
  else ok "keyboard light" "3 steps below macOS's lowest (keyboard_low_steps in config.json; off if the keys flicker)"; fi
else skip "Bridge" "off (chosen at setup)"; fi
# The camera of UTM and Fusion VMs comes through the Bridge (also with its bar features off).
if [[ $(feat camera off) == on && ( $TYPE == utm || $TYPE == fusion ) ]]; then
  running org.omacvm.bridge && ok "camera (Bridge)" "OmacVM Bridge passes the Mac's camera" \
    || bad "camera (Bridge)" "OmacVM Bridge is not running (omacvm apply --vm \"$VM\")"
fi
# The microphone: the VM's app records only with macOS's permission, and its
# recording helper cannot ask (docs/troubleshooting.md, finding 22). Its log says so.
miclog=""
case $TYPE in
  fusion) x=$(fusion_vmx "$VM" 2>/dev/null) && miclog="$(dirname "$x")/vmware.log"; micapp="VMware Fusion" ;;
  app) d=$(app_dir "$VM" 2>/dev/null) && miclog="$d/logs/qemu.log"; micapp="OmacVM" ;;
esac
if [[ -n $miclog && -f $miclog ]]; then
  if grep -q -e "Failed to start input audio queue" -e "SDL_OpenAudioDevice for recording failed" -e "no microphone permission yet" "$miclog"; then
    bad "microphone" "macOS does not let $micapp record: System Settings > Privacy & Security > Microphone, then restart the VM" human
  else ok "microphone" "no refusal in $micapp's log"; fi
fi
# A VM app whose GPU context virglrenderer dropped draws nothing until it
# restarts; for the shell that is a black display without bar. QEMU's log
# (this run of the VM) names it.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  lost=$(grep -o 'context error reported [0-9]* "[^"]*"' "$miclog" | sed 's/.*"\(.*\)"$/\1/' | sort -u | paste -sd, - | sed 's/,/, /g')
  # Not a failure by itself: the app may have been restarted since (the VM's
  # "desktop" line says whether the shell draws now).
  if [[ -n $lost ]]; then
    skip "GPU contexts" "lost earlier in this run by: $lost (an app that draws nothing needs a restart; the shell: omarchy-restart-shell)"
  else ok "GPU contexts" "no VM app lost its GPU context in this run"; fi
fi
# Gestures runs keys-only when trackpad gestures were turned off; on UTM it
# also types Cmd as Super, so it is needed there either way.
if [[ $GESTURES == on || $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; then
  if running org.omacvm.gestures; then
    a=$(listeners 47830)
    [[ " $a " == *" $HOST "* ]] && ok "Gestures" "listening on $a" || bad "Gestures" "not listening on $HOST (only: ${a:-nothing})"
    # A VM last updated with OmacVM 2.3 or older: its daemon has no token, so
    # Gestures refuses it (and it tries again every 2 s) until it is updated.
    if [[ $TYPE != app ]]; then
      r=$(grep -nF "omacvm-gestures: refused ${IP%:*} on " "$L/omacvm-gestures.log" 2>/dev/null | grep -F ": no token" | tail -1 | cut -d: -f1)
      c=$(grep -nF "omacvm-gestures: guest connected: ${IP%:*} " "$L/omacvm-gestures.log" 2>/dev/null | tail -1 | cut -d: -f1)
      (( ${r:-0} > ${c:-0} )) &&
        bad "Gestures for this VM" "refused: its trackpad daemon is from OmacVM 2.3 or older (omacvm update --vm \"$VM\")"
    fi
    keysonly=$(launchctl print "gui/$(id -u)/org.omacvm.gestures" 2>/dev/null | grep -c -- '--keys-only')
    if [[ $GESTURES == on && $keysonly != 0 ]]; then
      bad "trackpad gestures" "OmacVM Gestures runs keys-only on this Mac: src/mac/install.sh turns gestures back on"
    fi
    # A Mac mini, iMac or Studio may have no trackpad yet: the helper waits for one.
    if [[ $GESTURES == on && $keysonly == 0 ]]; then
      t=$(last_line "$L/omacvm-gestures.log" 'no trackpad found|trackpad: ')
      case $t in
        "no trackpad"*) skip "trackpad" "none connected: the swipes start when a Magic Trackpad connects" ;;
        trackpad:*) ok "trackpad" "${t#trackpad: }" ;;
      esac
    fi
    if [[ $GESTURES == on && $GLIDE == on ]]; then
      # OmacVM.app's VMs all connect from 127.0.0.1: this VM's own line first.
      g=$(grep "guest connected: ${IP%:*} " "$L/omacvm-gestures.log" 2>/dev/null | grep -F "VM \"$VM\")" | tail -1)
      [[ -n $g ]] || g=$(grep "guest connected: ${IP%:*} " "$L/omacvm-gestures.log" 2>/dev/null | tail -1)
      if [[ $g == *"scroll momentum on"* || $g == *"Glide on"* ]]; then ok "scroll momentum (Mac)" "scrolling goes to this VM in full screen"
      else bad "scroll momentum (Mac)" "the helper does not scroll for this VM yet (omacvm apply --vm \"$VM\")"; fi
    fi
    # The helper listens only once it has its permissions, so a later
    # "listening" line overrides a "waiting" one (e.g. a restart while waiting).
    p=$(last_line "$L/omacvm-gestures.log" 'permission|listening on')
    [[ -z $p || $p == *granted* || $p == listening* ]] && ok "keyboard/trackpad access" "Accessibility + Input Monitoring" \
      || bad "keyboard/trackpad access" "${p}: System Settings > Privacy & Security" human
  else bad "Gestures" "OmacVM Gestures is not running (src/mac/install.sh)"; fi
else skip "Gestures" "trackpad gestures off (chosen at setup)"; fi
# The Mac's battery: the Bridge serves it to UTM and Fusion VMs, OmacVM.app
# passes it on its own port; Parallels gives the VM its own.
if [[ $(feat battery off) == on && $TYPE != parallels ]]; then
  if [[ $TYPE == app ]]; then
    pid=$(app_pid_dir "$(app_dir "$VM")" 2>/dev/null)
    if [[ -n $pid ]] && ps -o args= -p "$pid" | grep -q 'name=org.omacvm.battery'; then ok "battery (Mac)" "OmacVM.app passes it (virtio port)"
    else bad "battery (Mac)" "this OmacVM.app does not pass the battery: omacvm update, then shut the VM down and start it again"; fi
  elif ! running org.omacvm.bridge; then
    bad "battery (Mac)" "OmacVM Bridge is not running: it serves the battery to $TYPE VMs (omacvm apply)"
  else
    T=~/Library/Application\ Support/omacvm-bridge/token b=""
    # The token only to this user's Bridge (as above).
    if [[ -s $T ]] && lsof -nP -a -u "$(id -u)" -c omacvm-bridge -iTCP@"$HOST":47831 -sTCP:LISTEN >/dev/null 2>&1; then
      b=$(curl -s -m 3 -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$T")") "http://$HOST:47831/battery")
    fi
    case $(jq -r '.present | tostring' <<<"$b" 2>/dev/null) in
      true) ok "battery (Mac)" "the Bridge serves it: $(jq -r '"\(.percentage) %, \(.state)"' <<<"$b")" ;;
      false) skip "battery (Mac)" "this Mac has no battery" ;;
      *) bad "battery (Mac)" "the Bridge does not answer /battery (older than the battery: omacvm update)" ;;
    esac
  fi
fi
# macOS's "Automatically hide and show the menu bar: Never" keeps the Mac's
# menu bar over the full-screen VM: a hint (it is the person's setting).
if [[ $(defaults read NSGlobalDomain AppleMenuBarVisibleInFullscreen 2>/dev/null) == 1 ]]; then
  skip "menu bar in full screen" "macOS always shows it: System Settings > Menu Bar (older macOS: Control Center) > Automatically hide and show the menu bar: In Full Screen Only" human
else ok "menu bar in full screen" "hidden by macOS"; fi
case $TYPE in
parallels)
  running org.omacvm.clip-in && ok "clipboard VM -> Mac" "org.omacvm.clip-in" || bad "clipboard VM -> Mac" "org.omacvm.clip-in not running"
  # Parallels keeps both settings in undocumented files: hints, not failures.
  parallels_sends_shortcuts && ok "Cmd+Space etc. to the VM" "Send macOS system shortcuts: Always" \
    || skip "Cmd+Space etc. to the VM" "set Parallels Desktop > Settings > Shortcuts > macOS System Shortcuts > Send macOS system shortcuts: Always" human
  # Every Mac display in full screen needs Parallels' own full screen (not
  # macOS's native one) with "Use all displays" (new VMs get both).
  pvs="$(vm_bundle "$VM")/config.pvs"
  if grep -q '<UseAllDisplays>1' "$pvs" 2>/dev/null && grep -q '<UseNativeFullScreen>0' "$pvs" 2>/dev/null; then
    ok "full screen on every display" "Parallels' full screen, all displays"
  else
    skip "full screen on every display" "shut the VM down, then omacvm apply --vm \"$VM\" (it sets this when it starts the VM)" human
  fi
  parallels_profile_emptied && ok "Cmd+C/V/X as Super" "Parallels' Linux profile emptied" \
    || skip "Cmd+C/V/X as Super" "Parallels turns them into Ctrl: quit Parallels Desktop, run src/mac/parallels-shortcuts.sh" human ;;
utm)
  [[ $(defaults read com.utmapp.UTM QEMUVulkanDriver 2>/dev/null) == 1 ]] && ok "UTM speed settings" "no Vulkan driver (fast page size)" \
    || bad "UTM speed settings" "QEMUVulkanDriver is not 1: omacvm build sets it, or run defaults write com.utmapp.UTM QEMUVulkanDriver -int 1; restart UTM after"
  case $(defaults read com.utmapp.UTM QEMURendererBackend 2>/dev/null || echo 0) in
    0|2) ok "UTM renderer" "ANGLE on Metal (GPU in Chrome)" ;;
    *) bad "UTM renderer" "Chrome gets no GPU: UTM › Settings › Display › Renderer Backend: Default, then restart UTM" ;;
  esac ;;
esac
if pgrep -xq omanotch; then
  # Omanotch's own setting (defaults write ch.gillesgoetsch.omanotch flush -bool true|false).
  [[ $(defaults read ch.gillesgoetsch.omanotch flush 2>/dev/null) == 1 ]] && h="the notch's (flush)" || h="the menu bar's"
  ok "Omanotch (Mac)" "running, bar height: $h"
elif [[ ${notch:=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)} != notch ]]; then skip "Omanotch (Mac)" "no notch on this Mac"
else skip "Omanotch (Mac)" "not running (omacvm update)"; fi
if [[ $TYPE == app && $(feat omanotch off) == on ]]; then
  rc=0; omanotch_serves_app || rc=$?
  (( rc != 1 )) || bad "Omanotch for OmacVM.app" "too old: it does not serve 127.0.0.1, so this VM's strip stays empty (omacvm update)"
fi
if [[ $TYPE == app ]]; then
  # The app's own notch-strip mode (a switch in the app; Omanotch then leaves the strip alone).
  n=$(defaults read org.omacvm.app useNotch 2>/dev/null || echo 0)
  if [[ $n == 1 ]]; then skip "notch strip (app)" "the app's full screen covers it (no Space of its own)"
  elif [[ ${notch:=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)} != notch ]]; then skip "notch strip (app)" "no notch on this Mac"
  else skip "notch strip (app)" "off: full screen in its own Space, Omanotch fills the strip"; fi
fi
(( fails )) && mac_failed=1 || mac_failed=0

if (( JSON )); then
  out=$(gssh "$IP" "bash -s -- --user '$U' --tsv" < "$R/src/guest/check.sh"); guest=$?
  while IFS=$'\t' read -r a b c d; do
    if [[ $a == section ]]; then SECTION="VM: $b"
    elif [[ -n $a ]]; then ROWS+="$a"$'\t'"$SECTION"$'\t'"$b"$'\t'"$c"$'\t'"$d"$'\n'; fi
  done <<<"$out"
  json_out "$( (( guest == 0 && ! mac_failed )) && echo true || echo false)"
  (( guest == 0 && ! mac_failed )); exit
fi
echo
echo "VM '$VM' at $IP"
gssh "$IP" "bash -s -- --user '$U'" < "$R/src/guest/check.sh"
guest=$?
(( mac_failed )) && echo "(and $fails check(s) failed on the Mac)"
(( guest == 0 && ! mac_failed ))
