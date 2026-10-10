#!/bin/bash
# OmacVM, guest side check: is every feature in place and working right now?
# Run as root inside the VM while the desktop user is logged in (check.sh on
# the Mac does that over SSH):
#   guest/check.sh --user NAME [--tsv]
# One line per feature (ok / FAIL / skip); exits 1 if anything failed. --tsv:
# "status<TAB>name<TAB>detail<TAB>human<TAB>feature" lines (human = 1: only a
# person can fix it; feature = the features.tsv name the line belongs to, empty
# for the VM in general) and "section<TAB>title", for omacvm check --json and
# the control centre.
set -uo pipefail
U=""; TSV=0
while (( $# )); do
  case $1 in
    --user) U=$2; shift 2 ;;
    --tsv) TSV=1; shift ;;
    *) echo "usage: guest/check.sh --user NAME [--tsv]" >&2; exit 2 ;;
  esac
done
id "$U" >/dev/null 2>&1 || { echo "guest/check.sh: --user must be the desktop user" >&2; exit 2; }
H=$(getent passwd "$U" | cut -d: -f6); RUN=/run/user/$(id -u "$U")
fails=0; FEATURE=""   # the feature the next lines belong to
line() {   # STATUS LABEL NAME DETAIL [human]
  if (( TSV )); then printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$3" "$4" "${5:+1}" "$FEATURE"
  else printf '  %-5s %-24s %s\n' "$2" "$3" "$4"; fi
}
ok()   { line ok ok "$1" "${2:-}"; }
bad()  { line fail FAIL "$1" "${2:-}" "${3:-}"; fails=$((fails + 1)); }
skip() { line skip skip "$1" "${2:-}" "${3:-}"; }
# check NAME DETAIL COMMAND...: ok if the command succeeds
check() { local n=$1 d=$2; shift 2; if "$@" >/dev/null 2>&1; then ok "$n" "$d"; else bad "$n" "$d"; fi; }
section() { if (( TSV )); then printf 'section\t%s\n' "$1"; else printf '%s\n' "$1"; fi; }
# In the desktop user's session, with Omarchy's and Hyprland's environment.
as_user() {
  local sig; sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -1)
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="$RUN" WAYLAND_DISPLAY=wayland-1 \
    HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
user_active() { systemctl --user -M "$U@" is-active "$1" >/dev/null 2>&1; }
connected_to() { ss -Htn state established "dst $1:$2" | grep -q .; }
ev_device() { grep -q "^N: Name=\"$1\"" /proc/bus/input/devices; }
# missing_pkgs PKG...: why a feature is not set up when pacman could not
# install what it needs ("" when all are there). On a VM whose package list
# is older than the mirrors every download is a 404 (guest/pkg-add exit 3):
# another apply does not help, a whole system update does (2026-10-08: camera
# and Chromium video said "omacvm apply" on a 2.9.1 VM after its update).
missing_pkgs() {
  local m; m=$(pacman -T "$@" 2>/dev/null | paste -sd' ' -)
  [[ -z $m ]] || echo "$m not installed (an old package list?): update the system with omarchy update, then r on this row (omacvm apply)"
}

[[ -r /etc/omacvm/env ]] || { bad "OmacVM guest side" "not installed (run omacvm apply on the Mac)"; exit 1; }
source /etc/omacvm/env
HOST=$OMACVM_HOST; TYPE=$OMACVM_VM_TYPE
# The VM's default gateway, as Gestures' default_gateway() picks it: the
# lowest metric among default routes whose card has a link. After the app
# switches networks the old card's route stays listed (first) for seconds.
SYS_NET=/sys/class/net
default_gateway() {
  local m via dev c
  ip -4 route show default 2>/dev/null |
    awk '{ v = d = ""; m = 0
           for (i = 1; i < NF; i++) { if ($i == "via") v = $(i + 1); if ($i == "dev") d = $(i + 1); if ($i == "metric") m = $(i + 1) }
           if (v != "") print m, v, d }' |
    while read -r m via dev; do
      c=$(cat "$SYS_NET/$dev/carrier" 2>/dev/null) || c=1   # no carrier to read: count it
      if [[ $c == 1 ]]; then echo "$m $via"; fi
    done | sort -n | awk '{ print $2; exit }'
}
# OmacVM.app on its fast network (vmnet): the Mac is the gateway 192.168.77.1.
GW=$(default_gateway)
[[ $TYPE == app && $GW == 192.168.77.1 ]] && HOST=$GW
# OmacVM.app gives the VM a feature's link to the Mac only when the VM starts
# (its port, or the battery/camera port): one turned on while the VM ran waits
# for the next start. "port": a port on the Mac's 127.0.0.1, which the fast
# network does not gate.
restart_hint() {
  [[ $TYPE == app ]] || return 0
  [[ ${1:-} == port && $HOST == 192.168.77.1 ]] && return 0
  printf '; turned on while the VM was running? shut it down and start it again'
}
# Where Omanotch's hidden NOTCH output sits next to the built-in display $2,
# from `hyprctl monitors all -j` ($1); $3 is the VM type. Prints "over" (on
# the display's top edge: Parallels, UTM, Fusion, and the app's fallback),
# "above" (right above it, touching its top edge: OmacVM.app, notchcast's
# notch-place.h) or nothing when NOTCH is anywhere else.
notch_spot() {
  jq -r --arg b "$2" --arg t "$3" '
    (.[] | select(.name == "NOTCH")) as $n | (.[] | select(.name == $b)) as $m
    | ($n.y + $n.height / $n.scale - $m.y) as $gap
    | if $n.x != $m.x or $n.width != $m.width then empty
      elif $n.y == $m.y then "over"
      elif $t == "app" and $gap > -1 and $gap < 1 then "above"
      else empty end' <<<"$1" 2>/dev/null | head -1
}
FAST_NET=${OMACVM_FEATURE_fast_network:-off}
# Features chosen at setup (VMs set up before the choices existed: the defaults
# they were built with).
BRIDGE=${OMACVM_FEATURE_bridge:-on}; WALLPAPER=${OMACVM_FEATURE_wallpaper:-on}
GESTURES=${OMACVM_FEATURE_gestures:-on}
# no-idle-lock was idle-lock before 3.0.1, on and off the other way round.
NO_IDLE_LOCK=${OMACVM_FEATURE_no_idle_lock:-$( [[ ${OMACVM_FEATURE_idle_lock:-on} == off ]] && echo on || echo off)}
THP_KERNEL=${OMACVM_FEATURE_thp_kernel:-}; AUTOLOGIN=${OMACVM_FEATURE_autologin:-}
GLIDE=${OMACVM_FEATURE_scroll_momentum:-${OMACVM_FEATURE_glide:-off}}; OMANOTCH=${OMACVM_FEATURE_omanotch:-}
CONTROL=${OMACVM_FEATURE_control_centre:-off}
MAC_CLOCK=${OMACVM_FEATURE_mac_clock:-off}; CAMERA=${OMACVM_FEATURE_camera:-off}; BATTERY=${OMACVM_FEATURE_battery:-off}
EXT_BRIGHTNESS=${OMACVM_FEATURE_external_brightness:-off}
TOUCH_ID=${OMACVM_FEATURE_touch_id:-off}
CHROMIUM_VIDEO=${OMACVM_FEATURE_chromium_video:-on}

section "Session ($TYPE VM, the Mac is $HOST)"
if pgrep -u "$U" -x Hyprland >/dev/null; then ok "Hyprland" "running for $U"
else bad "Hyprland" "not running for $U: log in first, the checks below need the session"; fi
check "Omarchy shell" "answers" as_user omarchy-shell shell ping
mon=$(as_user hyprctl monitors -j 2>/dev/null | jq -r 'max_by(.width * .height) | "\(.width)x\(.height)@\(.refreshRate | round) scale \(.scale)"' 2>/dev/null)
if [[ -z $mon ]]; then bad "display" "no monitor from hyprctl"
elif [[ $mon == 1160x768* ]]; then bad "display" "$mon: still the firmware mode (monitors.lua not applied)"
else ok "display" "$mon"; fi
bg=$H/.local/state/omarchy/current/background
if [[ -L $bg && ! -e $bg ]]; then bad "desktop background" "$(readlink "$bg") is missing: omacvm apply, then log in again"; fi
# Omarchy's default keyring: without one Chromium asks for a keyring password.
# The one gnome-keyring takes: named in "default", else "login" (as
# default-keyring.sh; the Mac sends this file alone, over SSH).
kd=$H/.local/share/keyrings; kr=login
[[ -s $kd/default ]] && kr=$(head -1 "$kd/default")
if [[ $kr =~ ^[A-Za-z0-9_.-]+$ && -f $kd/$kr.keyring ]]; then ok "keyring" "$kr (default)"
elif compgen -G "$kd/*.keyring" >/dev/null; then
  bad "keyring" "none is the default: apps like Chromium ask for a keyring password (pick one in Passwords and Keys)" human
else bad "keyring" "none: Chromium asks for a keyring password at its first start; omacvm apply makes Omarchy's default keyring"; fi
if [[ $TYPE == app ]]; then
  # Which UEFI firmware OmacVM.app started the VM with (SMBIOS BIOS version).
  fw=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
  if [[ $fw == *-omacvm ]]; then ok "firmware" "$fw (Omarchy boot logo)"
  else skip "firmware" "${fw:-unknown}: QEMU's own (TianoCore logo), from an older OmacVM.app or OMACVM_FIRMWARE=qemu"; fi
fi
# The Mac's proxy from the build (#122): what a login on this network gets (#232).
if [[ -f /etc/environment.d/90-omacvm-proxy.conf ]] &&
   [[ $(head -1 /etc/environment.d/90-omacvm-proxy.conf) == "# The Mac's proxy when this VM was built (OmacVM"* ]]; then
  bad "the Mac's proxy" "fixed to the build's network in environment.d: omacvm apply makes it follow the network"
elif [[ -s /etc/omacvm/proxy.env && -x /usr/local/bin/omacvm-proxy-env ]]; then
  px_err=$(mktemp); px=$(/usr/local/bin/omacvm-proxy-env 2>"$px_err" | sed -nE 's|//[^/@]*@|//***@|; s/^(http|https|all)_proxy=/\1 /p' | paste -sd, - | sed 's/,/, /g')
  if [[ -n $px ]]; then ok "the Mac's proxy" "$px (at each login, for the network the VM is on)"
  else skip "the Mac's proxy" "none on this network: $(sed -n '1s/^omacvm-proxy-env: //p' "$px_err")"; fi
  rm -f "$px_err"
fi

section "The Mac in the bar (Bridge)"
FEATURE=bridge
if [[ $BRIDGE == on ]]; then
  if [[ -s $H/.config/omacvm-bridge/token ]]; then ok "token" "~/.config/omacvm-bridge/token"
  else bad "token" "missing: run omacvm apply on the Mac"; fi
  state=$(as_user omacvm-bridge state 2>/dev/null)
  if jq -e .power >/dev/null 2>&1 <<<"$state"; then
    if jq -e .location_authorized <<<"$state" >/dev/null; then
      ok "Wi-Fi" "$(jq -r 'if .connected then "\(.ssid), \(.rssi) dBm" elif .power then "on, not connected" else "off" end' <<<"$state")"
    else bad "Wi-Fi" "Location Services not granted to OmacVM Bridge on the Mac (no network names)" human; fi
    if jq -e .can_share <<<"$state" >/dev/null; then ok "Wi-Fi password sharing" "QR card can ask the Mac"
    else skip "Wi-Fi password sharing" "not on a shareable network"; fi
  else bad "Wi-Fi" "the Bridge does not answer at $HOST:47831 (or did not prove it is OmacVM's Bridge: omacvm update$(restart_hint port))"; fi
  audio=$(as_user omacvm-bridge audio 2>/dev/null)
  if jq -e .devices >/dev/null 2>&1 <<<"$audio"; then
    ok "audio" "$(jq -r '(.devices[] | select(.default_output) | .name) // "no output"' <<<"$audio" | head -1)"
  else bad "audio" "no answer from the Bridge"; fi
  disp=$(as_user omacvm-bridge display 2>/dev/null)
  if jq -e .night_shift >/dev/null 2>&1 <<<"$disp"; then
    ok "Night Shift / True Tone" "$(jq -r '"night shift \(if .night_shift.enabled then "on" else "off" end), true tone \(if .true_tone.enabled then "on" else "off" end)"' <<<"$disp")"
  else bad "Night Shift / True Tone" "no answer from the Bridge"; fi
  if as_user bash -c 'timeout 4 omacvm-bridge events 2>/dev/null | grep -m1 -q "^event:"'; then ok "live updates" "event stream"
  else bad "live updates" "no events from the Bridge"; fi
  # The widgets and the OSD share one stream (omacvm-bridge-events); a second
  # connection can be a request in flight.
  n=$(ss -Htn state established "dst $HOST:47831" | wc -l)
  if ! user_active omacvm-bridge-events.socket; then bad "shared event stream" "omacvm-bridge-events.socket not active (omacvm apply)"
  elif (( n <= 2 )); then ok "shared event stream" "$n connection(s) to the Mac"
  else bad "shared event stream" "$n connections to the Mac (widgets from before it: log out and in)"; fi
  if user_active omacvm-bridge-osd.service; then ok "media keys OSD" "omacvm-bridge-osd"
  else bad "media keys OSD" "omacvm-bridge-osd.service not running"; fi
  # Omarchy's brightness commands reach the external Mac display an output is on.
  FEATURE=external-brightness
  if [[ $EXT_BRIGHTNESS != on ]]; then skip "external brightness" "off (omacvm enable external-brightness)"
  elif ! grep -qs '^# omacvm-ddcutil' /usr/local/bin/ddcutil; then bad "external brightness" "/usr/local/bin/ddcutil is not OmacVM's (omacvm apply)"
  elif ex=$(as_user omacvm-bridge external 2>/dev/null) && jq -e .displays >/dev/null 2>&1 <<<"$ex"; then
    ok "external brightness" "$(jq -r 'if (.enabled | not) then "off on the Mac (the Bridge'"'"'s config.json)"
      elif (.displays | length) == 0 then "no external display on the Mac now"
      else [.displays[] | "\(.name): \(if .method == "ddc" then "DDC/CI" elif .method == "apple" then "its own control" else "not settable" end)"] | join(", ") end' <<<"$ex")"
  else bad "external brightness" "the Bridge does not answer /display/external (an older Bridge: omacvm update on the Mac)"; fi
  # Touch ID (ADR 0041): the keys, the PAM lines and the polkit rule. The
  # Mac's side shows only with a finger, so not asked here.
  FEATURE=touch-id
  if [[ $TOUCH_ID != on ]]; then skip "Touch ID" "off (omacvm enable touch-id)"
  elif [[ ! -s /etc/omacvm/touchid-key || ( $TYPE != app && ! -s /etc/omacvm/touchid-token ) ]]; then bad "Touch ID" "no key in the VM (omacvm apply on the Mac, with the VM by name and without --no-token)"
  elif ! grep -qs 'pam_exec.so .*omacvm-touchid' /etc/pam.d/sudo; then bad "Touch ID" "not in /etc/pam.d/sudo (omacvm apply)"
  elif ! grep -qs 'pam_exec.so .*omacvm-touchid' /etc/pam.d/polkit-1; then bad "Touch ID" "not in /etc/pam.d/polkit-1 (omacvm apply)"
  elif [[ ! -f /etc/polkit-1/rules.d/00-omacvm-touchid.rules || ! -x /usr/lib/omacvm/omacvm-touchid-note ]]; then bad "Touch ID" "the polkit rule is missing (omacvm apply)"
  elif [[ $TYPE == app && ! -e /dev/virtio-ports/org.omacvm.auth ]]; then
    # Turned on while the VM runs: OmacVM.app adds the port at the start. Not a fault.
    skip "Touch ID" "on from the VM's next start: shut it down, then start it again (OmacVM.app adds its Touch ID port at the start)" human
  else ok "Touch ID" "sudo and polkit ask the Mac first; the password keeps working"; fi
  # How the last request went (the PAM client's journal line; never the command).
  if [[ $TOUCH_ID == on ]]; then
    tj=$(journalctl -t omacvm-touchid -n 1 -o short-iso --no-pager -q 2>/dev/null | tail -1)
    tw=$(sed -n 's/^[^ ]* [^ ]* omacvm-touchid[^:]*: //p' <<<"$tj"); tt=${tj:11:5}
    if [[ -z $tw ]]; then skip "Touch ID last request" "none yet: try sudo -v in a terminal"
    elif [[ $tw == *": Touch ID yes" ]]; then ok "Touch ID last request" "$tt: ${tw%%:*}, Touch ID yes"
    else skip "Touch ID last request" "$tt: ${tw}"; fi
  fi
  # The Mac's Touch ID panel draws in the Omarchy theme this VM sends (omacvm-touchid-theme).
  if [[ $TOUCH_ID == on ]]; then
    if ! user_active omacvm-touchid-theme.path; then bad "Touch ID panel theme" "the watcher (omacvm-touchid-theme.path) stopped: omacvm apply starts it again"
    elif [[ ! -s $H/.config/omacvm-bridge/vm-key ]]; then skip "Touch ID panel theme" "no control centre key in this VM: the Mac's panel stays Tokyo Night (omacvm apply with the VM by name)"
    elif [[ -s $H/.local/state/omacvm/touchid-theme-sent ]]; then ok "Touch ID panel theme" "the Mac's panel uses this Omarchy theme"
    else bad "Touch ID panel theme" "not sent to the Mac yet (journalctl --user -u omacvm-touchid-theme)"; fi
    # Apps that ask polkit only with their own switch on (1Password): a hint, never a fault.
    while IFS=$'\t' read -r _ st title text; do
      [[ -n $title ]] || continue
      if [[ $st == on ]]; then ok "$title" "$text"; else skip "$title" "$text" human; fi
    done < <(sudo -u "$U" env HOME="$H" /usr/lib/omacvm/omacvm-touchid-apps 2>/dev/null)
  fi
  FEATURE=bridge
  # Right after the first login omacvm-plugins may still be enabling the widgets.
  for _ in $(seq 60); do
    [[ -s $H/.local/state/omacvm/pending-plugins &&
       $(systemctl --user -M "$U@" show -p ActiveState --value omacvm-plugins.service 2>/dev/null) == activating ]] || break
    sleep 1
  done
  layout=$(jq -r '[.bar.layout[]?[]?.id] | join(" ")' "$H/.config/omarchy/shell.json" 2>/dev/null)
  bt=$(as_user omacvm-bridge bluetooth 2>/dev/null)
  if jq -e .devices >/dev/null 2>&1 <<<"$bt"; then
    ok "Bluetooth" "$(jq -r '"\(if .power then "on" else "off" end), \([.devices[] | select(.connected)] | length) of \(.devices | length) devices connected"' <<<"$bt")"
  else bad "Bluetooth" "no answer from the Bridge"; fi
  for w in omacvm.bluetooth omacvm.wifi omacvm.audio omacvm.nightshift; do
    if [[ " $layout " == *" $w "* ]]; then ok "bar: $w" "in the bar"
    elif [[ -s $H/.local/state/omacvm/pending-plugins ]]; then bad "bar: $w" "queued, not enabled yet (log out and in)"
    else bad "bar: $w" "not in the bar"; fi
  done
  for w in omarchy.bluetooth omarchy.network omarchy.audio; do
    [[ " $layout " == *" $w "* ]] && bad "bar: $w" "the stock widget is back next to OmacVM's"
  done
  if jq -e '.plugins[]? | select(.id == "omacvm.wifiqr")' "$H/.config/omarchy/shell.json" >/dev/null 2>&1; then ok "Wi-Fi QR card" "omacvm.wifiqr"
  else bad "Wi-Fi QR card" "omacvm.wifiqr not enabled"; fi
  check "Night Shift toggle" "Super+Ctrl+N drives the Mac" test -x /usr/local/bin/omarchy-toggle-nightlight
  if jq -e '[.bar.layout[]?[]? | select(.id == "omarchy.indicators") | (.items // ["NightLight"]) | index("NightLight")] | all(. == null)' "$H/.config/omarchy/shell.json" >/dev/null 2>&1 && ! pgrep -x hyprsunset >/dev/null; then
    ok "one night light" "the Mac's Night Shift; Omarchy's own is off"
  else bad "one night light" "Omarchy's night light (hyprsunset) is still reachable or running: omacvm apply"; fi
  FEATURE=wallpaper
  if [[ $WALLPAPER == on ]]; then
    if user_active omacvm-wallpaper.path; then ok "wallpaper" "follows the Omarchy theme"
    else bad "wallpaper" "the watcher (omacvm-wallpaper.path) stopped: omacvm apply starts it again"; fi
  elif user_active omacvm-wallpaper.path || user_active omacvm-wallpaper.service; then
    bad "wallpaper" "off, but its watcher runs: omacvm apply"
  else skip "wallpaper" "off (chosen at setup)"; fi
elif user_active omacvm-bridge-events.socket || user_active omacvm-bridge-osd.service || pgrep -u "$U" -f /usr/local/bin/omacvm-bridge >/dev/null; then
  bad "Bridge" "off, but its services run and talk to the Mac: omacvm apply"
else skip "Bridge" "off (chosen at setup): Omarchy's own Wi-Fi and audio widgets"; fi

section "Camera and microphone"
FEATURE=camera
if [[ $CAMERA == on && $TYPE == parallels ]]; then
  # Parallels' own camera sharing: a USB camera in the VM.
  cams=$(cat /sys/class/video4linux/video*/name 2>/dev/null | sort -u | paste -sd, -)
  if [[ -n $cams ]]; then ok "camera" "Parallels' own: $cams"
  else bad "camera" "no camera in the VM: turn on camera sharing in the VM's settings in Parallels Desktop (it shares the Mac's camera as a USB camera)"; fi
elif [[ $CAMERA == on ]]; then
  campkg=$(missing_pkgs dkms v4l2loopback-dkms)
  if [[ $(cat /sys/class/video4linux/video42/name 2>/dev/null) == "Mac Camera" ]]; then ok "camera device" "/dev/video42, Mac Camera"
  elif [[ -n $campkg ]]; then bad "camera device" "no /dev/video42: $campkg"
  else bad "camera device" "no /dev/video42 (v4l2loopback not loaded: after a kernel update reboot, then omacvm apply)"; fi
  if user_active omacvm-camera.service; then ok "camera service" "omacvm-camera, asks the Mac only while an app reads"
  elif [[ -n $campkg ]]; then bad "camera service" "not set up: $campkg"
  else bad "camera service" "omacvm-camera.service not running: omacvm apply"; fi
  cs=$(as_user /usr/local/bin/omacvm-camera --status 2>/dev/null)
  if [[ $TYPE == app ]]; then
    if jq -e .port <<<"$cs" >/dev/null 2>&1; then ok "camera from the Mac" "OmacVM.app's camera port"
    else bad "camera from the Mac" "no camera port: start the VM from an OmacVM.app with the camera (omacvm update$(restart_hint))"; fi
  else
    case $(jq -r '.permission // empty' <<<"$cs" 2>/dev/null) in
      granted|test) ok "camera from the Mac" "OmacVM Bridge: $(jq -r '.camera // "no camera"' <<<"$cs"), $(jq -r 'if .on then "on, \(.readers) reading" else "off" end' <<<"$cs")" ;;
      not-determined) skip "camera from the Mac" "macOS asks for OmacVM Bridge the first time a Linux app uses the camera" human ;;
      denied|restricted) bad "camera from the Mac" "camera not allowed for OmacVM Bridge (System Settings > Privacy & Security > Camera)" human ;;
      *) bad "camera from the Mac" "the Bridge does not answer /camera/status: $(jq -r '.error // "no answer"' <<<"$cs" 2>/dev/null) (omacvm update)" ;;
    esac
  fi
elif user_active omacvm-camera.service; then bad "camera" "off, but omacvm-camera runs and asks the Mac: omacvm apply"
else skip "camera" "off (chosen at setup)"; fi
FEATURE=""
mic=$(as_user pactl list short sources 2>/dev/null | awk '$2 !~ /\.monitor$/ { print $2; exit }')
if [[ -n $mic ]]; then ok "microphone" "$mic"
else bad "microphone" "PipeWire has no input: no sound card in the VM? (UTM, Fusion: shut it down, then omacvm apply --vm NAME starts it with one)"; fi
# PipeWire's sound threads run real-time (RTKit, install.sh); at normal
# priority the sound breaks whenever the VM is busy.
pw=$(pgrep -u "$U" -x pipewire | head -1)
if [[ -z $pw ]]; then skip "sound priority" "PipeWire is not running"
elif ps -L -o cls=,comm= -p "$pw" | awk '$2 ~ /^data-loop/ && ($1 == "RR" || $1 == "FF") { f = 1 } END { exit !f }'; then
  ok "sound priority" "real-time (PipeWire's data loop)"
else bad "sound priority" "PipeWire runs at normal priority, so the sound breaks when the VM is busy: omacvm apply, then systemctl --user restart pipewire pipewire-pulse wireplumber"; fi

section "The Mac's battery"
FEATURE=battery
if [[ $TYPE == parallels ]]; then
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then skip "battery" "Parallels gives the VM the Mac's battery itself"
  else skip "battery" "none: this Mac has no battery (on a MacBook Parallels passes it itself)"; fi
elif [[ $BATTERY == on ]]; then
  if [[ -w /sys/devices/platform/omacvm-battery/state ]]; then
    ok "battery module" "omacvm_battery $(cat /sys/module/omacvm_battery/version 2>/dev/null) loaded"
  else bad "battery module" "not loaded on $(uname -r) (reboot after omacvm apply; log /var/lib/omacvm/battery-build.log)"; fi
  # Every kernel that boots must have it (DKMS builds it with each kernel's headers).
  for k in /usr/lib/modules/*; do k=${k##*/}
    [[ -d /usr/lib/modules/$k/kernel ]] || continue
    if dkms status -k "$k" omacvm-battery 2>/dev/null | grep -q installed; then ok "battery: kernel $k" "module built (DKMS)"
    elif [[ ! -f /usr/lib/modules/$k/build/Makefile ]]; then bad "battery: kernel $k" "no headers to build the module with: omarchy update, reboot, omacvm apply"
    else bad "battery: kernel $k" "module not built (omacvm apply; log /var/lib/omacvm/battery-build.log)"; fi
  done
  # Right after a boot the agent (and its first snapshot) may need a moment.
  for _ in $(seq 15); do systemctl is-active -q omacvm-battery && break; sleep 1; done
  for _ in $(seq 5); do [[ -d /sys/class/power_supply/BAT0 ]] && break; sleep 1; done
  if systemctl is-active -q omacvm-battery; then ok "battery agent" "omacvm-battery feeds it the Mac's"
  else bad "battery agent" "omacvm-battery.service not running ($(journalctl -u omacvm-battery -n1 -o cat 2>/dev/null | sed 's/^omacvm-battery: //'))"; fi
  up=$(upower -i /org/freedesktop/UPower/devices/battery_BAT0 2>/dev/null)
  pct=$(awk '/percentage:/ { print $2; exit }' <<<"$up"); st=$(awk '/state:/ { print $2; exit }' <<<"$up")
  if [[ -n $pct ]]; then ok "battery in UPower" "BAT0 $pct, $st"
  elif [[ -d /sys/class/power_supply/ADP0 ]]; then bad "battery in UPower" "no BAT0 yet: the Mac sent no battery (a Mac without one, or the Mac's side is older: omacvm update$(restart_hint))"
  else bad "battery in UPower" "no BAT0$(restart_hint)"; fi
  # Watts and time left need the Mac's current (module 1.1.0, Mac side 3.0.6):
  # without it UPower guesses watts from charge steps, and the guess is noise.
  if [[ $st == charging || $st == discharging ]]; then
    if w=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null); then
      ok "battery watts" "$(awk -v w="$w" 'BEGIN { printf "%.1f W", w / 1000000 }') $st (the Mac's)"
    elif [[ -e /sys/class/power_supply/BAT0/power_now ]]; then
      # Not a restart matter: the Mac's side is older than 3.0.6.
      if [[ $TYPE == app ]]; then bad "battery watts" "OmacVM.app sends no current: update the app"
      else bad "battery watts" "the Bridge sends no current: omacvm update on the Mac"; fi
    else bad "battery watts" "the module is older than 1.1.0: omacvm apply, or reboot"; fi
  fi
  if jq -e '[.bar.layout[]?[]?.id] | index("omarchy.power")' "$H/.config/omarchy/shell.json" >/dev/null 2>&1; then
    ok "battery in the bar" "Omarchy's power widget (shows while BAT0 is there)"
  else skip "battery in the bar" "Omarchy's power widget is not in the bar (Omarchy's bar settings add it)"; fi
  if grep -qs '^CriticalPowerAction=Ignore' /etc/UPower/UPower.conf.d/90-omacvm-battery.conf; then ok "low battery" "the VM never suspends for it"
  else bad "low battery" "UPower may suspend or power off the VM: omacvm apply"; fi
elif systemctl is-active -q omacvm-battery; then bad "battery" "off, but omacvm-battery runs and asks the Mac: omacvm apply"
else skip "battery" "off (omacvm enable battery, on a MacBook)"; fi

section "Trackpad and keyboard"
FEATURE=gestures
if [[ $GESTURES == on ]]; then
  if systemctl is-active -q omacvm-gestures; then
    if connected_to "$HOST" 47830; then ok "gestures" "connected to the Mac"
    else bad "gestures" "service runs but is not connected to $HOST:47830$(restart_hint port)"; fi
  else bad "gestures" "omacvm-gestures.service not running"; fi
elif systemctl is-active -q omacvm-gestures; then
  bad "gestures" "off, but omacvm-gestures.service runs and talks to the Mac: omacvm apply"
fi
FEATURE=gestures
if [[ $GESTURES == on ]]; then
  check "virtual trackpad" "Magic Trackpad (OmacVM)" ev_device "Apple Inc. Magic Trackpad (OmacVM)"
  if grep -rqs '^hl.gesture({ fingers = 3' "$H/.config/hypr/"; then ok "workspace swipes" "3/4-finger gestures configured"
  else bad "workspace swipes" "no hl.gesture lines in ~/.config/hypr"; fi
else skip "trackpad gestures" "off (chosen at setup): macOS keeps its swipes"; fi
FEATURE=scroll-momentum
if [[ $GLIDE == on && $GESTURES == on ]]; then
  pid=$(systemctl show -p MainPID --value omacvm-gestures 2>/dev/null)
  # same rule as the daemon: the new key wins, a VM not yet updated may only have the old glide key
  denv=$( [[ -n $pid && $pid != 0 ]] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)
  dsm=$(sed -n 's/^OMACVM_FEATURE_scroll_momentum=//p' <<<"$denv"); dgl=$(sed -n 's/^OMACVM_FEATURE_glide=//p' <<<"$denv")
  if [[ ${dsm:-${dgl:-off}} == on ]]; then
    ok "scroll momentum" "two-finger scrolling from the Mac (experimental)"
  else bad "scroll momentum" "chosen, but the daemon runs without it: systemctl restart omacvm-gestures"; fi
  if [[ -f $H/.config/hypr/omacvm_glide.lua ]] && grep -qxF 'require("hypr.omacvm_glide")' "$H/.config/hypr/hyprland.lua"; then
    ok "scroll settings" "omacvm_glide.lua"
  else bad "scroll settings" "omacvm_glide.lua missing or not loaded from hyprland.lua (omacvm enable scroll-momentum)"; fi
else skip "scroll momentum" "off (omacvm enable scroll-momentum turns it on: trackpads only)"; fi
FEATURE=""
if [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; then
  if [[ $GESTURES == on ]]; then
    check "Cmd as Super" "OmacVM keyboard (Mac shortcuts)" ev_device "OmacVM keyboard (Mac shortcuts)"
  else skip "Cmd as Super" "comes with trackpad gestures, which are off (omacvm enable gestures)"; fi
fi
check "Cmd+V paste" "Universal paste binding" grep -qs '"Universal paste"' "$H/.config/hypr/bindings.lua"
[[ $TYPE != app ]] || check "globe key binding" "XF86Launch3: Omarchy's emoji picker" grep -qs '"Emojis (Mac globe key)"' "$H/.config/hypr/bindings.lua"
kb=$(as_user hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty' 2>/dev/null)
if [[ -n $kb ]]; then ok "keyboard layout" "$kb"; else bad "keyboard layout" "no layout from Hyprland"; fi

case $TYPE in
parallels)
  section "Parallels"
  check "Parallels Tools" "prltoolsd" systemctl is-active -q prltoolsd
  check "dynamic resolution" "parallels-dynres" test -x /usr/local/bin/parallels-dynres
  check "clipboard VM -> Mac" "parallels-clip-out" test -x /usr/local/bin/parallels-clip-out ;;
utm)
  section "UTM"
  check "SPICE daemon" "spice-vdagentd" systemctl is-active -q spice-vdagentd
  if user_active omacvm-vdagent.service; then ok "clipboard + pointer" "omacvm-vdagent"
  else bad "clipboard + pointer" "omacvm-vdagent.service not running"; fi
  user_active spice-vdagent.service && bad "stock SPICE agent" "running: the pointer stops halfway"
  w=$(as_user hyprctl monitors -j 2>/dev/null | jq -r 'max_by(.width * .height) | .width' 2>/dev/null)
  tab=$(python3 - 2>/dev/null <<'EOF'
import evdev
for p in evdev.list_devices():
    d = evdev.InputDevice(p)
    if d.name == "spice vdagent tablet":
        print(dict(d.capabilities(absinfo=True)[3])[0].max + 1)
EOF
)
  if [[ -z $tab ]]; then skip "pointer range" "no SPICE tablet yet (UTM window not open?)"
  elif [[ $tab == "$w" ]]; then ok "pointer range" "${tab} px, the whole screen"
  else bad "pointer range" "tablet $tab px vs screen $w px"; fi
  check "QEMU guest agent" "utmctl ip-address/exec" systemctl is-active -q qemu-guest-agent
  check "virtio-gpu settings" "90-omacvm-utm.conf" test -f /etc/environment.d/90-omacvm-utm.conf
  check "GPU for browsers" "virgl-msaa.so preloaded" bash -c 'test -s /usr/local/lib/omacvm/virgl-msaa.so && grep -qx /usr/local/lib/omacvm/virgl-msaa.so /etc/ld.so.preload' ;;
app)
  section "OmacVM.app"
  check "display follows the window" "omacvm-display-sync" pgrep -u "$U" -f omacvm-display-sync
  check "QEMU guest agent" "clean shutdown fallback" systemctl is-active -q qemu-guest-agent
  # Fast network (vmnet through omacvm-netd on the Mac), else QEMU's user network.
  if [[ $GW == 192.168.77.1 ]]; then
    a=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4; exit }')
    # On here or turned on with the app's button (no apply since then).
    ok "fast network" "vmnet, ${a%/*}"
  elif [[ $FAST_NET == on ]]; then
    # The app's button may have turned it off since; the Mac's check knows.
    skip "fast network" "not this start: QEMU's user network (omacvm check on the Mac says why)"
  else skip "fast network" "off (experimental: omacvm enable fast-network)"; fi
  check "power key" "Quit on the Mac shuts down" test -f /etc/systemd/logind.conf.d/90-omacvm-app-power.conf
  FEATURE=vulkan
  if [[ ${OMACVM_FEATURE_vulkan:-off} == on && ! -f /etc/vulkan/icd.d/omacvm_venus_icd.json ]]; then
    bad "Vulkan (OmacVM's Mesa)" "on, but OmacVM's Mesa is not installed: omacvm apply (its log says why)"
  elif [[ -f /etc/vulkan/icd.d/omacvm_venus_icd.json ]]; then
    if ! /usr/local/share/omacvm/app/guest/venus/install.sh --venus-on; then
      skip "Vulkan (OmacVM's Mesa)" "on from the VM's next start (shut it down in OmacVM.app, then start it again)" 1
    else
      if command -v vulkaninfo >/dev/null; then
        check "Vulkan (OmacVM's Mesa)" "venus" bash -c 'VK_LOADER_DRIVERS_DISABLE=virtio_icd.json vulkaninfo --summary 2>/dev/null | grep -q "driverName *= venus"'
      else skip "Vulkan (OmacVM's Mesa)" "not checked: vulkaninfo missing (vulkan-tools)"; fi
      check "OpenCL (rusticl on Zink)" "a zink device" bash -c 'RUSTICL_ENABLE=zink clinfo -l 2>/dev/null | grep -q zink'
      check "WebGPU in Chromium" "\"Chromium (WebGPU)\" in the menu (omacvm-chromium-webgpu)" test -x /usr/local/bin/omacvm-chromium-webgpu
    fi
  elif [[ -f /etc/environment.d/90-omacvm-opencl.conf ]]; then
    # Graphics Vulkan: the distro's rusticl on Zink on Venus (venus/opencl.sh).
    if ! /usr/local/share/omacvm/app/guest/venus/install.sh --venus-on; then
      skip "OpenCL (rusticl on Zink)" "with Vulkan from the VM's next start"
    elif RUSTICL_ENABLE=zink clinfo -l 2>/dev/null | grep -q zink; then
      ok "OpenCL (rusticl on Zink)" "$(RUSTICL_ENABLE=zink clinfo -l 2>/dev/null | sed -n 's/.*Device #0: //p' | head -1)"
    else
      bad "OpenCL (rusticl on Zink)" "no device: on MoltenVK (macOS 15) Zink needs OmacVM's Mesa (omacvm enable vulkan)"
    fi
    # WebGPU in Chromium: the launcher, on a Venus driver with shared semaphores (OmacVM's vulkan-virtio build).
    if [[ ! -x /usr/local/bin/omacvm-chromium-webgpu ]]; then
      bad "WebGPU in Chromium" "no \"Chromium (WebGPU)\" launcher: omacvm apply"
    elif [[ $(pacman -Q vulkan-virtio 2>/dev/null) == *omacvm* ]]; then
      ok "WebGPU in Chromium" "\"Chromium (WebGPU)\" in the menu (omacvm-chromium-webgpu)"
    else
      skip "WebGPU in Chromium" "after OmacVM's Venus driver build ($(pacman -Q vulkan-virtio 2>/dev/null || echo "no vulkan-virtio") now; the VM builds it after its next start)"
    fi
  else skip "Vulkan, WebGPU, GPU compute" "off (experimental: omacvm enable vulkan)"; fi
  FEATURE=""
  if user_active omacvm-clipboard.service; then ok "clipboard" "both ways (omacvm-clipboard)"
  else bad "clipboard" "omacvm-clipboard.service not running (the app passes the port: started from OmacVM.app?)"; fi
  if [[ ! -e /dev/virtio-ports/org.omacvm.display ]]; then
    skip "every Mac display" "no display port: an OmacVM.app from before external displays (omacvm update)"
  elif user_active omacvm-displays.service; then
    n=$(as_user hyprctl monitors -j 2>/dev/null | jq '[.[] | select(.name | test("^Virtual-"))] | length' 2>/dev/null || echo "?")
    ok "every Mac display" "external displays $(as_user omacvm-displays state 2>/dev/null || echo "?"), $n output(s) now"
    # What each display really shows (a small screenshot): only Hyprland's grey
    # where the desktop should be means no wallpaper and no bar were drawn.
    desk=$(as_user omacvm-displays desktop 2>/dev/null)
    dark=$(jq -r '.undrawn // [] | join(", ")' <<<"$desk" 2>/dev/null)
    off=$(jq -r '.misplaced // [] | join("; ")' <<<"$desk" 2>/dev/null)
    fixes=$(jq -r '.repairs.count // 0' <<<"$desk" 2>/dev/null)
    if [[ -n $dark ]]; then bad "desktop" "nothing drawn on $dark, only Hyprland's grey${off:+ ($off)}: omarchy-restart-shell; journalctl --user -u omacvm-displays"
    elif [[ -n $off ]]; then bad "desktop" "wallpaper not on its display: $off (omarchy-restart-shell)"
    elif [[ -z $desk ]]; then skip "desktop" "omacvm-displays desktop gave nothing"
    else ok "desktop" "wallpaper drawn on every display without windows$([[ ${fixes:-0} != 0 ]] && echo " (shell restarted $fixes time(s) to draw it)")"; fi
  else bad "every Mac display" "omacvm-displays.service not running: omacvm apply"; fi
  if as_user pactl list short sinks 2>/dev/null | grep -q .; then ok "sound" "$(as_user pactl list short sinks 2>/dev/null | head -1 | cut -f2)"
  else bad "sound" "no PipeWire sink: omacvm apply"; fi
  if as_user hyprctl monitors -j 2>/dev/null | jq -e '.[0].refreshRate' >/dev/null 2>&1; then
    ok "display" "$(as_user hyprctl monitors -j | jq -r '.[0] | "\(.width)x\(.height) @\(.refreshRate | floor) Hz, scale \(.scale)"')"
  fi
  # The display sync stops following an output that keeps changing (a loop)
  # and writes why; nothing written: it never had to.
  held=$RUN/omacvm/display-sync/held
  if [[ -s $held ]]; then
    bad "display sync" "held $(wc -l < "$held") time(s) this session, last: $(tail -1 "$held" | cut -d' ' -f2-)"
  fi
  r=$(as_user glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
  [[ -z $r ]] && r=$(as_user eglinfo -B 2>/dev/null | sed -n 's/^OpenGL core profile renderer: //p;s/^OpenGL renderer: //p' | head -1)
  case $r in
    *virgl*) ok "GPU" "$r" ;;
    "") skip "GPU" "no glxinfo/eglinfo to ask (mesa-utils)" ;;
    *) bad "GPU" "software rendering: $r" ;;
  esac
  # Vulkan (Venus), with the app's Vulkan switch on: the driver must size GPU
  # memory to the Mac's pages, or every Vulkan app fails to start.
  FEATURE=graphics
  # (OmacVM's Mesa above has its own Venus driver; the distro's is not used then.)
  vk=$(/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh --status 2>/dev/null)
  [[ -f /etc/vulkan/icd.d/omacvm_venus_icd.json ]] && vk=omacvm
  # Without vulkaninfo (vulkan-tools) nothing was asked: not checked, not "no device" (#332).
  case ${vk%% *} in
    ok|update) command -v vulkaninfo >/dev/null || vk="novkinfo ${vk#* }" ;;
  esac
  case ${vk%% *} in
    omacvm) ;;
    novkinfo) skip "Vulkan (Venus)" "not checked: vulkaninfo missing (vulkan-tools; omacvm apply installs it); ${vk#* }" ;;
    ok) if v=$(vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' | grep -m1 Venus); then ok "Vulkan (Venus)" "$v, ${vk#* }"
        else bad "Vulkan (Venus)" "${vk#* }, but vulkaninfo finds no Venus device"; fi ;;
    update) if v=$(vulkaninfo --summary 2>/dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' | grep -m1 Venus); then ok "Vulkan (Venus)" "$v, ${vk#* } (built after the VM's next start, or omacvm apply)"
            else bad "Vulkan (Venus)" "${vk#* }, but vulkaninfo finds no Venus device"; fi ;;
    needed) bad "Vulkan (Venus)" "${vk#* }: omacvm apply" ;;
    no-venus|no-pages) skip "Vulkan (Venus)" "${vk#* }" ;;
    *) skip "Vulkan (Venus)" "not known (an OmacVM from before this check: omacvm apply)" ;;
  esac
  FEATURE=""
  # Video decoding on the Mac's media engine (an app with it lists decoders).
  drv=virtio_gpu; [[ -f /usr/local/lib/dri/omacvm_drv_video.so ]] && drv=omacvm
  # The shim prints the Mac's per-VM limit (past it, players decode on the CPU).
  va=$(as_user env LIBVA_DRIVER_NAME=$drv LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri \
      OMACVM_VA_DEBUG=1 vainfo --display drm 2>&1)
  v=$(sed -n 's/^[[:space:]]*VAProfile\([A-Za-z0-9]*\)[[:space:]]*:[[:space:]]*VAEntrypointVLD$/\1/p' <<<"$va" | tr '\n' ' ')
  lim=$(sed -n 's/^omacvm_drv_video: the Mac keeps at most \([1-9][0-9]*\) decoders.*/\1/p' <<<"$va" | head -1)
  # VA-API that does not start (vaInitialize failed): the line that says why.
  vafail=$(/usr/local/share/omacvm/vdec/guest/vdecd.sh vafail <<<"$va" 2>/dev/null)
  if [[ -n $v ]]; then ok "video decoding" "the Mac's media engine: $v${lim:+(at most $lim at once, more decode on the CPU)}"
  elif ! command -v vainfo >/dev/null; then skip "video decoding" "no vainfo (omacvm apply installs it)"
  elif [[ -n $vafail ]]; then bad "video decoding" "VA-API does not start, videos decode on the CPU: $vafail"
  else skip "video decoding" "no decoders (OmacVM.app older than the video decoding?)"; fi
  # Arch Linux ARM's Chromium decodes through V4L2 (omacvm-vdec + omacvm-vdecd).
  FEATURE=chromium-video
  if command -v chromium >/dev/null; then
    s=$(cat /run/omacvm-vdec/status 2>/dev/null || true)
    # A module built after it was loaded (an update while a video played): the old one serves until then.
    pend=""; m=$(modinfo -F srcversion omacvm_vdec 2>/dev/null || true)
    [[ -n $m && -e /sys/module/omacvm_vdec && $(cat /sys/module/omacvm_vdec/srcversion 2>/dev/null) != "$m" ]] &&
      pend=" (an update waits: restart the VM)"
    if [[ $CHROMIUM_VIDEO != on ]]; then skip "video decoding in Chromium" "off (omacvm enable chromium-video)"
    elif [[ -z $v && -n $vafail ]]; then skip "video decoding in Chromium" "VA-API does not start (see video decoding)"
    elif [[ -z $v ]]; then skip "video decoding in Chromium" "no decoders on the Mac's side"
    elif [[ ! -f /etc/systemd/system/omacvm-vdecd.service ]]; then
      vpkg=$(missing_pkgs dkms make gcc)
      bad "video decoding in Chromium" "not set up: ${vpkg:-omacvm apply}"
    elif [[ ! -e /dev/omacvm-vdec ]]; then bad "video decoding in Chromium" "no module for kernel $(uname -r) yet: omacvm apply, or reboot after an update"
    elif ! systemctl is-active -q omacvm-vdecd || [[ -z $s ]]; then
      w=$(/usr/local/share/omacvm/vdec/guest/vdecd.sh why 2>/dev/null)
      bad "video decoding in Chromium" "omacvm-vdecd down: ${w:-not running (journalctl -u omacvm-vdecd)}$pend"
    elif ! as_user /usr/local/lib/omacvm/chromium-flags.py check; then bad "video decoding in Chromium" "AcceleratedVideoDecoder missing in Chromium's flags: omacvm apply"
    else ok "video decoding in Chromium" "V4L2 -> the Mac's media engine: $s$pend"; fi
  fi
  FEATURE=""
  if [[ $drv == omacvm ]] && command -v firefox >/dev/null; then
    check "video decoding in Firefox" "the driver shim is on ld.so's path (Firefox's sandbox)" \
      grep -qx /usr/local/lib/dri /etc/ld.so.conf.d/omacvm-video.conf
  fi
  e=$(as_user env LIBVA_DRIVER_NAME=$drv LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri \
      vainfo --display drm 2>/dev/null | sed -n 's/^[[:space:]]*VAProfile\([A-Za-z0-9]*\)[[:space:]]*:[[:space:]]*VAEntrypointEncSlice$/\1/p' | tr '\n' ' ')
  if [[ -n $e ]]; then
    ok "video encoding" "the Mac's media engine: $e"
    check "WebRTC encoding" "Chrome, Brave: VA-API encoder features in their flags (omacvm apply)" \
      python3 /usr/local/share/omacvm/app/guest/browser-video-encode.py "$U" check
  elif command -v vainfo >/dev/null; then skip "video encoding" "none offered (OmacVM.app older than the video encoding?)"; fi
  # The frozen screen of screenshots and the recording picker (hyprpicker -r -z): OmacVM's build
  # draws it once per display, the package's on every frame (app/guest/hyprpicker/build.sh).
  if hp=$(pacman -Q hyprpicker 2>/dev/null | awk '{ print $2 }') && [[ -n $hp ]]; then
    if [[ -x /usr/local/bin/hyprpicker && "$(cut -d' ' -f1-2 /var/lib/omacvm/hyprpicker 2>/dev/null)" == "$hp $(sha256sum /usr/local/bin/hyprpicker | awk '{ print $1 }')" ]]; then
      ok "screenshot freeze" "hyprpicker $hp, drawn only when it changes"
    else skip "screenshot freeze" "the package's hyprpicker, which draws every frame (omacvm apply builds OmacVM's; it needs the network)"; fi
  fi
  # The Mac's input methods (mac-ime, docs/adr/0043): OmacVM's Fcitx5 module
  # built for this Fcitx5, the port (from the VM's start), Fcitx5 using both.
  FEATURE=mac-ime
  ime=$(/usr/local/share/omacvm/ime/guest/install.sh "$U" --status 2>/dev/null || true)
  if [[ ${OMACVM_FEATURE_mac_ime:-off} == on ]]; then
    port=/dev/virtio-ports/org.omacvm.ime
    fpid=$(pgrep -u "$U" -x fcitx5 2>/dev/null | head -1 || true)
    if [[ ${ime%% *} != ok ]]; then bad "Mac input methods" "${ime#* }"
    elif [[ ! -e $port ]]; then
      skip "Mac input methods" "on from the VM's next start: shut it down, then start it again (OmacVM.app adds its port at the start)" human
    elif [[ -z $fpid ]]; then bad "Mac input methods" "Fcitx5 does not run (Omarchy's omarchy-fcitx5 service starts it with the desktop)"
    elif ! grep -qs libomacvmime "/proc/$fpid/maps"; then skip "Mac input methods" "Fcitx5 loads the module at its next start (log out and in once)" human
    elif ! ls -l "/proc/$fpid/fd" 2>/dev/null | grep -qF -- "$(readlink -f "$port")"; then
      bad "Mac input methods" "Fcitx5 did not open the port (journalctl --user -u omarchy-fcitx5 in the VM)"
    elif ! as_user systemctl --user show-environment 2>/dev/null | grep -qx 'GTK_IM_MODULE=fcitx'; then
      ok "Mac input methods" "${ime#* }; GTK apps get the caret from the next login"
    else ok "Mac input methods" "${ime#* }: an input method on the Mac types in Omarchy's text fields"; fi
  elif [[ ${ime%% *} == ok || $ime == *"older"* || $ime == *"built for"* ]]; then
    bad "Mac input methods" "off, but OmacVM's Fcitx5 module is still installed: omacvm apply"
  else skip "Mac input methods" "off (experimental: omacvm enable mac-ime)"; fi
  FEATURE="" ;;
fusion)
  section "VMware Fusion"
  check "graphics driver" "vmwgfx" test -d /sys/module/vmwgfx
  hv=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }')
  if [[ "$(cat /var/lib/omacvm/hyprland-vmwgfx 2>/dev/null)" == "$hv $(sha256sum /usr/bin/Hyprland | awk '{ print $1 }')" ]]; then
    ok "Hyprland" "$hv with the vmwgfx fix"
  else bad "Hyprland" "$hv without the vmwgfx fix (black screen at the next login): omacvm apply builds it"; fi
  check "Hyprland after updates" "pacman hook rebuilds it" test -f /etc/pacman.d/hooks/zz-omacvm-hyprland.hook
  check "GPU in Chromium and Chrome" "--ignore-gpu-blocklist in /etc/chromium-flags.conf, /etc/chrome-flags.conf" \
    bash -c 'grep -qx -- --ignore-gpu-blocklist /etc/chromium-flags.conf && grep -qx -- --ignore-gpu-blocklist /etc/chrome-flags.conf'
  if command -v brave >/dev/null; then
    check "GPU in Brave" "--ignore-gpu-blocklist in ~/.config/brave-flags.conf (omacvm apply)" grep -qx -- --ignore-gpu-blocklist "$H/.config/brave-flags.conf"
  fi
  if command -v firefox >/dev/null; then
    check "GPU in Firefox" "omacvm-fusion.js (vmwgfx allowed)" test -f /usr/lib/firefox/defaults/pref/omacvm-fusion.js
  fi
  check "DNS" "Fusion's own, which follows the Mac (public DNS only while OmacVM installs)" test ! -f /etc/NetworkManager/conf.d/90-omacvm-fusion.conf
  check "VMware Tools" "vmtoolsd (Fusion's display layout)" systemctl is-active -q vmtoolsd
  if user_active omacvm-fusion-displays.service; then
    n=$(/usr/local/share/omacvm/fusion/guest/omacvm-fusion-layout 2>/dev/null | grep -c .)
    ok "displays" "omacvm-fusion-displays follows Fusion's layout ($n output(s) now)"
  else bad "displays" "omacvm-fusion-displays.service not running: omacvm apply"; fi
  if user_active omacvm-fusion-clipboard.service && pgrep -u "$U" -f 'vmtoolsd -n vmusr' >/dev/null; then
    ok "copy and paste" "VMware's agent + omacvm-fusion-clipboard"
  else bad "copy and paste" "omacvm-fusion-clipboard.service or VMware's agent not running: omacvm apply"; fi ;;
esac

section "Speed and safety"
FEATURE=thp-kernel
k=$(uname -r)
[[ -n $THP_KERNEL ]] || { [[ $k == *thp* ]] && THP_KERNEL=on || THP_KERNEL=off; }
if [[ $k == *thp* && $THP_KERNEL == off ]]; then bad "kernel" "$k: the memory-optimized kernel is off but still running (reboot)"
elif [[ $k == *thp* ]]; then ok "kernel" "$k (memory-optimized: THP + MGLRU)"
elif [[ $THP_KERNEL == off ]]; then ok "kernel" "$k (Arch Linux ARM's own; memory-optimized kernel not chosen)"
elif ! command -v grub-mkconfig >/dev/null; then skip "kernel" "$k (the memory-optimized kernel needs GRUB)"
else bad "kernel" "$k: not the memory-optimized kernel yet (reboot after omacvm apply?)"; fi
thp=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
if [[ $thp == always || $thp == madvise ]]; then ok "transparent huge pages" "$thp"
elif [[ $k == *thp* ]]; then bad "transparent huge pages" "${thp:-unavailable}"
else skip "transparent huge pages" "${thp:-not in this kernel} (part of the memory-optimized kernel)"; fi
lru=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)
if [[ -n $lru && $lru != 0x0000 ]]; then ok "MGLRU" "$lru"
elif [[ $k == *thp* ]]; then bad "MGLRU" "${lru:-unavailable}"
else skip "MGLRU" "${lru:-not in this kernel} (part of the memory-optimized kernel)"; fi
FEATURE=""
z=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | awk '/zram/ { print $2; exit }')
[[ -n $z ]] && ok "zram swap" "$z" || bad "zram swap" "none (reboot after omacvm apply?)"
if command -v grub-mkconfig >/dev/null; then
  if ! systemctl is-active -q grub-btrfsd; then bad "bootable snapshots" "grub-btrfsd is not running"
  elif [[ ! -s /boot/grub/grub-btrfs.cfg ]] && btrfs subvolume list -s / 2>/dev/null | grep -q .; then
    bad "bootable snapshots" "no snapshots menu in GRUB: it finds no kernel with an initramfs (omacvm apply)"
  else ok "bootable snapshots" "grub-btrfsd, snapshots menu in GRUB"; fi
fi
if ufw status 2>/dev/null | grep -q "omacvm: ssh from the Mac"; then ok "SSH from the Mac" "firewall rule"
else bad "SSH from the Mac" "no OmacVM firewall rule"; fi

section "Choices"
FEATURE=no-idle-lock
if [[ $NO_IDLE_LOCK == on ]]; then
  if [[ -f $H/.local/state/omarchy/indicators/stay-awake ]]; then ok "screensaver and lock disabled" "the Mac's lock protects the VM"
  else bad "screensaver and lock disabled" "chosen, but Omarchy's Stay Awake is not set"; fi
else ok "screensaver and lock" "Omarchy's own, after idle"; fi
FEATURE=autologin
# As SDDM does it, whoever wrote the file (the Mac's omacvm check fixes OmacVM's record to match).
# Run with bash -s from the Mac: the VM's copy (an older one has OmacVM's own file only).
if [[ -f /usr/local/share/omacvm/guest/autologin.sh ]]; then
  source /usr/local/share/omacvm/guest/autologin.sh; al=$(sddm_autologin_user)
else al=""; [[ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ]] && al=$U; fi
if [[ -n $al ]]; then ok "autologin" "on: SDDM logs $al in"
else ok "autologin" "off"; fi
FEATURE=mac-clock
if [[ $MAC_CLOCK == on ]]; then
  f=$(jq -r '.bar.layout.right[-1] | select(.id == "omarchy.clock") | .format' "$H/.config/omarchy/shell.json" 2>/dev/null)
  if [[ -n $f ]]; then ok "the Mac's clock" "far right, $f"
  elif [[ -s $H/.local/state/omacvm/pending-clock ]]; then bad "the Mac's clock" "set at the next login"
  else bad "the Mac's clock" "not at the far right of the bar (omacvm apply)"; fi
else skip "the Mac's clock" "off (chosen at setup): Omarchy's own clock"; fi

FEATURE=x86-apps
x86=$(/usr/local/share/omacvm/x86/guest/install.sh --status 2>/dev/null)
if [[ ${OMACVM_FEATURE_x86_apps:-off} == on ]]; then
  if [[ ${x86%% *} != ok ]]; then bad "x86 apps" "${x86#* }"
  elif ! /usr/local/share/omacvm/x86/guest/install.sh --test; then bad "x86 apps" "${x86#* }, but a test x86_64 program does not run"
  else ok "x86 apps" "${x86#* }"; fi
elif [[ -n $x86 && ${x86%% *} != off && $x86 != *"not OmacVM's"* ]]; then bad "x86 apps" "off, but OmacVM's box64 is still installed: omacvm apply"
else skip "x86 apps" "off (omacvm enable x86-apps: x86_64 programs through box64)"; fi
FEATURE=""

section "Omanotch"
FEATURE=omanotch
if [[ $OMANOTCH == off ]]; then
  if user_active notchcast.service || pgrep -u "$U" -x notchcast >/dev/null || connected_to "$HOST" 47811; then
    bad "Omanotch" "off, but notchcast runs and talks to the Mac: omacvm apply"
  elif [[ $(systemctl --global is-enabled omacvm-omanotch.service 2>/dev/null) == enabled ]]; then
    bad "Omanotch" "off, but queued to install at the next login: omacvm apply"
  else skip "Omanotch" "off (chosen at setup)"; fi
elif [[ $OMANOTCH == on && ! -x $H/.local/bin/notchcast ]]; then
  if [[ -f /etc/systemd/user/omacvm-omanotch.service ]]; then bad "Omanotch" "chosen, not installed yet: it installs at the next login"
  else bad "Omanotch" "chosen, not set up (omacvm enable omanotch)"; fi
elif [[ $TYPE == app ]] && grep -qs '^OMACVM_FULLPANEL=' /run/omacvm/host.env; then
  # OmacVM.app's FullPanel start (#339): the VM's full screen covers the
  # strip and its bar sits there itself; notchcast stays off for this boot.
  if user_active notchcast.service || pgrep -u "$U" -x notchcast >/dev/null || connected_to "$HOST" 47811; then
    bad "Omanotch" "notchcast runs on a start with full screen including notch: it would stream a second bar (omacvm apply brings the unit that stays off)"
  else ok "Omanotch" "not needed (full screen including notch): notchcast idle until the next start with the notch via Omanotch"; fi
  st=$(as_user omarchy-shell notchbar state 2>/dev/null)
  fp=$(jq -r '.fullpanel // empty' <<<"$st" 2>/dev/null)
  bars=$(jq -r '[.bars[]? | select(.[1] == "fullpanel") | "\(.[0]) (\(.[3]) px)"] | join(", ")' <<<"$st" 2>/dev/null)
  case $fp in
    strip) ok "full screen" "including notch: the bar sits in the strip beside the notch on ${bars:-the built-in display}" ;;
    waiting) skip "full screen" "including notch: the bar waits for full screen on the MacBook's display (windowed now, or macOS kept the window below the notch: omacvm check on the Mac says)" ;;
    off) bad "full screen" "including notch this start, but the bar is Omanotch's older one or did not read host.env (omacvm apply, then omarchy-restart-shell)" ;;
    *) skip "full screen" "including notch: the bar does not answer (is the Omarchy shell running? is Omanotch's bar the one in use?)" ;;
  esac
elif systemctl --user -M "$U@" list-unit-files notchcast.service 2>/dev/null | grep -q notchcast; then
  if connected_to "$HOST" 47811; then ok "Omanotch" "streaming the bar to the Mac"
  elif [[ $TYPE == app ]]; then bad "Omanotch" "notchcast is not connected to $HOST:47811 (is Omanotch running on the Mac, and new enough for OmacVM.app? omacvm check on the Mac says$(restart_hint port))"
  else bad "Omanotch" "notchcast is not connected to $HOST:47811 (Omanotch on the Mac serves one VM at a time: is it running, or is another VM connected?)"; fi
  # The hidden NOTCH output sits on the built-in display (OmacVM.app: right
  # above it), and the bar parked under the strip is that display's (else the
  # MacBook shows two bars). OmacVM.app with external displays says which
  # output that is.
  b=$(cat "$RUN/omacvm/builtin" 2>/dev/null || echo Virtual-1)
  mons=$(as_user hyprctl monitors all -j 2>/dev/null)
  at() { jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.x),\(.y),\(.width)"' <<<"$mons" 2>/dev/null; }
  st=$(as_user omarchy-shell notchbar state 2>/dev/null)
  parked=$(jq -r '.parked' <<<"$st" 2>/dev/null); pscreen=$(jq -r '.screen' <<<"$st" 2>/dev/null)
  if [[ -z $(at NOTCH) || -z $(at "$b") ]]; then skip "notch display" "no NOTCH or $b output now"
  elif ! spot=$(notch_spot "$mons" "$b" "$TYPE") || [[ -z $spot ]]; then
    bad "notch display" "NOTCH is not on $b, the built-in display, nor right above it (journalctl --user -u notchcast)"
  elif [[ $parked == true && $pscreen != "$b" ]]; then bad "notch display" "the bar on $pscreen is parked, not $b's: two bars on the MacBook"
  elif beat=$(tr -cd 0-9 2>/dev/null < "$H/.local/state/omanotch/beat") &&
       [[ $parked != true && -n $beat && $(cut -d' ' -f1 "$H/.local/state/omanotch/park" 2>/dev/null) == 1 ]] &&
       (( $(date +%s%3N) - beat < 15000 )); then
    bad "notch display" "the strip shows the bar but $b's own bar is not parked: two bars on the MacBook (omarchy-restart-shell)"
  elif [[ $(cut -d' ' -f1 "$H/.local/state/omanotch/park" 2>/dev/null) == 1 && -n $beat ]] &&
       (( $(date +%s%3N) - beat < 15000 )) &&
       [[ $(as_user hyprctl layers -j 2>/dev/null | jq --arg n "$b" --argjson m "$(jq -c --arg n "$b" '.[] | select(.name == $n)' <<<"$mons" 2>/dev/null || echo null)" \
            '[(.[$n].levels // {})[][] | select(.namespace == "omarchy-bar" and .h >= 8 and $m != null
              and .y < $m.y + $m.height / $m.scale and .y + .h > $m.y)] | length' 2>/dev/null) -gt 0 ]]; then
    # What Hyprland composites, whatever the bar says about itself.
    bad "notch display" "the strip shows the bar and a bar is also on $b: two bars on the MacBook (omarchy-restart-shell)"
  else ok "notch display" "$b$([[ $spot == above ]] && echo ", NOTCH right above it")$([[ $parked == true ]] && echo ", its bar in the strip")"; fi
else skip "Omanotch" "not installed (omacvm enable omanotch, on a MacBook with a notch)"; fi

section "Control centre"
FEATURE=control-centre
if [[ $CONTROL == on ]]; then
  check "omacvm" "/usr/local/bin/omacvm opens the control centre" test -x /usr/local/bin/omacvm
  # OmacVM's own copy (control/vendor), checked as shipped and loaded once (nothing written).
  if tx=$(python3 -I /usr/local/share/omacvm/control/omacvm_cc/vendor.py --check 2>&1); then ok "Textual" "$tx"
  else bad "Textual" "$(tail -n1 <<<"$tx" | cut -c1-200): omacvm shows plain text and offers a repair from the Mac"; fi
  check "checks for it" "omacvm-check.socket" systemctl is-active -q omacvm-check.socket
  if grep -q '"omacvm": {' "$H/.config/omarchy/extensions/omarchy-menu.jsonc" 2>/dev/null; then ok "Omarchy menu" "OmacVM row"
  else bad "Omarchy menu" "no OmacVM row in ~/.config/omarchy/extensions/omarchy-menu.jsonc (omacvm apply)"; fi
  layout=$(jq -r '[.bar.layout[]?[]?.id] | join(" ")' "$H/.config/omarchy/shell.json" 2>/dev/null)
  if [[ " $layout " == *" omacvm.control "* ]]; then ok "bar item" "omacvm.control"
  elif grep -qx omacvm.control "$H/.local/state/omacvm/pending-plugins" 2>/dev/null; then bad "bar item" "queued, not enabled yet (log out and in)"
  else skip "bar item" "omacvm.control is not in the bar (Omarchy's bar settings add it back)"; fi
else skip "control centre" "off (on the Mac: omacvm enable control-centre)"; fi

(( TSV )) && exit $(( fails ? 1 : 0 ))
echo
(( fails )) && { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
