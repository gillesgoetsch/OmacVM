#!/bin/bash
# omacvm check: is every OmacVM feature in place and working, on the Mac and
# in a running VM (Parallels, UTM or VMware Fusion)? Read-only; run it after a build or an
# apply, or whenever something seems off:
#   omacvm check [--vm NAME | --ip IP] [--vm-type parallels|utm|fusion|app] [--user NAME] [--key PRIVATE_KEY]
#                [--json] [--mac-only]
# VM, user and key as in omacvm apply (a stopped VM is not started). One line
# per feature (ok / WARN / FAIL / skip); exits 1 if anything failed (WARN:
# works, but on a fallback). The desktop user must be logged in to the VM.
# --mac-only: the Mac's side for that VM, not the checks inside it.
# --json: {"vm", "type", "ip", "ok", "checks": [{"section", "name", "status"
# (ok, warn, fail, skip), "detail", "needs_human", "feature"}]}; needs_human =
# only a person can fix it (a macOS permission, a Parallels setting: the
# detail says where); feature = the features.tsv name the check belongs to
# ("" = the Mac or VM in general).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
VM=""; IP=""; TYPE=""; U=""; KEY=~/.ssh/omacvm; JSON=0; MAC_ONLY=0
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --user) U=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --mac-only) MAC_ONLY=1; shift ;;
    -h|--help) sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm check: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
source "$R/src/lib/graphics.sh"
source "$R/src/lib/notch.sh"
export OMA_KEY=$KEY
# stop RC MESSAGE: no VM to check. With --json also the JSON, one failed check.
stop() {
  if (( JSON )); then
    printf '{"vm": %s, "type": %s, "ip": "", "ok": false, "checks": [\n  {"section": "Mac", "name": "VM", "status": "fail", "detail": %s, "needs_human": false, "feature": ""}\n]}\n' \
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
  [[ -n $IP ]] || stop 1 "'$VM' is off, nothing was started (start it, or omacvm apply --vm \"$VM\" starts it)"
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

fails=0; ROWS=""; SECTION=Mac; FEATURE=""   # FEATURE: what the next lines belong to
# ROWS: one check per line, fields split by US (\037): unlike a tab, read
# keeps an empty field.
US=$'\037'
# line STATUS LABEL NAME DETAIL [human]
line() {
  if (( JSON )); then ROWS+="$1$US$SECTION$US$3$US$4$US${5:+1}$US$FEATURE"$'\n'
  else printf '  %-5s %-24s %s\n' "$2" "$3" "$4"; fi
}
ok()   { line ok ok "$1" "${2:-}"; }
bad()  { line fail FAIL "$1" "${2:-}" "${3:-}"; fails=$((fails + 1)); }
skip() { line skip skip "$1" "${2:-}" "${3:-}"; }
# warn: works, but not as it should; does not fail the check.
warn() { line warn WARN "$1" "${2:-}" "${3:-}"; }
say_() { (( JSON )) || echo "$@"; }
json_out() {   # the collected rows as JSON
  local first=1 st sec name detail human feature
  printf '{"vm": %s, "type": "%s", "ip": %s, "ok": %s, "checks": [' "$(json_str "${VM:-}")" "$TYPE" "$(json_str "${IP:-}")" "$1"
  while IFS=$US read -r st sec name detail human feature; do
    [[ -n $st ]] || continue
    printf '%s\n  {"section": %s, "name": %s, "status": "%s", "detail": %s, "needs_human": %s, "feature": %s}' \
      "$( ((first)) || echo ,)" "$(json_str "$sec")" "$(json_str "$name")" "$st" "$(json_str "$detail")" \
      "$( [[ $human == 1 ]] && echo true || echo false)" "$(json_str "$feature")"
    first=0
  done <<<"$ROWS"
  printf '\n]}\n'
}
# The helpers' LaunchAgent labels (org.omacvm.test.* for a test HOME: src/lib/labels.sh).
L_BRIDGE=$(omacvm_label bridge) L_GESTURES=$(omacvm_label gestures) L_CLIP=$(omacvm_label clip-in)
# The Bridge and Gestures by their process, whichever job started it: their
# LaunchAgent, or macOS itself after a grant (#331); the rest by its LaunchAgent.
HELPER_ID=""
[[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && HELPER_ID="test"
running() {
  case $1 in
    "$L_BRIDGE") [[ -n $(helper_pid bridge $HELPER_ID) ]] ;;
    "$L_GESTURES") [[ -n $(helper_pid gestures $HELPER_ID) ]] ;;
    *) launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'state = running' ;;
  esac
}
# The test identity (OMACVM_TEST_IDENTITY=1): its own helpers (started with open,
# no LaunchAgent) on their own ports.
BRIDGE_PORT=47831 GESTURES_PORT=47830
if [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]]; then
  BRIDGE_PORT=47931 GESTURES_PORT=47930
  running() {
    case $1 in
      "$L_BRIDGE") [[ -n $(helper_pid bridge test) ]] ;;
      "$L_GESTURES") [[ -n $(helper_pid gestures test) ]] ;;
      *) return 1 ;;
    esac
  }
fi
# listeners PORT: the addresses something listens on for that port
listeners() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { sub(/:[0-9]+$/, "", $9); print $9 }' | sort -u | tr '\n' ' '; }
last_line() { grep -E "$2" "$1" 2>/dev/null | tail -1 | sed 's/^.*omacvm-[a-z]*: //'; }

say_ "Mac"
L=~/Library/Logs
BRIDGE_LOG=$L/omacvm-bridge.log GESTURES_LOG=$L/omacvm-gestures.log
# The test identity's helpers log there (src/mac/install.sh starts them so).
[[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && BRIDGE_LOG=$L/omacvm-test-bridge.log GESTURES_LOG=$L/omacvm-test-gestures.log
# Only what the running helpers wrote: a log from a process before them (one
# macOS started again writes nowhere, 3.0.13) says nothing about them (#331).
LOGS_NOW=$(mktemp -d)
trap 'rm -rf "$LOGS_NOW"' EXIT
BRIDGE_PID=$(helper_pid bridge $HELPER_ID) GESTURES_PID=$(helper_pid gestures $HELPER_ID) BRIDGE_OLD="" GESTURES_OLD=""
if [[ -n $BRIDGE_PID ]]; then
  helper_log "$BRIDGE_PID" "$BRIDGE_LOG" > "$LOGS_NOW/bridge" || BRIDGE_OLD=$BRIDGE_PID
  BRIDGE_LOG=$LOGS_NOW/bridge
fi
if [[ -n $GESTURES_PID ]]; then
  helper_log "$GESTURES_PID" "$GESTURES_LOG" > "$LOGS_NOW/gestures" || GESTURES_OLD=$GESTURES_PID
  GESTURES_LOG=$LOGS_NOW/gestures
fi
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
# OmacVM.app's fast network: its fast-network file is the switch (the app's
# button and omacvm enable/disable both set it).
FAST_NET=$(feat fast_network off)
if [[ $TYPE == app ]] && d=$(app_dir "$VM" 2>/dev/null); then [[ -s $d/fast-network ]] && FAST_NET=on || FAST_NET=off; fi

# OmacVM's record of the features against the VM as it is (src/lib/features.sh):
# what was switched outside OmacVM (the app's Fast network button, an SDDM
# autologin file OmacVM did not write) keeps its real state, and the record
# is fixed to match; an OmacVM.app VM's record (its features file) and the
# VM's copy (/etc/omacvm/env) should say the same.
probe=$(vm_probe "$IP")
if [[ -n $(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe") ]]; then
  features_load
  rd=""; [[ $TYPE == app && -n ${VM:-} ]] && { rd=$(app_dir "$VM" 2>/dev/null) || rd=""; }
  features_read_env "$probe"; COPY=("${FV[@]}")
  features_read_record "$rd"; REC=("${FV[@]}")
  features_real "$probe" "$rd"
  if [[ -n ${DRIFT[*]+x} ]]; then
    # A newer OmacVM's record is not this one's to write (it knows other features, #233).
    if version_lt "$(cat "$R/src/VERSION")" "$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")"; then
      fx="not fixed: the VM has a newer OmacVM than this omacvm"
    elif features_record_fix "$IP" "$rd"; then fx="fixed the record"; else fx="could not fix the VM's copy (/etc/omacvm/env)"; fi
    for d in "${DRIFT[@]}"; do
      FEATURE=${d%%$'\t'*}
      dl=$(DRIFT=("$d"); features_drift_lines "$fx")
      [[ -n $dl ]] || continue   # only the VM's copy was behind the record: fixed, nothing to say
      if [[ $fx == fixed* ]]; then ok "record" "$dl"
      else warn "record" "$dl"; fi
    done
    COPY=("${FV[@]}"); REC=("${FV[@]}")
  fi
  if [[ -n $rd && -f $rd/features ]]; then
    for ((i = 0; i < ${#FN[@]}; i++)); do
      [[ ${REC[$i]} == "${COPY[$i]}" ]] && continue
      FEATURE=${FN[$i]}
      warn "record" "${FTITLE[$i]}: ${REC[$i]} in OmacVM's record (the VM's features file), ${COPY[$i]} in the VM's copy: omacvm apply --vm \"$VM\" brings them together"
    done
  fi
  FEATURE=""
fi

FEATURE=fast-network
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
  d=$(app_dir "$VM" 2>/dev/null); net=$(head -1 "$d/logs/network" 2>/dev/null)
  # The switch (fast-network) says how the NEXT start goes; this start keeps
  # the network it took (logs/network).
  if [[ $FAST_NET == on ]]; then
    st=$("$R/src/net/mac/install.sh" --status 2>/dev/null)
    upd="omacvm enable fast-network --vm \"$VM\", or Update… under Fast network in OmacVM (macOS asks for your password once); until then the VM starts on QEMU's own network"
    case $(head -1 <<<"$st") in
      ok) ok "fast network service" "omacvm-netd, for this OmacVM.app" ;;
      old) bad "fast network service" "needs an update for this OmacVM.app (it is from another version of the app): $upd" human ;;
      down) bad "fast network service" "installed, but launchd does not run it: sudo launchctl bootstrap system /Library/LaunchDaemons/org.omacvm.netd.plist" human ;;
      stopped) bad "fast network service" "vmnet failed too often in a row, so omacvm-netd stopped trying (each failure costs macOS's vmnet service for good): restart the Mac, or omacvm enable fast-network --vm \"$VM\" again" human ;;
      *) bad "fast network service" "not installed: $upd" human ;;
    esac
    case $net in
      vmnet) ok "fast network" "on (vmnet), the VM is $IP" ;;
      "slirp off") warn "fast network" "on from the VM's next start; this start runs on QEMU's own network (shut the VM down, then start it again)" ;;
      slirp\ fallback*) bad "fast network" "${net#slirp fallback: }$(netd_said)" ;;
      slirp*) bad "fast network" "this start took QEMU's user network: ${net#slirp }" ;;
      vmnet-down*) bad "fast network" "${net#vmnet-down }$(netd_said)" ;;
      *) bad "fast network" "the app did not say which network it took (from before the fast network? omacvm update)" ;;
    esac
    # Networks that came up after macOS's sharing started (a VPN): omacvm-netd
    # translates the VMs' addresses there itself (its VPN NAT).
    nat=$(sed -n 's/^vpn-nat: //p' <<<"$st")
    natlog=$(grep 'VPN NAT' /var/log/org.omacvm.netd.log 2>/dev/null | tail -1)
    natt=$(date -j -f '%Y-%m-%d %H:%M:%S' "${natlog:0:19}" +%s 2>/dev/null || echo 0)
    if [[ $natlog == *"VPN NAT: "* && $natlog != *"removed what"* ]] && (( $(date +%s) - natt < 600 )); then
      bad "VPN NAT" "$(cut -d' ' -f3- <<<"$natlog") (a VPN connected while the VM runs may not work for it)"
    elif [[ -n $nat ]]; then ok "VPN NAT" "omacvm-netd translates the VM's addresses on $nat (came up after macOS's sharing started, e.g. a VPN)"
    elif [[ $net == vmnet ]]; then ok "VPN NAT" "not needed: macOS's sharing covers every network that is up"; fi
  elif [[ $net == vmnet ]]; then ok "fast network" "off from the VM's next start; this start runs on it (vmnet), the VM is $IP"
  else skip "fast network" "off (experimental: omacvm enable fast-network)"; fi
fi

FEATURE=bridge
if [[ $BRIDGE == on ]]; then
  if running "$L_BRIDGE"; then
    a=$(listeners "$BRIDGE_PORT")
    if [[ " $a " == *" * "* || $a == *0.0.0.0* ]]; then bad "Bridge" "listens on every interface: $a"
    elif [[ " $a " == *" $HOST "* ]]; then ok "Bridge" "listening on $a"
    else bad "Bridge" "not listening on $HOST (only: ${a:-nothing})"; fi
  else bad "Bridge" "OmacVM Bridge is not running (src/mac/install.sh)"; fi
  T=$OMA_BRIDGE_SUPPORT/token
  if [[ -s $T ]]; then
    [[ $(stat -f %Lp "$T") == 600 ]] && ok "token" "private (600)" || bad "token" "readable by others: chmod 600"
    # The token only to this user's Bridge (on 127.0.0.1 any Mac program could
    # listen), and through a header file, never on a command line.
    bget() { curl -s -m 3 -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$T")") "http://$HOST:$BRIDGE_PORT$1"; }
    lsof -nP -a -u "$(id -u)" -c omacvm-bridge -iTCP@"$HOST":"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1 ||
      { bad "Bridge" "$HOST:$BRIDGE_PORT is not held by this user's OmacVM Bridge: token not sent"; bget() { :; }; }
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
  m=$(last_line "$BRIDGE_LOG" 'media keys: (event tap|waiting|cannot)')
  if [[ $(jq -r '.capture_keys == false' "$OMA_BRIDGE_SUPPORT/config.json" 2>/dev/null) == true ]]; then
    skip "media keys" "off: macOS keeps them (capture_keys false in config.json)"
  elif [[ -n $BRIDGE_OLD ]]; then
    warn "media keys" "not known: the running Bridge (pid $BRIDGE_OLD, started by macOS, not its LaunchAgent) writes no log; omacvm update starts one that does"
  else
    IFS=$'\t' read -r st d <<<"$(media_keys_state "$m")"
    case $st in ok) ok "media keys" "$d" ;; warn) warn "media keys" "$d" ;; *) bad "media keys" "$d" ;; esac
  fi
  # The Bridge says which permissions it has (at start and on each change).
  pm=$(last_line "$BRIDGE_LOG" 'omacvm-bridge: permissions: ')
  [[ -n $BRIDGE_OLD ]] && pm=old
  case $pm in
    "") ;;   # a Bridge from before it said so
    old) warn "Bridge permissions" "not known: the running Bridge (pid $BRIDGE_OLD) writes no log (started by macOS after a grant); omacvm update starts one that does" ;;
    *"Accessibility MISSING"*) bad "Bridge permissions" "Accessibility is off for OmacVM Bridge (the media keys need it): System Settings > Privacy & Security > Accessibility" human ;;
    *"Input Monitoring MISSING"*) warn "Bridge permissions" "Input Monitoring is off for OmacVM Bridge: the brightness keys do nothing with a VM in front (System Settings > Privacy & Security > Input Monitoring)" ;;
    *) ok "Bridge permissions" "${pm#permissions: }" ;;
  esac
  # Dimmer keyboard light steps (config.json); flicker is for a person to judge.
  c=$OMA_BRIDGE_SUPPORT/config.json
  if [[ $(last_line "$BRIDGE_LOG" 'keyboard light: ') == *none* ]]; then
    skip "keyboard light" "this Mac has none (Shift + brightness keys stay macOS's)"
  elif [[ $(jq -r '.keyboard_low_steps == false' "$c" 2>/dev/null) == true ]]; then
    skip "keyboard light" "macOS's 1/16 steps (keyboard_low_steps off in $c)"
  else ok "keyboard light" "4 steps below macOS's lowest (keyboard_low_steps in config.json; off if the keys flicker)"; fi
  # External displays: which ones the brightness keys set while the VM is on
  # them (DDC/CI, an Apple display's own control), and why not.
  # Asked only while the feature is on: the Bridge then reads each display over DDC/CI.
  FEATURE=external-brightness
  if [[ $(feat external_brightness on) != on ]]; then skip "external brightness" "off (omacvm enable external-brightness)"
  else
    ex=""; declare -F bget >/dev/null && ex=$(bget /display/external)
    if ! jq -e .displays <<<"$ex" >/dev/null 2>&1; then bad "external brightness" "the Bridge does not answer /display/external (omacvm update)"
    elif [[ $(jq -r .enabled <<<"$ex") != true ]]; then skip "external brightness" "off on this Mac (external_brightness in $c)"
    elif [[ $(jq '.displays | length' <<<"$ex") == 0 ]]; then skip "external brightness" "no external display connected"
    else
      while IFS=$'\t' read -r name method reason; do
        case $method in
          ddc) ok "brightness: $name" "DDC/CI: the brightness keys set it while the VM is in front on it" ;;
          apple) ok "brightness: $name" "its own control: the brightness keys set it while the VM is in front on it" ;;
          *) skip "brightness: $name" "not settable, $reason: the brightness keys stay as before there" ;;
        esac
      done < <(jq -r '.displays[] | [.name, .method, (.reason // "")] | @tsv' <<<"$ex")
    fi
  fi
  FEATURE=bridge
else skip "Bridge" "off (chosen at setup)"; fi
# The camera of UTM and Fusion VMs comes through the Bridge (also with its bar features off).
FEATURE=camera
if [[ $(feat camera off) == on && ( $TYPE == utm || $TYPE == fusion ) ]]; then
  running "$L_BRIDGE" && ok "camera (Bridge)" "OmacVM Bridge passes the Mac's camera" \
    || bad "camera (Bridge)" "OmacVM Bridge is not running (omacvm apply --vm \"$VM\")"
fi
[[ $(feat camera off) == off ]] && skip "camera" "off for this VM (chosen at setup)"
# The microphone: the VM's app records only with macOS's permission, and its
# recording helper cannot ask (docs/troubleshooting.md, finding 22). Its log says so.
FEATURE=""; miclog=""
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
  # The app restarts the desktop (and the shell) by itself (DesktopRecovery).
  restarts=$(grep -ac "restarting the VM's desktop by itself" "$miclog")
  again=""
  (( restarts > 0 )) && again="; the app restarted the desktop by itself $restarts time(s), closing the apps open in it"
  if [[ -n $lost ]]; then
    skip "GPU contexts" "lost earlier in this run by: $lost$again (an app that draws nothing needs a restart; the shell: omarchy-restart-shell)"
  else ok "GPU contexts" "no VM app lost its GPU context in this run"; fi
  # The VM's graphics memory on the Mac (on top of its VM memory): now and
  # the peak of this run from QEMU's status file (logs/gpu-memory, written
  # while the VM runs), else the peak QEMU's log has (512 MB steps). Refused
  # only past the runaway budget or when macOS itself was short of memory.
  FEATURE=gpu-memory   # the control centre's Graphics memory row (only there)
  gm="$(dirname "$miclog")/gpu-memory"
  gmv() { sed -n "s/^$1=//p" "$gm" 2>/dev/null | head -1; }
  gb() { awk -v m="$1" 'BEGIN { printf (m < 1024 ? "%d MB" : "%.1f GB"), (m < 1024 ? m : m / 1024) }'; }
  budget=$(grep -o 'guest GPU memory budget: [0-9]* MB' "$miclog" | tail -1 | grep -o '[0-9]*')
  if [[ -s $gm && -n $(gmv in_use_mb) ]]; then
    use=$(gmv in_use_mb) peak=$(gmv peak_mb) refused=$(gmv refused) pressure=$(gmv pressure)
    what="$(gb "$use") now (peak $(gb "$peak")), from the Mac on top of the VM memory; macOS memory pressure $pressure"
    # 3.0.5: the guard's last part is the desktop's (virgl-gpu-guard-desktop-reserve.patch).
    reserve=$(gmv reserve_mb)
    [[ ${reserve:-0} != 0 ]] && what="$what; apps up to $(gb "$(gmv apps_mb)"), the last $(gb "$reserve") kept for the desktop"
    if (( ${refused:-0} > 0 )); then
      bad "graphics memory" "$what; $refused allocation(s) refused this run ($(grep -o -e 'budget of [0-9]* MB reached' -e "apps' share of [0-9]* MB reached" -e 'macOS is short of memory' -e "past the apps' share" "$miclog" | sort -u | paste -sd, - | sed 's/,/, /g')): an app may have lost its GPU context"
    else ok "graphics memory" "$what"; fi
  elif [[ -n $budget ]]; then
    peak=$(grep -o 'guest GPU memory in use: [0-9]* MB' "$miclog" | tail -1 | grep -o '[0-9]*')
    if grep -q -e 'guest GPU memory budget of [0-9]* MB reached' -e "apps' share of [0-9]* MB reached" -e 'macOS is short of memory' "$miclog"; then
      bad "graphics memory" "refused this run (budget $budget MB or macOS short of memory): an app may have lost its GPU context (restart the VM)"
    else ok "graphics memory" "${peak:+peak about $(gb "$peak"), }no fixed limit (runaway guard $(gb "$budget"))"; fi
  fi
  FEATURE=""
fi
# The GPU path an app VM took this run (qemu.log starts fresh with each run):
# fences from the sync thread or polled, frames as IOSurfaces or with a
# CAOpenGLLayer. GPU safe mode takes the old path on purpose; without it the
# old path is a fallback (still works, slower), and qemu.log says why.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  fences=$(grep -o 'virgl fences .*' "$miclog" | tail -1)
  frames=$(grep -o 'GL frames shown .*' "$miclog" | tail -1)
  if [[ -n $fences$frames ]]; then
    g="fences ${fences#virgl fences }, frames ${frames#GL frames shown }"
    if [[ $fences == *"did not start"* ]] || grep -q 'IOSurface present failed' "$miclog"; then
      bad "GPU path" "$g: a fallback (logs/qemu.log says why)"
    elif [[ $(defaults read org.omacvm.app gpuSafeMode 2>/dev/null) == 1 ]]; then
      ok "GPU path" "$g (GPU safe mode)"
    else ok "GPU path" "$g"; fi
  fi
fi
# OmacVM.app's Graphics setting: what this start got (the app says so in
# qemu.log), and whether the next start gets something else.
if [[ $TYPE == app ]] && gd=$(app_dir "$VM" 2>/dev/null); then
  FEATURE=graphics
  gl=$(sed -n 's/^OmacVM: graphics: //p' "$gd/logs/qemu.log" 2>/dev/null | tail -1)
  gc=$(graphics_choice "$gd"); gn=$(graphics_next_start "$gd"); gs=$(graphics_summary "$gd")
  if [[ -z $gl ]]; then
    skip "Graphics" "$(graphics_title "$gc"): $gs from the VM's next start (an app from before 3.0.0 has OpenGL only)"
  elif gf=$(graphics_fallback "$gd") && [[ $(graphics_wants "$gd") == vulkan ]]; then
    # Vulkan fell back and stays off until chosen again (graphics-fallback).
    # Choosing the same setting again clears it (graphics.sh), whatever it is.
    warn "Graphics" "$GRAPHICS_DID_NOT_START ($gf; choose the setting again to try Vulkan once more: omacvm graphics --vm \"$VM\" $gc)"
  elif [[ $gl == *"(${GRAPHICS_DID_NOT_START%%:*}"* ]]; then
    # Vulkan fell back for this start only; the next start tries it again.
    warn "Graphics" "this start: $gl"
  elif [[ ${gl%% *} != "$gc" || $gl != *"-> $gn "* ]]; then
    skip "Graphics" "this start: $gl; $(graphics_title "$gc") gives $gs from the VM's next start"
  elif graphics_waiting_for_driver "$gd"; then
    [[ $gc == auto ]] && gs="OpenGL until the VM has its Vulkan driver"
    skip "Graphics" "$(graphics_title "$gc"): $gs (omacvm apply, or omacvm graphics --vm \"$VM\" $gc while it runs)"
  else ok "Graphics" "$(graphics_title "$gc"): $gl"; fi
  FEATURE=""
fi
# Vulkan in an app VM (Graphics Vulkan): the Mac driver QEMU picked
# this run (qemu.log starts fresh with each run). KosmicKrisp falls back to
# MoltenVK when it cannot run.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  FEATURE=graphics
  v=$(grep -o 'vulkan driver: .*' "$miclog" | tail -1)
  case $v in
    "") ;;
    *kosmickrisp*) ok "Vulkan (Venus)" "KosmicKrisp" ;;
    *MoltenVK*)
      if grep -q 'unusable, trying MoltenVK' "$miclog"; then
        warn "Vulkan (Venus)" "MoltenVK: KosmicKrisp could not run on this Mac, Vulkan has fewer features (logs/qemu.log says why)"
      else ok "Vulkan (Venus)" "MoltenVK"; fi ;;
    *) ok "Vulkan (Venus)" "${v#vulkan driver: }" ;;
  esac
  FEATURE=""
fi
# macOS's own shortcuts while an app VM has the keyboard (this run): to the
# VM (switched off meanwhile), kept by the user's choice, or a fallback.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  if grep -q 'macOS shortcuts stay with macOS' "$miclog"; then
    skip "macOS shortcuts" "stay with macOS (the default; experimental, all to the VM: defaults write org.omacvm.app macShortcuts -bool false)"
  elif grep -q "macOS's switch for them was not found\|macOS shortcuts .*FAILED" "$miclog"; then
    warn "macOS shortcuts" "some stay with macOS: macOS refused to switch them off (logs/qemu.log)"
  elif grep -q 'macOS shortcuts off' "$miclog"; then
    ok "macOS shortcuts" "go to the VM while it has the keyboard (⌃⌥ Esc is macOS's)"
  fi
  # QEMU's keyboard tap (⌘ Tab, ⌘ Space, ⌘ ⇧ 4 to the VM) is an active tap:
  # OmacVM needs Accessibility ("control the computer"; Input Monitoring is
  # not enough); without it QEMU says so once at the start. An old
  # "control the computer" entry (an earlier build's signature) refuses
  # whatever the Accessibility switch shows.
  if grep -q 'Could not create event tap' "$miclog"; then
    warn "VM keyboard" "macOS refused OmacVM's key tap: ⌘ Tab, ⌘ Space, ⌘ ⇧ 4 can go to macOS. Allow… in OmacVM.app's window (it clears what macOS kept for an older build: OmacVM can show as on under Accessibility and still not count), or: tccutil reset PostEvent org.omacvm.app, then System Settings › Privacy & Security › Accessibility: OmacVM on; restart the VM"
  fi
fi
# The globe key on its own (3.0.1): to the VM while it has the keyboard.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  if grep -q 'globe key stays with macOS' "$miclog"; then
    skip "globe key" "stays with macOS (defaults write org.omacvm.app globeKeyToVM -bool false)"
  elif grep -q "globe key: macOS's switch for its shortcut was not found\|globe key .*FAILED" "$miclog"; then
    warn "globe key" "opens macOS's Emoji & Symbols: macOS refused to switch its shortcut off (logs/qemu.log)"
  elif grep -q 'globe key goes to the VM' "$miclog"; then
    ok "globe key" "goes to the VM while it has the keyboard (Omarchy's emoji picker)"
  fi
fi
# Sound on a busy Mac: QEMU's main loop (the sound card's timers) at
# user-interactive QoS, and the sound card paced (no catch-up after a stall);
# the hidden audioClassic setting keeps QEMU's own timing for both.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  q=$(grep -o 'main loop QoS: .*' "$miclog" | tail -1)
  p=$(grep -o 'HDA sound pacing [a-z]*' "$miclog" | tail -1)
  case "$q|$p" in
    "|") ;;   # a runtime before 3.0.0 says nothing
    *refused*) warn "sound timing" "macOS refused user-interactive QoS: sound may crackle while the Mac is busy" ;;
    *user-interactive"|HDA sound pacing on") ok "sound timing" "QEMU's main loop at user-interactive QoS, sound card paced" ;;
    *"|HDA sound pacing off") ok "sound timing" "QEMU's own sound timing (audioClassic)" ;;
    *) ok "sound timing" "${q:-main loop QoS: unknown}, ${p:-pacing unknown}" ;;
  esac
fi
# A Mac audio device that does not answer (coreaudiod stuck): QEMU opens it off
# its main loop and the VM runs without sound instead of hanging; qemu.log says
# so, and when the device works again.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  case $(grep -o "OmacVM: sound: the Mac's audio device [a-z ]*" "$miclog" | tail -1) in
    *"does not answer"*) warn "sound" "Mac audio device not answering, the VM runs without sound; fix: pick another output in System Settings > Sound, replug it, or sudo killall coreaudiod" ;;
    *"works again"*) ok "sound" "the Mac's audio device stopped answering earlier in this run and works again" ;;
  esac
fi
# The Mac folder (the app's setting, off by default): what this start shared,
# and whether the VM has it at ~/Mac.
if [[ $TYPE == app && -n $miclog && -f $miclog ]]; then
  mf=$(sed -n 's/^OmacVM: Mac folder: //p' "$miclog" | tail -1)
  case $mf in
    ""|off) ;;   # off, or an app from before the setting
    "off this start: "*) warn "Mac folder" "${mf#off this start: }" ;;
    *)
      if gssh "$IP" "mountpoint -q ~$U/Mac" < /dev/null 2>/dev/null; then ok "Mac folder" "$mf"
      else bad "Mac folder" "shared, but not at ~/Mac in the VM (omacvm apply installs omacvm-mac-folder; then restart the VM)"; fi ;;
  esac
fi
FEATURE=gestures
# With gestures off the VM's daemon is off too (also on UTM, Fusion and
# OmacVM.app), so this VM needs no Gestures on the Mac.
if [[ $GESTURES == on ]]; then
  if running "$L_GESTURES"; then
    a=$(listeners "$GESTURES_PORT")
    IFS=$'\t' read -r gst gmiss <<<"$(gestures_state "$GESTURES_LOG")"
    if [[ " $a " == *" $HOST "* ]]; then ok "Gestures" "listening on $a"
    # Running, but waiting at start for a permission: it listens by itself once
    # that is granted (#330).
    elif [[ $gst == waiting ]]; then
      bad "Gestures" "running, but waiting for $gmiss permission (System Settings > Privacy & Security > $gmiss > OmacVM Gestures); it starts listening by itself once allowed" human
    else bad "Gestures" "not listening on $HOST (only: ${a:-nothing})"; fi
    # A VM last updated with OmacVM 2.3 or older: its daemon has no token, so
    # Gestures refuses it (and it tries again every 2 s) until it is updated.
    if [[ $TYPE != app ]]; then
      r=$(grep -nF "omacvm-gestures: refused ${IP%:*} on " "$GESTURES_LOG" 2>/dev/null | grep -F ": no token" | tail -1 | cut -d: -f1)
      c=$(grep -nF "omacvm-gestures: guest connected: ${IP%:*} " "$GESTURES_LOG" 2>/dev/null | tail -1 | cut -d: -f1)
      (( ${r:-0} > ${c:-0} )) &&
        bad "Gestures for this VM" "refused: its trackpad daemon is from OmacVM 2.3 or older (omacvm update --vm \"$VM\")"
    fi
    keysonly=$(ps -o args= -p "$GESTURES_PID" 2>/dev/null | grep -c -- '--keys-only')
    if [[ $GESTURES == on && $keysonly != 0 ]]; then
      bad "trackpad gestures" "OmacVM Gestures runs keys-only on this Mac: src/mac/install.sh turns gestures back on"
    fi
    # A Mac mini, iMac or Studio may have no trackpad yet: the helper waits for one.
    if [[ $GESTURES == on && $keysonly == 0 ]]; then
      t=$(last_line "$GESTURES_LOG" 'no trackpad found|trackpad: ')
      case $t in
        "no trackpad"*) skip "trackpad" "none connected: the swipes start when a Magic Trackpad connects" ;;
        trackpad:*) ok "trackpad" "${t#trackpad: }" ;;
      esac
    fi
    if [[ $GESTURES == on && $GLIDE == on ]]; then
      FEATURE=scroll-momentum
      # OmacVM.app's VMs all connect from 127.0.0.1: this VM's own line first.
      g=$(grep "guest connected: ${IP%:*} " "$GESTURES_LOG" 2>/dev/null | grep -F "VM \"$VM\")" | tail -1)
      [[ -n $g ]] || g=$(grep "guest connected: ${IP%:*} " "$GESTURES_LOG" 2>/dev/null | tail -1)
      if [[ $g == *"scroll momentum on"* || $g == *"Glide on"* ]]; then ok "scroll momentum (Mac)" "on (trackpad only): a trackpad's scrolling goes to this VM in full screen, mice scroll one to one"
      elif [[ $(last_line "$GESTURES_LOG" 'omacvm-gestures: permissions: ') == *MISSING* ]]; then
        bad "scroll momentum (Mac)" "OmacVM Gestures waits for its Mac permissions (keyboard/trackpad access below); omacvm apply does not change them"
      else bad "scroll momentum (Mac)" "the helper does not scroll for this VM yet (omacvm apply --vm \"$VM\")"; fi
      FEATURE=gestures
    fi
    # The helper listens only once it has its permissions, so a later
    # "listening" line overrides a "waiting" one (e.g. a restart while waiting).
    # Gestures says which of its two permissions it has (at start and on each
    # change); one from before that: its older lines.
    p=$(last_line "$GESTURES_LOG" 'omacvm-gestures: permissions: ')
    if [[ -n $GESTURES_OLD ]]; then
      warn "keyboard/trackpad access" "not known: the running Gestures (pid $GESTURES_OLD, started by macOS, not its LaunchAgent) writes no log; omacvm update starts one that does"
    elif [[ $p == *MISSING* ]]; then
      miss=$(sed -E 's/^permissions: //; s/[A-Za-z ]+ granted(, )?//g; s/ MISSING//g; s/[, ]+$//' <<<"$p")
      # On in System Settings and still refused: an entry macOS kept for an
      # older build (#306). The helper clears its own once per build; by hand:
      bad "keyboard/trackpad access" "$miss off for OmacVM Gestures (the escape combo and gestures need it): System Settings > Privacy & Security. On there and still off: tccutil reset Accessibility $L_GESTURES; tccutil reset ListenEvent $L_GESTURES; launchctl kickstart -k gui/$(id -u)/$L_GESTURES, then allow it again" human
    elif [[ -n $p ]]; then ok "keyboard/trackpad access" "Accessibility + Input Monitoring"
    else
      p=$(last_line "$GESTURES_LOG" 'permission|listening on')
      [[ -z $p || $p == *granted* || $p == listening* ]] && ok "keyboard/trackpad access" "Accessibility + Input Monitoring" \
        || bad "keyboard/trackpad access" "${p}: System Settings > Privacy & Security" human
    fi
  else bad "Gestures" "OmacVM Gestures is not running (src/mac/install.sh)"; fi
else FEATURE=gestures; skip "Gestures" "trackpad gestures off (chosen at setup)"; fi
FEATURE=battery
# The Mac's battery: the Bridge serves it to UTM and Fusion VMs, OmacVM.app
# passes it on its own port; Parallels gives the VM its own.
if [[ $(feat battery off) == on && $TYPE != parallels ]]; then
  if [[ $TYPE == app ]]; then
    pid=$(app_pid_dir "$(app_dir "$VM")" 2>/dev/null)
    if [[ -n $pid ]] && ps -o args= -p "$pid" | grep -q 'name=org.omacvm.battery'; then ok "battery (Mac)" "OmacVM.app passes it (virtio port)"
    else bad "battery (Mac)" "this OmacVM.app does not pass the battery: omacvm update, then shut the VM down and start it again"; fi
  elif ! running "$L_BRIDGE"; then
    bad "battery (Mac)" "OmacVM Bridge is not running: it serves the battery to $TYPE VMs (omacvm apply)"
  else
    T=$OMA_BRIDGE_SUPPORT/token b=""
    # The token only to this user's Bridge (as above).
    if [[ -s $T ]] && lsof -nP -a -u "$(id -u)" -c omacvm-bridge -iTCP@"$HOST":"$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      b=$(curl -s -m 3 -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$T")") "http://$HOST:$BRIDGE_PORT/battery")
    fi
    case $(jq -r '.present | tostring' <<<"$b" 2>/dev/null) in
      true) ok "battery (Mac)" "the Bridge serves it: $(jq -r '"\(.percentage) %, \(.state)"' <<<"$b")" ;;
      false) skip "battery (Mac)" "this Mac has no battery" ;;
      *) bad "battery (Mac)" "the Bridge does not answer /battery (older than the battery: omacvm update)" ;;
    esac
  fi
fi
[[ $(feat battery off) == off && $TYPE != parallels ]] && skip "battery (Mac)" "off for this VM (chosen at setup)"
FEATURE=""
# macOS's "Automatically hide and show the menu bar: Never" keeps the Mac's
# menu bar over the full-screen VM: a hint (it is the person's setting).
if [[ $(defaults read NSGlobalDomain AppleMenuBarVisibleInFullscreen 2>/dev/null) == 1 ]]; then
  skip "menu bar in full screen" "macOS always shows it: System Settings > Menu Bar (older macOS: Control Center) > Automatically hide and show the menu bar: In Full Screen Only" human
else ok "menu bar in full screen" "hidden by macOS"; fi
case $TYPE in
parallels)
  running "$L_CLIP" && ok "clipboard VM -> Mac" "$L_CLIP" || bad "clipboard VM -> Mac" "$L_CLIP not running"
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
  # UTM's settings are in its container (lib/mac.sh utm_data): a read that
  # macOS holds back says so instead of failing.
  v=$(utm_data defaults read com.utmapp.UTM QEMUVulkanDriver 2>/dev/null); rc=$?
  if (( rc > 128 )); then skip "UTM speed settings" "$UTM_UNREADABLE_HINT" human
  elif [[ $v == 1 ]]; then ok "UTM speed settings" "no Vulkan driver (fast page size)"
  else bad "UTM speed settings" "QEMUVulkanDriver is not 1: omacvm build sets it, or run defaults write com.utmapp.UTM QEMUVulkanDriver -int 1; restart UTM after"; fi
  case $(utm_data defaults read com.utmapp.UTM QEMURendererBackend 2>/dev/null || echo 0) in
    0|2) ok "UTM renderer" "ANGLE on Metal (GPU in Chrome)" ;;
    *) bad "UTM renderer" "Chrome gets no GPU: UTM › Settings › Display › Renderer Backend: Default, then restart UTM" ;;
  esac ;;
esac
FEATURE=omanotch
# OmacVM.app's FullPanel start (src/lib/notch.sh): the VM draws the strip
# itself, so Omanotch has nothing to do for it.
fp_start=0
[[ $TYPE == app ]] && fp_dir=$(app_dir "$VM" 2>/dev/null) && notch_fullpanel_this_start "$fp_dir" && fp_start=1
if [[ $(feat omanotch off) == off ]]; then
  skip "Omanotch" "off for this VM (chosen at setup)"
elif (( fp_start )); then
  ok "Omanotch (Mac)" "not needed (full screen including notch): this start of the VM has no link to Omanotch"
elif pgrep -xq omanotch; then
  # Omanotch's own setting (defaults write ch.gillesgoetsch.omanotch flush -bool true|false).
  [[ $(defaults read ch.gillesgoetsch.omanotch flush 2>/dev/null) == 1 ]] && h="the notch's (flush)" || h="the menu bar's"
  ok "Omanotch (Mac)" "running, bar height: $h"
elif [[ ${notch:=$(mac_tool mac-notch 2>/dev/null || echo none)} != notch ]]; then skip "Omanotch (Mac)" "no notch on this Mac"
else skip "Omanotch (Mac)" "not running (omacvm update)"; fi
if [[ $TYPE == app && $(feat omanotch off) == on ]] && (( ! fp_start )); then
  rc=0; omanotch_serves_app || rc=$?
  (( rc != 1 )) || bad "Omanotch for OmacVM.app" "too old: it does not serve 127.0.0.1, so this VM's strip stays empty (omacvm update)"
  if (( rc == 0 )) && [[ $FAST_NET == on ]]; then
    rc=0; omanotch_serves_fast_network || rc=$?
    (( rc != 1 )) || bad "Omanotch for OmacVM.app" "too old for the fast network: it does not listen on 192.168.77.1, so this VM's strip stays empty (omacvm update)"
  fi
fi
# Touch ID (ADR 0041), the Mac's side: what a prompt needs here, one line
# that says what is missing (the VM's side: its own check).
FEATURE=touch-id
if [[ $(feat touch_id off) == on ]]; then
  tk=""; [[ -n ${VM:-} ]] && tk="$(vm_key_file "$TYPE" "$VM").touchid"
  tm=""
  if [[ -z $tk ]]; then tm="no VM name (--ip): the Mac keeps Touch ID keys by VM name (omacvm apply --vm NAME)"
  elif [[ ! -s $tk ]]; then tm="no Touch ID key for this VM on the Mac: omacvm apply --vm NAME makes it, or omacvm enable touch-id"
  elif ! running "$L_BRIDGE"; then tm="OmacVM Bridge is not running, and it asks the Mac's Touch ID: omacvm update"
  elif [[ $TYPE == app && ! -S $OMA_BRIDGE_SUPPORT/relay.sock ]]; then tm="OmacVM Bridge has no socket for OmacVM.app's requests: omacvm update"
  fi
  # The last request the Bridge logged for this VM (never what it was for).
  tl=$(grep -F "touchid: from " "$BRIDGE_LOG" 2>/dev/null | grep -F "(${VM:-?}): " | tail -1)
  [[ -z $tl ]] || tl="; last request ${tl:11:5}: ${tl##*): }"
  tn=$(bioutil -c 2>/dev/null | sed -n 's/.*:[[:space:]]*\([0-9][0-9]*\) biometric.*/\1/p' | head -1)
  tp=0; [[ $TYPE == app ]] && td=$(app_dir "$VM" 2>/dev/null) && { app_touchid_port "$td" || tp=$?; }
  if [[ -n $tm ]]; then bad "Touch ID (Mac)" "$tm"
  elif (( tp == 1 )); then
    # Started by OmacVM.app 3.0.3 or older, which added the port only with touch-id on at the start.
    skip "Touch ID (Mac)" "on from the VM's next start: shut it down, then start it again (OmacVM.app adds its Touch ID port at the start)" human
  elif [[ $tn == 0 ]]; then
    bad "Touch ID (Mac)" "no fingerprint in this Mac's Touch ID (or no sensor): System Settings › Touch ID & Password; until then the VM asks for the password" human
  else ok "Touch ID (Mac)" "the VM's key, OmacVM Bridge$( [[ -n $tn ]] && echo " and $tn fingerprint(s)") ready$tl"; fi
fi
FEATURE=omanotch   # the Mac links row below, as before
# OmacVM.app: what of the Mac this start of the VM may use (the app reads
# the VM's features at start and says so in qemu.log). A feature that is off
# must get nothing; one switched on while the VM runs waits for its next start.
if [[ $TYPE == app ]] && d=$(app_dir "$VM" 2>/dev/null); then
  l=$(sed -n 's/^OmacVM: Mac links: //p' "$d/logs/qemu.log" 2>/dev/null | tail -1)
  if [[ -z $l ]]; then
    skip "Mac links (app)" "this OmacVM.app serves every feature to every VM (older than 3.0.0: omacvm update)"
  else
    fs=$(for k in omanotch gestures bridge battery camera; do printf '%s=%s ' "$k" "$(feat "$k" on)"; done)
    open=$(app_links_stale "$d" "$fs" off) closed=$(app_links_stale "$d" "$fs" on)
    m=""
    [[ -z $open ]] || m="off for this VM, but the app still serves it: $open"
    [[ -z $closed ]] || m+="${m:+; }on, but closed to the VM since its start: $closed"
    # Touch ID is not one of these (its own "Touch ID (Mac)" row): the line's
    # "Touch ID off" is only how it was at the start, and it may be on now.
    lv=", $l, "; lv=${lv//, Touch ID port on, /, }; lv=${lv//, Touch ID on, /, }; lv=${lv//, Touch ID off, /, }
    lv=${lv#, }; lv=${lv%, }
    if [[ -n $m ]]; then bad "Mac links (app)" "$m (shut the VM down and start it again)"
    else ok "Mac links (app)" "$lv"; fi
  fi
fi
# OmacVM.app's USB devices (off by default, docs/usb.md): the switch at this
# start, the devices the VM has now (the app logs each connect and
# disconnect), and one the user wanted that macOS or a Mac app had. Per
# device the last line counts.
if [[ $TYPE == app ]] && d=$(app_dir "$VM" 2>/dev/null); then
  u=$(sed -n 's/^OmacVM: USB devices: //p' "$d/logs/qemu.log" 2>/dev/null | tail -1)
  usb_now=$(awk '
    /^OmacVM: USB: [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]/ {
      l = substr($0, 14)
      if (match(l, / connected \(/)) { k = substr(l, 1, RSTART - 1); s[k] = "on"; if (!(k in o)) { o[k] = ++n; ks[n] = k } }
      else if (match(l, / (disconnected|kept on the Mac|not connected)/)) {
        k = substr(l, 1, RSTART - 1); s[k] = (l ~ /not connected: in use on the Mac/) ? "busy" : "off"
        if (!(k in o)) { o[k] = ++n; ks[n] = k }
      }
    }
    END {
      for (i = 1; i <= n; i++) { k = ks[i]; if (s[k] == "on") on = on (on ? ", " : "") k; if (s[k] == "busy") b = b (b ? ", " : "") k }
      print on "|" b
    }' "$d/logs/qemu.log" 2>/dev/null)
  if [[ -n $u && $u != off ]]; then
    m="$u"
    [[ -n ${usb_now%%|*} ]] && m+="; with the VM now: ${usb_now%%|*}"
    if [[ -n ${usb_now#*|} ]]; then warn "USB devices (app)" "$m; a Mac app had ${usb_now#*|}: not connected (docs/usb.md)"
    else ok "USB devices (app)" "$m"; fi
  fi
fi
FEATURE=""
if [[ $TYPE == app ]]; then
  # OmacVM.app's full screen is macOS's own, in its own Space. Native: below
  # the notch, Omanotch fills the strip beside it. FullPanel (experimental,
  # src/lib/notch.sh): QEMU's window covers the strip and the VM's bar sits
  # there; QEMU logs "strip covered" once it has it, "strip lost" or "using
  # normal full screen" when it fell back.
  nd=$(app_dir "$VM" 2>/dev/null) || nd=""
  nmode=native; [[ -n $nd ]] && nmode=$(notch_choice "$nd")
  nlast=""; [[ -n $nd ]] && nlast=$(notch_this_start "$nd")
  if (( fp_start )); then
    nq=$(grep -E '^omacvm: full panel: (strip covered|strip lost|.*normal full screen)' "$nd/logs/qemu.log" 2>/dev/null | tail -1)
    nq=${nq#omacvm: full panel: }
    case $nq in
      "strip covered"*) ok "full screen (app)" "including notch (experimental): $nq; Omanotch idle" ;;
      "strip lost"*) warn "full screen (app)" "including notch set, but macOS moved the window below the notch: normal full screen until the next one ($nq)" ;;
      "") skip "full screen (app)" "including notch this start, not in full screen on the MacBook's display yet" ;;
      *) warn "full screen (app)" "including notch set, but QEMU uses normal full screen: $nq" ;;
    esac
  elif [[ ${notch:=$(mac_tool mac-notch 2>/dev/null || echo none)} != notch && $nmode != fullpanel ]]; then skip "full screen (app)" "no notch on this Mac"
  elif [[ $nmode == fullpanel ]]; then
    full=0; notch_app_full_screen && full=1
    skip "full screen (app)" "including notch is set; this start: ${nlast:-not known}; next start: $(notch_next_start "$nd" "$notch" "$full")"
  elif [[ $(feat omanotch off) == on ]]; then skip "full screen (app)" "notch via Omanotch: full screen in its own Space, Omanotch fills the strip"
  else skip "full screen (app)" "notch via Omanotch: full screen in its own Space; the strip stays black (Omanotch is off for this VM: omacvm enable omanotch)"; fi
fi
(( fails )) && mac_failed=1 || mac_failed=0
if (( MAC_ONLY )); then
  (( JSON )) && json_out "$( (( mac_failed )) && echo false || echo true)"
  (( ! mac_failed )); exit
fi

if (( JSON )); then
  out=$(gssh "$IP" "bash -s -- --user '$U' --tsv" < "$R/src/guest/check.sh"); guest=$?
  while IFS=$US read -r a b c d e; do
    if [[ $a == section ]]; then SECTION="VM: $b"
    elif [[ -n $a ]]; then ROWS+="$a$US$SECTION$US$b$US$c$US$d$US$e"$'\n'; fi
  done < <(tr '\t' '\037' <<<"$out")
  json_out "$( (( guest == 0 && ! mac_failed )) && echo true || echo false)"
  (( guest == 0 && ! mac_failed )); exit
fi
echo
echo "VM '$VM' at $IP"
gssh "$IP" "bash -s -- --user '$U'" < "$R/src/guest/check.sh"
guest=$?
(( mac_failed )) && echo "(and $fails check(s) failed on the Mac)"
(( guest == 0 && ! mac_failed ))
