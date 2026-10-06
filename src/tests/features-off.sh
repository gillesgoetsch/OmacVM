#!/bin/bash
# A feature switched off is off on every route: nothing of it runs in the VM,
# nothing in the VM connects to the Mac for it, the Mac side does not serve
# it, and the checks say "off". No VM needed: the VM side's off steps
# (guest/off.sh) run in a scratch folder with systemctl and the session
# replaced; the Mac side's lines run with their helpers replaced.
#   src/tests/features-off.sh
# Every feature in src/features.tsv must be in the table below: a new feature
# says here what off means for it.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---------- every feature is covered ----------
# name: how off is made sure of (tested below, or why there is nothing to test)
covered="
bridge:off.sh bridge_off; no Bridge port from OmacVM.app
wallpaper:off.sh wallpaper_off (its watcher talks to the Bridge)
gestures:off.sh gestures_off; apply skips Gestures; no Gestures port from OmacVM.app
scroll-momentum:inside the gestures daemon; needs gestures (features_fix)
omanotch:off.sh omanotch_off, also an install queued for the next login; no Omanotch port from OmacVM.app
mac-clock:the Mac's format is read only when on (apply); clock.sh off, also a queued clock
camera:camera/guest/install.sh off on every apply; OmacVM.app does not serve the camera port
battery:battery/guest/install.sh off on every apply; OmacVM.app does not serve the battery port
external-brightness:install.sh removes OmacVM's ddcutil on every apply; apply sets the Bridge's external_brightness false, so no DDC (src/tests/external-brightness.sh)
chromium-video:vdec/guest/install.sh off on every apply of an app VM; never on the other routes; nothing of it talks to the Mac
control-centre:control/guest/install.sh off removes omacvm, its check socket, menu row and bar item (install.sh runs it while any of them is there); nothing left in the VM asks the Mac
no-idle-lock:nothing of it talks to the Mac; off is Omarchy's own screensaver and lock
autologin:nothing of it talks to the Mac
thp-kernel:nothing of it talks to the Mac
fast-network:apply takes the Mac's service off when no VM has it (src/net/mac/test.sh)
vulkan:apply removes the VM's vulkan file (no Venus device from the next start) and venus/install.sh --remove; nothing of it talks to the Mac (src/tests/vulkan-feature.sh)
x86-apps:x86/guest/install.sh off removes OmacVM's box64 package and its binfmt rule on every apply; nothing of it talks to the Mac (src/tests/x86-apps.sh)
"
while IFS=$'\t' read -r name _; do
  [[ -z $name || $name == \#* ]] && continue
  grep -q "^$name:" <<<"$covered" && echo "ok   $name: in this test's table" ||
    { echo "FAIL $name: not in src/tests/features-off.sh's table: say what off means for it"; fail=1; }
done < "$R/src/features.tsv"

# ---------- the VM side: guest/off.sh in a scratch folder ----------
# off STATE-SETUP FUNCTION: runs it as guest/install.sh would; CALLS has what
# it asked of systemd and the session, OUT what it logged.
U=me H=/home/me
ROOT=$T/root CALLS=$T/calls OUT=$T/out
reset_root() { rm -rf "$ROOT" "$CALLS" "$OUT"; mkdir -p "$ROOT$H/.config/hypr" "$ROOT/etc/systemd/user"; : > "$CALLS"; : > "$OUT"; }
run_off() {   # FUNCTION [SESSION=0|1] [SERVICE=enabled|active|none]
  ( SESSION=${2:-0} SERVICE=${3:-none}
    log() { echo "$*" >> "$OUT"; }
    user_ctl() { echo "user_ctl $*" >> "$CALLS"; }
    systemctl() {
      case "$1 $2" in
        "is-enabled -q") [[ $SERVICE == enabled ]] ;;
        "is-active -q") [[ $SERVICE == enabled || $SERVICE == active ]] ;;
        *) echo "systemctl $*" >> "$CALLS" ;;
      esac
    }
    in_session() { echo "in_session $*" >> "$CALLS"; (( SESSION )); }
    pkill() { echo "pkill $*" >> "$CALLS"; }
    chown() { :; }
    restart_shell_later() { echo "restart-shell" >> "$CALLS"; }
    /repo/guest/omanotch-notifications.sh() { :; }
    # /repo's Python helpers run from this checkout.
    SRC=$R/src; python3() { echo "python3 $*" >> "$CALLS"; command python3 "${@/#\/repo\//$SRC/}"; }
    # shellcheck source=../guest/off.sh
    source "$R/src/guest/off.sh"
    R=/repo   # this copy of src/ in the VM
    "$1" )
}
has() { [[ -e $ROOT$1 || -L $ROOT$1 ]] && echo yes || echo no; }
called() { grep -qF -- "$1" "$CALLS" && echo yes || echo no; }
link() { mkdir -p "$(dirname "$ROOT$1")"; ln -sf "$2" "$ROOT$1"; }
file() { mkdir -p "$(dirname "$ROOT$1")"; printf '%s\n' "${2:-x}" > "$ROOT$1"; }

# Gestures: the daemon is stopped and disabled whatever state it is in.
for s in enabled active; do
  reset_root; run_off gestures_off 0 "$s"
  expect "gestures off ($s daemon): disabled and stopped" yes "$(called "systemctl disable --now omacvm-gestures")"
done
reset_root; run_off gestures_off 0 none
expect "gestures off, no daemon: nothing" "" "$(cat "$OUT" "$CALLS")"

# Omanotch queued for the next login, not built yet (the RC3 bug: it built
# itself at the next login although off).
reset_root
file /etc/systemd/user/omacvm-omanotch.service
link /etc/systemd/user/graphical-session.target.wants/omacvm-omanotch.service /etc/systemd/user/omacvm-omanotch.service
run_off omanotch_off
expect "omanotch off, queued: says so" "Omanotch: off" "$(cat "$OUT")"
expect "omanotch off, queued: the queued install is gone" no "$(has /etc/systemd/user/omacvm-omanotch.service)"
expect "omanotch off, queued: not enabled for any user" no "$(has /etc/systemd/user/graphical-session.target.wants/omacvm-omanotch.service)"
expect "omanotch off, queued: disabled" yes "$(called "systemctl --global disable omacvm-omanotch.service")"

# Omanotch built and running, nobody logged in (its uninstall needs the session).
reset_root
file "$H/.local/bin/notchcast"; file "$H/.local/bin/omanotch-display-panel"; file "$H/.config/systemd/user/notchcast.service"
file "$H/.config/systemd/user/notchcast.service.d/omacvm-host.conf"
link "$H/.config/systemd/user/graphical-session.target.wants/notchcast.service" "$H/.config/systemd/user/notchcast.service"
file "$H/.config/hypr/notchbar.lua"; file "$H/.local/state/omacvm/omanotch"; file "$H/.local/state/omanotch/expect"
file /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook
file "$H/.config/omarchy/plugins/omanotch.monitor/manifest.json" '{"id": "omanotch.monitor", "omarchy": {"clonedFrom": "omarchy.monitor"}}'
file "$H/.config/omarchy/shell.json" '{"bar": {"layout": {"right": [{"id": "omanotch.monitor"}, {"id": "omarchy.clock"}]}}}'
printf '%s\n' 'require("hypr.other")' '' '-- omarchy-notch-bar: hidden output for the macOS notch helper.' 'require("hypr.notchbar")' > "$ROOT$H/.config/hypr/hyprland.lua"
run_off omanotch_off 0
expect "omanotch off, built: its uninstall tried in the session" yes "$(called "in_session bash /repo/omanotch/guest/uninstall.sh")"
for p in "$H/.local/bin/notchcast" "$H/.local/bin/omanotch-display-panel" "$H/.config/systemd/user/notchcast.service" "$H/.config/systemd/user/notchcast.service.d" \
         "$H/.config/systemd/user/graphical-session.target.wants/notchcast.service" "$H/.config/hypr/notchbar.lua" \
         "$H/.local/state/omanotch/expect" /etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook "$H/.config/omarchy/plugins/omanotch.monitor"; do
  expect "omanotch off, built, no session: $p gone" no "$(has "$p")"
done
expect "omanotch off, no session: Omarchy's display panel back in the bar" "omarchy.monitor omarchy.clock" \
  "$(jq -r '[.bar.layout.right[].id] | join(" ")' "$ROOT$H/.config/omarchy/shell.json")"
expect "omanotch off: hyprland.lua no longer loads notchbar" "$(printf '%s\n' 'require("hypr.other")' '')" "$(cat "$ROOT$H/.config/hypr/hyprland.lua")"
expect "omanotch off: notchcast stopped" yes "$(called "user_ctl disable --now notchcast.service")"
: > "$OUT"; : > "$CALLS"; run_off omanotch_off 0
expect "omanotch off again: nothing to do" "" "$(cat "$OUT" "$CALLS")"

# The Bridge, nobody logged in: services, client, queued widgets; the widgets
# in the bar are disabled at the next login.
reset_root
for b in omacvm-bridge omacvm-bridge-osd omacvm-bridge-events omarchy-toggle-nightlight; do file "/usr/local/bin/$b"; done
for u in omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service omacvm-plugins.service; do file "/etc/systemd/user/$u"; done
link "$H/.config/systemd/user/graphical-session.target.wants/omacvm-bridge-osd.service" /etc/systemd/user/omacvm-bridge-osd.service
link "$H/.config/systemd/user/sockets.target.wants/omacvm-bridge-events.socket" /etc/systemd/user/omacvm-bridge-events.socket
file "$H/.local/state/omacvm/pending-plugins" "$(printf '%s\n' omacvm.workspaces omacvm.wifi omacvm.audio)"
file "$H/.config/omarchy/shell.json" '{"bar": {"layout": {"right": [{"id": "omacvm.wifi"}, {"id": "omarchy.clock"}]}}}'
run_off bridge_off 0
expect "bridge off: says so" "bridge: off" "$(cat "$OUT")"
for p in /usr/local/bin/omacvm-bridge /usr/local/bin/omacvm-bridge-osd /usr/local/bin/omacvm-bridge-events \
         /etc/systemd/user/omacvm-bridge-osd.service /etc/systemd/user/omacvm-bridge-events.socket \
         "$H/.config/systemd/user/graphical-session.target.wants/omacvm-bridge-osd.service" \
         "$H/.config/systemd/user/sockets.target.wants/omacvm-bridge-events.socket"; do
  expect "bridge off, no session: $p gone" no "$(has "$p")"
done
expect "bridge off: queued widgets not enabled at the next login" omacvm.workspaces "$(cat "$ROOT$H/.local/state/omacvm/pending-plugins")"
expect "bridge off, no session: widgets disabled at the next login" 5 "$(grep -c . "$ROOT$H/.local/state/omacvm/pending-plugins-off")"
expect "bridge off, no session: omacvm-plugins runs at the next login" yes "$(has "$H/.config/systemd/user/graphical-session.target.wants/omacvm-plugins.service")"
expect "bridge off: widgets streaming from the Mac stopped" yes "$(called "pkill -u me -f -- /usr/local/bin/omacvm-bridge")"
: > "$OUT"; run_off bridge_off 0
expect "bridge off again, widgets still in the bar: queued once" "bridge: off 5" "$(cat "$OUT") $(grep -c . "$ROOT$H/.local/state/omacvm/pending-plugins-off")"
reset_root; file /usr/local/bin/omacvm-bridge
run_off bridge_off 1
expect "bridge off, session: widgets disabled now" yes "$(called "in_session bash -c")"
expect "bridge off, session: nothing queued" no "$(has "$H/.local/state/omacvm/pending-plugins-off")"
reset_root; run_off bridge_off 0
expect "bridge off, no Bridge: nothing" "" "$(cat "$OUT" "$CALLS")"
grep -q 'pending-plugins-off' "$R/src/lib/omacvm-plugins" && echo "ok   omacvm-plugins disables the queued widgets" ||
  { echo "FAIL omacvm-plugins does not read pending-plugins-off"; fail=1; }

# The wallpaper's watcher, enabled for the user only (no user manager to ask).
reset_root
file /usr/local/bin/omacvm-wallpaper; file /etc/systemd/user/omacvm-wallpaper.path; file /etc/systemd/user/omacvm-wallpaper.service
link "$H/.config/systemd/user/default.target.wants/omacvm-wallpaper.path" /etc/systemd/user/omacvm-wallpaper.path
link "$H/.config/systemd/user/graphical-session.target.wants/omacvm-wallpaper.service" /etc/systemd/user/omacvm-wallpaper.service
run_off wallpaper_off 0
for p in /usr/local/bin/omacvm-wallpaper /etc/systemd/user/omacvm-wallpaper.path \
         "$H/.config/systemd/user/default.target.wants/omacvm-wallpaper.path" \
         "$H/.config/systemd/user/graphical-session.target.wants/omacvm-wallpaper.service"; do
  expect "wallpaper off, no session: $p gone" no "$(has "$p")"
done

# guest/install.sh runs the off steps whenever a feature is off (not only when
# one marker of it is there).
inst=$R/src/guest/install.sh
# Each block starts "if ! want F" (a repair of other features only: nothing),
# then "elif [[ ${F[F]} == on ]]" and a plain else.
for f in gestures bridge wallpaper omanotch; do
  b=$(awk -v f="$f" 'index($0, "elif [[ ${F[" f "]} == on ]]; then") == 1 {on = 1} on {print} on && /^fi$/ {exit}' "$inst")
  [[ $(grep -c '^else$' <<<"$b") == 1 && $(grep -cE "^  ${f}_off( |$)" <<<"$b") == 1 && $(tail -n +2 <<<"$b" | grep -c '^elif') == 0 ]] &&
    echo "ok   install.sh: $f off -> ${f}_off, always" || { echo "FAIL install.sh: $f off does not always run ${f}_off"; fail=1; }
done
b=$(awk 'index($0, "elif [[ ${F[battery]} == on ]]; then") == 1 {on = 1} on {print} on && /^fi$/ {exit}' "$inst")
[[ $b == *$'\nelse\n'*'battery/guest/install.sh" off'* && $(tail -n +2 <<<"$b") != *elif* ]] && echo "ok   install.sh: battery off -> its installer's off, always" ||
  { echo "FAIL install.sh: battery off does not always run its installer's off"; fail=1; }
grep -q '^ *"$R/camera/guest/install.sh" "$U" "$TYPE" "${F\[camera\]}"' "$inst" && echo "ok   install.sh: camera's installer on every apply, with the choice" ||
  { echo "FAIL install.sh: camera's installer not run with the choice"; fail=1; }

# The control centre's repair (install.sh --only F): a repair of other
# features leaves Gestures alone; one of scroll momentum (which needs
# gestures) still applies gestures off.
block=$(awk '/^if ! want gestures && ! want scroll-momentum; then$/ {on = 1} on {print} on && /^fi$/ {exit}' "$inst")
[[ $block == *'gestures/guest/install.sh'* && $block == *'gestures_off'* ]] ||
  { echo "FAIL install.sh: gestures block (repair mode) not found"; fail=1; }
block=${block//'${F[gestures]}'/'$FG'}   # macOS's bash 3.2: no associative arrays
repair() {   # GESTURES ONLY -> what the block did
  ( FG=$1 ONLY=$2 R=/repo U=me CALLS=""
    log() { :; }
    want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }   # as in src/guest/install.sh
    gestures_off() { CALLS+="gestures_off "; }
    /repo/gestures/guest/install.sh() { CALLS+="install "; }
    eval "$block"
    echo "${CALLS% }" )
}
expect "repair of the Bridge only: gestures left alone" "" "$(repair off ,bridge,)"
expect "repair of scroll momentum, gestures off: gestures_off" gestures_off "$(repair off ,scroll-momentum,)"
expect "repair of gestures, on: installed" install "$(repair on ,gestures,)"
expect "full apply, gestures off: gestures_off" gestures_off "$(repair off "")"

# clock.sh off: also a clock queued for the next login goes.
mkdir -p "$T/bin" "$T/home/.local/state/omacvm"
printf '#!/bin/sh\necho "me:x:1:1::%s:/bin/bash"\n' "$T/home" > "$T/bin/getent"; chmod +x "$T/bin/getent"
echo "EEE HH:mm" > "$T/home/.local/state/omacvm/pending-clock"
PATH="$T/bin:$PATH" bash "$R/src/clock/guest/clock.sh" me off >/dev/null 2>&1
expect "mac-clock off: the queued clock goes" no "$( [[ -e $T/home/.local/state/omacvm/pending-clock ]] && echo yes || echo no)"

# ---------- omacvm check in the VM: off says off ----------
# The Omanotch rows (check.sh) with the VM's state replaced.
om=$(awk '/^section "Omanotch"$/ {on = 1; next} on && /^FEATURE=/ {next} on && /^elif \[\[ \$OMANOTCH == on/ {exit} on {print}' "$R/src/guest/check.sh")
[[ $om == 'if [[ $OMANOTCH == off ]]; then'* ]] || { echo "FAIL check.sh: no Omanotch off rows"; fail=1; }
om_check() {   # NOTCHCAST(active|none) QUEUED(enabled|disabled) -> the row
  ( A=$1 Q=$2 OMANOTCH=off HOST=10.0.2.2 U=me
    user_active() { [[ $A == active ]]; }
    pgrep() { [[ $A == active ]]; }
    connected_to() { false; }
    systemctl() { echo "$Q"; }
    bad() { echo "fail: $2"; }
    skip() { echo "skip: $2"; }
    eval "$om"$'\nfi' )
}
expect "check, omanotch off: off" "skip: off (chosen at setup)" "$(om_check none disabled)"
expect "check, omanotch off, notchcast runs: fails" "fail: off, but notchcast runs and talks to the Mac: omacvm apply" "$(om_check active disabled)"
expect "check, omanotch off, install queued: fails" "fail: off, but queued to install at the next login: omacvm apply" "$(om_check none enabled)"
for r in '"wallpaper" "off, but' '"Bridge" "off, but' '"camera" "off, but' '"battery" "off, but' "\"the Mac's clock\" \"off (chosen"; do
  grep -qF "$r" "$R/src/guest/check.sh" && echo "ok   check.sh: $r" || { echo "FAIL check.sh has no $r row"; fail=1; }
done

# ---------- the Mac side ----------
# omacvm apply: Gestures and the token only with gestures on.
mac=$(grep -E 'skip-gestures\)|bridge_token_ensure; fi' "$R/src/cmd/apply.sh")
[[ $(wc -l <<<"$mac") == *2 ]] || { echo "FAIL apply.sh gestures lines not found"; exit 1; }
apply() {   # TYPE GESTURES -> the installer's gestures argument and whether the token goes in
  ( TYPE=$1 G=$2 TOKEN=1 args=() tok=no
    on() { [[ $1 == gestures && $G == on ]]; }
    bridge_token_ensure() { tok=yes; }
    eval "$mac"
    echo "${args[*]:-none} token=$tok" )
}
for t in utm fusion app; do
  expect "$t, gestures off: Mac side skips Gestures" "--skip-gestures token=no" "$(apply $t off)"
  expect "$t, gestures on: Mac side installs Gestures" "none token=yes" "$(apply $t on)"
done

# OmacVM.app: apply writes the VM's features into its folder, the app opens
# the Mac only for the ones that are on (MacLinks.swift, compiled here).
source "$R/src/lib/app.sh"
mkdir -p "$T/vm"
app_features_write "$T/vm" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on"
expect "app: features written" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on" "$(cat "$T/vm/features")"
app_features_write "$T/vm" "bridge=off gestures=on omanotch=off battery=off camera=on mac-clock=on"
expect "app: unchanged features: status 1" 1 "$?"
# apply.sh runs under set -e: status 1 (unchanged, every re-apply) must not end it.
grep -qE '^ +app_features_write "\$d" "\$\{feats% \}" \|\| true' "$R/src/cmd/apply.sh" &&
  echo "ok   apply.sh: unchanged features do not stop apply (set -e)" ||
  { echo "FAIL apply.sh: app_features_write's status 1 (unchanged) ends apply under set -e"; fail=1; }
if command -v swiftc >/dev/null; then
  cat > "$T/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let l = a.count > 1 ? MacLinks.load(folder: URL(fileURLWithPath: a[1])) : MacLinks()
print("ports=\(l.hostPorts) battery=\(l.battery) camera=\(l.camera) test=\(l.hostPorts(test: true))")
EOF
  if swiftc -O -o "$T/links" "$R/app/app/Sources/OmacVM/MacLinks.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
    expect "app: only gestures' port, camera served, battery not" "ports=47830 battery=false camera=true test=47830>47930" "$("$T/links" "$T/vm")"
    app_features_write "$T/vm" "bridge=off wallpaper=off gestures=off omanotch=off battery=off camera=off"
    expect "app: all off: no port to the Mac, no battery, no camera" "ports= battery=false camera=false test=" "$("$T/links" "$T/vm")"
    app_features_write "$T/vm" "bridge=on gestures=on omanotch=on battery=on camera=on"
    # The test identity: its own helpers' ports, never Omanotch (it has none).
    expect "app: all on" "ports=47811,47830,47831 battery=true camera=true test=47830>47930,47831>47931" "$("$T/links" "$T/vm")"
    mkdir -p "$T/old"
    expect "app: a VM from before (no features file): as before" "ports=47811,47830,47831 battery=true camera=true test=47830>47930,47831>47931" "$("$T/links" "$T/old")"
  else
    echo "FAIL MacLinks.swift does not compile:"; cat "$T/swiftc.log"; fail=1
  fi
else
  echo "skip MacLinks.swift: no swiftc"
fi
# A feature turned on while an app VM runs: the app opens the Mac to it only
# at the VM's next start (libslirp and Runner read the features once). apply
# names it, omacvm check fails with "shut the VM down and start it again".
V=$T/run; mkdir -p "$V/logs"
printf '%s\n' "OmacVM: Mac links: Omanotch on, Gestures on, Bridge on, battery on, camera on" \
  "OmacVM: Mac links: Omanotch off, Gestures on, Bridge off, battery off, camera on" > "$V/logs/qemu.log"
fs="bridge=on gestures=on omanotch=off battery=on camera=off"
expect "app: on, closed since this start (the last line)" "Bridge, battery" "$(app_links_stale "$V" "$fs" on)"
expect "app: off, still served since this start" "camera" "$(app_links_stale "$V" "$fs" off)"
expect "app: features as at the start: nothing" "" "$(app_links_stale "$V" "omanotch=off bridge=off battery=off" on)$(app_links_stale "$V" "omanotch=off bridge=off battery=off" off)"
expect "app: a feature not named is on" "Bridge, battery" "$(app_links_stale "$V" "omanotch=off" on)"
mkdir -p "$T/older/logs"; echo "OmacVM: network: user" > "$T/older/logs/qemu.log"
expect "app: an app from before the line: nothing" "" "$(app_links_stale "$T/older" "$fs" on)"

# apply's lines for a running app VM.
ap=$(awk '/^  # The app reads them only when the VM starts/ {on = 1} on {print} on && /^  fi$/ {exit}' "$R/src/cmd/apply.sh")
[[ $ap == *app_links_stale* ]] || { echo "FAIL apply.sh: no Mac links lines for a running app VM"; fail=1; }
apply_app() {   # RUNNING(0|1) FEATURES -> what apply says
  ( RUN=$1 d=$V feats="$2 "
    app_running_dir() { (( RUN )); }
    info() { echo "$*"; }
    eval "$ap" )
}
expect "apply, running, bridge and battery turned on: names them, says restart" \
  "OmacVM.app: Bridge, battery only from the VM's next start: shut it down and start it again" \
  "$(apply_app 1 "bridge=on gestures=on omanotch=off battery=on camera=on")"
expect "apply, running, camera turned off: says the Mac serves it until the next start" \
  "OmacVM.app: camera off in the VM now; the Mac stops serving it at the VM's next start" \
  "$(apply_app 1 "bridge=off gestures=on omanotch=off battery=off camera=off")"
expect "apply, running, nothing changed: says nothing" "" "$(apply_app 1 "bridge=off gestures=on omanotch=off battery=off camera=on")"
expect "apply, running, unchanged features again: still names them" "OmacVM.app: Bridge only from the VM's next start: shut it down and start it again" \
  "$(apply_app 1 "bridge=on gestures=on omanotch=off battery=off camera=on"; apply_app 1 "bridge=on gestures=on omanotch=off battery=off camera=on" >/dev/null)"
expect "apply, stopped: says nothing (the next start reads them)" "" "$(apply_app 0 "bridge=on gestures=on omanotch=on battery=on camera=on")"
expect "apply: features written" "bridge=on gestures=on omanotch=on battery=on camera=on" "$(cat "$V/features")"

# omacvm check's "Mac links (app)" row.
ck=$(awk '/^# OmacVM.app: what of the Mac this start of the VM may use/ {on = 1} on && /^if \[\[ \$TYPE == app \]\]; then$/ {exit} on {print}' "$R/src/cmd/check.sh")
[[ $ck == *'"Mac links (app)"'* ]] || { echo "FAIL check.sh: no Mac links (app) row"; fail=1; }
check_app() {   # FEATURES -> the row
  ( TYPE=app VM=x F=" $1 "
    app_dir() { echo "$V"; }
    feat() { [[ $F == *" $1=off "* ]] && echo off || echo on; }
    ok() { echo "ok: $2"; }
    bad() { echo "fail: $2"; }
    skip() { echo "skip: $2"; }
    eval "$ck" )
}
expect "check, app: features as at the start: ok" "ok: Omanotch off, Gestures on, Bridge off, battery off, camera on" \
  "$(check_app "omanotch=off bridge=off battery=off")"
expect "check, app: bridge turned on while it runs: fails, says restart" \
  "fail: on, but closed to the VM since its start: Bridge (shut the VM down and start it again)" \
  "$(check_app "omanotch=off battery=off")"
expect "check, app: camera turned off while it runs: fails, says restart" \
  "fail: off for this VM, but the app still serves it: camera (shut the VM down and start it again)" \
  "$(check_app "omanotch=off bridge=off battery=off camera=off")"
expect "check, app: both: one row with both" \
  "fail: off for this VM, but the app still serves it: camera; on, but closed to the VM since its start: Omanotch (shut the VM down and start it again)" \
  "$(check_app "bridge=off battery=off camera=off")"
expect "check, app from before the line: skip" "skip: this OmacVM.app serves every feature to every VM (older than 3.0.0: omacvm update)" "$(V=$T/older check_app "")"

# In the VM: the rows that find no link to the Mac hint at the restart on
# OmacVM.app (not for a port on the fast network, which does not gate them).
rh=$(awk '/^restart_hint\(\) \{$/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
hint() { ( TYPE=$1 HOST=$2; eval "$rh"; restart_hint "${3:-}" ); }
h="; turned on while the VM was running? shut it down and start it again"
expect "guest hint: app, port" "$h" "$(hint app 10.0.2.2 port)"
expect "guest hint: app, battery/camera port" "$h" "$(hint app 192.168.77.1)"
expect "guest hint: app on the fast network, port: none" "" "$(hint app 192.168.77.1 port)"
expect "guest hint: UTM: none" "" "$(hint utm 192.168.64.1 port)"
for r in '"gestures" "service runs but is not connected to $HOST:47830$(restart_hint port)"' \
         'omacvm check on the Mac says$(restart_hint port))"' "OmacVM's Bridge: omacvm update\$(restart_hint port))\"" \
         'with the camera (omacvm update$(restart_hint))"' 'older: omacvm update$(restart_hint))"'; do
  grep -qF -- "$r" "$R/src/guest/check.sh" && echo "ok   guest check.sh hints at the restart: ${r:0:40}" ||
    { echo "FAIL guest check.sh: no restart hint in $r"; fail=1; }
done
grep -q 'env\["OMACVM_SLIRP_HOST_PORTS"\] = links.hostPorts' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  grep -q 'if links.battery { startBattery() }' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  grep -q 'if links.camera { startCamera() }' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  echo "ok   Runner.swift follows MacLinks" || { echo "FAIL Runner.swift does not follow MacLinks"; fail=1; }

# off_lines under set -e: taking out the file's last lines is no failure
# (grep then finds nothing; the control centre's "bridge off" stopped there).
printf 'omacvm.wifi\nomacvm.audio\n' > "$T/pending"
got=$(set -e; ROOT=""; source "$R/src/guest/off.sh" 2>/dev/null; off_lines "$T/pending" omacvm.wifi omacvm.audio; echo "rc=0 left=$(wc -c < "$T/pending" | tr -d ' ')")
expect "off_lines: every line taken out, under set -e" "rc=0 left=0" "$got"

exit $fail
