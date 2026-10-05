#!/bin/bash
# OmacVM, guest side check: is every feature in place and working right now?
# Run as root inside the VM while the desktop user is logged in (check.sh on
# the Mac does that over SSH):
#   guest/check.sh --user NAME [--tsv]
# One line per feature (ok / FAIL / skip); exits 1 if anything failed. --tsv:
# "status<TAB>name<TAB>detail<TAB>human" lines (human = 1: only a person can fix
# it) and "section<TAB>title", for omacvm check --json.
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
fails=0
line() {   # STATUS LABEL NAME DETAIL [human]
  if (( TSV )); then printf '%s\t%s\t%s\t%s\n' "$1" "$3" "$4" "${5:+1}"
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
FAST_NET=${OMACVM_FEATURE_fast_network:-off}
# Features chosen at setup (VMs set up before the choices existed: the defaults
# they were built with).
BRIDGE=${OMACVM_FEATURE_bridge:-on}; WALLPAPER=${OMACVM_FEATURE_wallpaper:-on}
GESTURES=${OMACVM_FEATURE_gestures:-on}; IDLE_LOCK=${OMACVM_FEATURE_idle_lock:-on}
THP_KERNEL=${OMACVM_FEATURE_thp_kernel:-}; AUTOLOGIN=${OMACVM_FEATURE_autologin:-}
GLIDE=${OMACVM_FEATURE_scroll_momentum:-${OMACVM_FEATURE_glide:-off}}; OMANOTCH=${OMACVM_FEATURE_omanotch:-}
MAC_CLOCK=${OMACVM_FEATURE_mac_clock:-off}; CAMERA=${OMACVM_FEATURE_camera:-off}; BATTERY=${OMACVM_FEATURE_battery:-off}

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
if [[ $TYPE == app ]]; then
  # Which UEFI firmware OmacVM.app started the VM with (SMBIOS BIOS version).
  fw=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
  if [[ $fw == *-omacvm ]]; then ok "firmware" "$fw (Omarchy boot logo)"
  else skip "firmware" "${fw:-unknown}: QEMU's own (TianoCore logo), from an older OmacVM.app or OMACVM_FIRMWARE=qemu"; fi
fi

section "The Mac in the bar (Bridge)"
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
  else bad "Wi-Fi" "the Bridge does not answer at $HOST:47831 (or did not prove it is OmacVM's Bridge: omacvm update)"; fi
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
  if [[ $WALLPAPER == on ]]; then
    if user_active omacvm-wallpaper.path; then ok "wallpaper" "follows the Omarchy theme"
    else bad "wallpaper" "the watcher (omacvm-wallpaper.path) stopped: omacvm apply starts it again"; fi
  else skip "wallpaper" "off (chosen at setup)"; fi
else skip "Bridge" "off (chosen at setup): Omarchy's own Wi-Fi and audio widgets"; fi

section "Camera and microphone"
if [[ $CAMERA == on && $TYPE == parallels ]]; then
  # Parallels' own camera sharing: a USB camera in the VM.
  cams=$(cat /sys/class/video4linux/video*/name 2>/dev/null | sort -u | paste -sd, -)
  if [[ -n $cams ]]; then ok "camera" "Parallels' own: $cams"
  else bad "camera" "no camera in the VM: turn on camera sharing in the VM's settings in Parallels Desktop (it shares the Mac's camera as a USB camera)"; fi
elif [[ $CAMERA == on ]]; then
  if [[ $(cat /sys/class/video4linux/video42/name 2>/dev/null) == "Mac Camera" ]]; then ok "camera device" "/dev/video42, Mac Camera"
  else bad "camera device" "no /dev/video42 (v4l2loopback not loaded: after a kernel update reboot, then omacvm apply)"; fi
  if user_active omacvm-camera.service; then ok "camera service" "omacvm-camera, asks the Mac only while an app reads"
  else bad "camera service" "omacvm-camera.service not running: omacvm apply"; fi
  cs=$(as_user /usr/local/bin/omacvm-camera --status 2>/dev/null)
  if [[ $TYPE == app ]]; then
    if jq -e .port <<<"$cs" >/dev/null 2>&1; then ok "camera from the Mac" "OmacVM.app's camera port"
    else bad "camera from the Mac" "no camera port: start the VM from an OmacVM.app with the camera (omacvm update)"; fi
  else
    case $(jq -r '.permission // empty' <<<"$cs" 2>/dev/null) in
      granted|test) ok "camera from the Mac" "OmacVM Bridge: $(jq -r '.camera // "no camera"' <<<"$cs"), $(jq -r 'if .on then "on, \(.readers) reading" else "off" end' <<<"$cs")" ;;
      not-determined) skip "camera from the Mac" "macOS asks for OmacVM Bridge the first time a Linux app uses the camera" human ;;
      denied|restricted) bad "camera from the Mac" "camera not allowed for OmacVM Bridge (System Settings > Privacy & Security > Camera)" human ;;
      *) bad "camera from the Mac" "the Bridge does not answer /camera/status: $(jq -r '.error // "no answer"' <<<"$cs" 2>/dev/null) (omacvm update)" ;;
    esac
  fi
else skip "camera" "off (chosen at setup)"; fi
mic=$(as_user pactl list short sources 2>/dev/null | awk '$2 !~ /\.monitor$/ { print $2; exit }')
if [[ -n $mic ]]; then ok "microphone" "$mic"
else bad "microphone" "PipeWire has no input: no sound card in the VM? (UTM, Fusion: shut it down, then omacvm apply --vm NAME starts it with one)"; fi

section "The Mac's battery"
if [[ $TYPE == parallels ]]; then
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then skip "battery" "Parallels gives the VM the Mac's battery itself"
  else skip "battery" "none: this Mac has no battery (on a MacBook Parallels passes it itself)"; fi
elif [[ $BATTERY == on ]]; then
  if [[ -w /sys/devices/platform/omacvm-battery/state ]]; then ok "battery module" "omacvm_battery loaded"
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
  elif [[ -d /sys/class/power_supply/ADP0 ]]; then bad "battery in UPower" "no BAT0 yet: the Mac sent no battery (a Mac without one, or the Mac's side is older: omacvm update)"
  else bad "battery in UPower" "no BAT0"; fi
  if jq -e '[.bar.layout[]?[]?.id] | index("omarchy.power")' "$H/.config/omarchy/shell.json" >/dev/null 2>&1; then
    ok "battery in the bar" "Omarchy's power widget (shows while BAT0 is there)"
  else skip "battery in the bar" "Omarchy's power widget is not in the bar (Omarchy's bar settings add it)"; fi
  if grep -qs '^CriticalPowerAction=Ignore' /etc/UPower/UPower.conf.d/90-omacvm-battery.conf; then ok "low battery" "the VM never suspends for it"
  else bad "low battery" "UPower may suspend or power off the VM: omacvm apply"; fi
else skip "battery" "off (omacvm enable battery, on a MacBook)"; fi

section "Trackpad and keyboard"
if [[ $GESTURES == on ]]; then
  if systemctl is-active -q omacvm-gestures; then
    if connected_to "$HOST" 47830; then ok "gestures" "connected to the Mac"
    else bad "gestures" "service runs but is not connected to $HOST:47830"; fi
  else bad "gestures" "omacvm-gestures.service not running"; fi
elif systemctl is-active -q omacvm-gestures; then
  bad "gestures" "off, but omacvm-gestures.service runs and talks to the Mac: omacvm apply"
fi
if [[ $GESTURES == on ]]; then
  check "virtual trackpad" "Magic Trackpad (OmacVM)" ev_device "Apple Inc. Magic Trackpad (OmacVM)"
  if grep -rqs '^hl.gesture({ fingers = 3' "$H/.config/hypr/"; then ok "workspace swipes" "3/4-finger gestures configured"
  else bad "workspace swipes" "no hl.gesture lines in ~/.config/hypr"; fi
else skip "trackpad gestures" "off (chosen at setup): macOS keeps its swipes"; fi
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
else skip "scroll momentum" "off (experimental, opt-in: omacvm enable scroll-momentum)"; fi
if [[ $TYPE == utm || $TYPE == fusion || $TYPE == app ]]; then
  if [[ $GESTURES == on ]]; then
    check "Cmd as Super" "OmacVM keyboard (Mac shortcuts)" ev_device "OmacVM keyboard (Mac shortcuts)"
  else skip "Cmd as Super" "comes with trackpad gestures, which are off (omacvm enable gestures)"; fi
fi
check "Cmd+V paste" "Universal paste binding" grep -qs '"Universal paste"' "$H/.config/hypr/bindings.lua"
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
    if [[ $FAST_NET == on ]]; then ok "fast network" "vmnet, ${a%/*}"
    else bad "fast network" "the VM is on vmnet, but the feature is off here: omacvm enable fast-network"; fi
  elif [[ $FAST_NET == on ]]; then
    bad "fast network" "on, but the VM got QEMU's user network (the app says why: omacvm check on the Mac)"
  else skip "fast network" "off (experimental: omacvm enable fast-network)"; fi
  check "power key" "Quit on the Mac shuts down" test -f /etc/systemd/logind.conf.d/90-omacvm-app-power.conf
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
  r=$(as_user glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
  [[ -z $r ]] && r=$(as_user eglinfo -B 2>/dev/null | sed -n 's/^OpenGL core profile renderer: //p;s/^OpenGL renderer: //p' | head -1)
  case $r in
    *virgl*) ok "GPU" "$r" ;;
    "") skip "GPU" "no glxinfo/eglinfo to ask (mesa-utils)" ;;
    *) bad "GPU" "software rendering: $r" ;;
  esac
  # Video decoding on the Mac's media engine (an app with it lists decoders).
  drv=virtio_gpu; [[ -f /usr/local/lib/dri/omacvm_drv_video.so ]] && drv=omacvm
  # The shim prints the Mac's per-VM limit (past it, players decode on the CPU).
  va=$(as_user env LIBVA_DRIVER_NAME=$drv LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri \
      OMACVM_VA_DEBUG=1 vainfo --display drm 2>&1)
  v=$(sed -n 's/^[[:space:]]*VAProfile\([A-Za-z0-9]*\)[[:space:]]*:[[:space:]]*VAEntrypointVLD$/\1/p' <<<"$va" | tr '\n' ' ')
  lim=$(sed -n 's/^omacvm_drv_video: the Mac keeps at most \([1-9][0-9]*\) decoders.*/\1/p' <<<"$va" | head -1)
  if [[ -n $v ]]; then ok "video decoding" "the Mac's media engine: $v${lim:+(at most $lim at once, more decode on the CPU)}"
  elif ! command -v vainfo >/dev/null; then skip "video decoding" "no vainfo (omacvm apply installs it)"
  else skip "video decoding" "no decoders (OmacVM.app older than the video decoding?)"; fi
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
  elif command -v vainfo >/dev/null; then skip "video encoding" "none offered (OmacVM.app older than the video encoding?)"; fi ;;
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
if [[ $IDLE_LOCK == off ]]; then
  if [[ -f $H/.local/state/omarchy/indicators/stay-awake ]]; then ok "screensaver and lock" "off: the Mac's lock protects the VM"
  else bad "screensaver and lock" "chosen off, but Omarchy's Stay Awake is not set"; fi
else ok "screensaver and lock" "Omarchy's own, after idle"; fi
[[ -f /etc/sddm.conf.d/20-omacvm-autologin.conf ]] && ok "autologin" "on" || ok "autologin" "off"
if [[ $MAC_CLOCK == on ]]; then
  f=$(jq -r '.bar.layout.right[-1] | select(.id == "omarchy.clock") | .format' "$H/.config/omarchy/shell.json" 2>/dev/null)
  if [[ -n $f ]]; then ok "the Mac's clock" "far right, $f"
  elif [[ -s $H/.local/state/omacvm/pending-clock ]]; then bad "the Mac's clock" "set at the next login"
  else bad "the Mac's clock" "not at the far right of the bar (omacvm apply)"; fi
fi

section "Omanotch"
if [[ $OMANOTCH == on && ! -x $H/.local/bin/notchcast ]]; then
  if [[ -f /etc/systemd/user/omacvm-omanotch.service ]]; then bad "Omanotch" "chosen, not installed yet: it installs at the next login"
  else bad "Omanotch" "chosen, not set up (omacvm enable omanotch)"; fi
elif systemctl --user -M "$U@" list-unit-files notchcast.service 2>/dev/null | grep -q notchcast; then
  if connected_to "$HOST" 47811; then ok "Omanotch" "streaming the bar to the Mac"
  elif [[ $TYPE == app ]]; then bad "Omanotch" "notchcast is not connected to $HOST:47811 (is Omanotch running on the Mac, and new enough for OmacVM.app? omacvm check on the Mac says)"
  else bad "Omanotch" "notchcast is not connected to $HOST:47811 (Omanotch on the Mac serves one VM at a time: is it running, or is another VM connected?)"; fi
  # The hidden NOTCH output sits on the built-in display, and the bar parked
  # under the strip is that display's (else the MacBook shows two bars).
  # OmacVM.app with external displays says which output that is.
  b=$(cat "$RUN/omacvm/builtin" 2>/dev/null || echo Virtual-1)
  mons=$(as_user hyprctl monitors all -j 2>/dev/null)
  at() { jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.x),\(.y),\(.width)"' <<<"$mons" 2>/dev/null; }
  st=$(as_user omarchy-shell notchbar state 2>/dev/null)
  parked=$(jq -r '.parked' <<<"$st" 2>/dev/null); pscreen=$(jq -r '.screen' <<<"$st" 2>/dev/null)
  if [[ -z $(at NOTCH) || -z $(at "$b") ]]; then skip "notch display" "no NOTCH or $b output now"
  elif [[ $(at NOTCH) != "$(at "$b")" ]]; then bad "notch display" "NOTCH is not on $b, the built-in display (journalctl --user -u notchcast)"
  elif [[ $parked == true && $pscreen != "$b" ]]; then bad "notch display" "the bar on $pscreen is parked, not $b's: two bars on the MacBook"
  elif beat=$(tr -cd 0-9 < "$H/.local/state/omanotch/beat" 2>/dev/null) &&
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
  else ok "notch display" "$b$([[ $parked == true ]] && echo ", its bar in the strip")"; fi
else skip "Omanotch" "not installed (omacvm enable omanotch, on a MacBook with a notch)"; fi

(( TSV )) && exit $(( fails ? 1 : 0 ))
echo
(( fails )) && { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
