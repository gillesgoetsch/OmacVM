#!/bin/bash
# Root never writes into the desktop user's home (src/guest/home-files.sh).
# The guest scripts run as root at every omacvm apply, and the home is the
# user's: a program running as the user can put links there. Up to 3.1.24
# root's install -d -o, `>> file; chown`, mktemp + mv, sed -i, rm -rf, ln -sf,
# shell-colors.py's temp file and the Mac folder's mount all followed them
# (~/.config/omacvm-bridge -> /etc made /etc the user's: root at the next
# apply). Review of #465/#468, 2026-10-19.
#   src/tests/home-links.sh        anywhere: no root-style write into the home left in the guest scripts
#   sudo src/tests/home-links.sh   Linux as root: a real user whose home links into a folder of root's;
#                                  the guest scripts run (system paths moved into the test's folder,
#                                  systemd and Omarchy stand-ins); nothing of root's changes, nothing
#                                  secret of root's lands in the home, and a plain home still works
#   sudo OMACVM_SRC=DIR src/tests/home-links.sh   the same against another checkout (an older one fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
T=$(mktemp -d)
LU=omacvm-hometest
cleanup() {
  if [[ $(id -u) == 0 && $(uname) == Linux ]]; then
    local m
    for m in $(awk -v t="$T" 'index($2, t) == 1 { print $2 }' /proc/mounts | sort -r); do umount "$m" 2>/dev/null; done
    for m in $(awk '$2 ~ "^/home/'"$LU"'" { print $2 }' /proc/mounts | sort -r); do umount "$m" 2>/dev/null; done
    id "$LU" >/dev/null 2>&1 && userdel -r "$LU" >/dev/null 2>&1
  fi
  rm -rf "$T"
}
trap cleanup EXIT
chmod 755 "$T"
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# ---------- anywhere: no root-style write into the home is left ----------
# The scripts that run as root and touch the home. A line that chowns to the
# user, installs with the user as owner or writes "$H/..." itself is root
# writing there; home-files.sh's functions write as the user.
lint=$(cd "$SRC" && grep -nE 'chown|install [^#]* -o "?\$(U|user)\b|>>? *"\$H' \
    guest/install.sh guest/off.sh lib/install-plugin.sh clock/guest/clock.sh gestures/guest/glide.sh \
    bridge/guest/touchid.sh app/guest/omacvm-mac-folder */guest/install.sh 2>/dev/null |
  grep -vE ':[0-9]+: *#|-o root|chown -R nobody:|fchown' || true)
expect "no chown, install -o or write to \"\$H...\" as root in the guest scripts" "" "$lint"
lint=$(grep -nE "install [^#]*-o '\\\$U'" "$SRC/cmd/apply.sh" || true)
expect "apply writes nothing into the VM's home with install -o" "" "$lint"

if [[ $(id -u) != 0 || $(uname) != Linux ]] || ! command -v useradd >/dev/null || ! command -v setpriv >/dev/null; then
  echo "skip the real user's links (Linux as root only: sudo $0)"
  exit $fail
fi

# ---------- Linux as root ----------
useradd -m -s /bin/bash "$LU" || { echo "FAIL useradd"; exit 1; }
H=$(getent passwd "$LU" | cut -d: -f6)
SECRET="omacvm-secret-$RANDOM$RANDOM"
# Root's folder the links point into: files, a secret only root reads, a folder.
S=$T/sys
mkdir -p "$S/dir"; echo "root's" > "$S/dir/keep"; echo "a file of root's" > "$S/file"
printf '{"bar":{"layout":{"right":[{"id":"omarchy.clock"},{"id":"omarchy.indicators"}]}}}\n' > "$S/json"
echo "$SECRET" > "$S/secret"; chmod 600 "$S/secret"; chmod 755 "$S" "$S/dir"; chmod 644 "$S/file" "$S/json" "$S/dir/keep"
snapshot() { find "$S" -printf '%P %u %g %m %y\n' | sort; find "$S" -type f -exec sha256sum {} + | sort; }

# This checkout's src/, its system paths moved into the test's folder.
X=$T/root; cp -R "$SRC" "$T/src"; mkdir -p "$X/usr/local/bin" "$X/etc/systemd/user" "$X/usr/local/lib/omacvm"
grep -rlE '/usr/local/bin/|/etc/systemd/' "$T/src" | while IFS= read -r f; do
  sed -i -e "s#/usr/local/bin/#$X/usr/local/bin/#g" -e "s#/etc/systemd/#$X/etc/systemd/#g" "$f"
done
printf '#!/bin/sh\nexit 0\n' > "$T/src/guest/pkg-add"
sed -i "s#/usr/share/omarchy/shell\"#$T/omarchy-shell\"#" "$T/src/guest/shell-colors.py"   # not the VM's own Omarchy
chmod -R a+rX "$T/src"
# Stand-ins: systemd, Omarchy, localectl, hyprctl; sudo runs the command (only
# Omarchy's stand-ins go through it).
B=$T/bin; mkdir -p "$B"
for c in localectl hyprctl omarchy udevadm; do printf '#!/bin/sh\nexit 0\n' > "$B/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$B/omarchy-shell"                    # no shell running
printf '#!/bin/sh\ncase "$1 $2" in "--user -M") exit 1 ;; esac\nexit 0\n' > "$B/systemctl"   # no user manager
printf '#!/bin/bash\n[[ $1 == -u ]] && shift 2\nexec "$@"\n' > "$B/sudo"
chmod 755 "$B"/*
export PATH="$B:$PATH"
G=$T/src

# QML for shell-colors.py: Qt with QtQuick's Color, a plugin clone that needs the pin.
printf 'Module { Component { exports: ["QtQuick/Color 6.12"] } }\n' > "$T/qt.qmltypes"
qml() { printf 'import QtQuick\nimport qs.Commons\nItem { color: Color.bar.text }\n'; }

# video_flags on|off: Chrome's and Brave's video switches, both groups (its marker in the test's folder).
video_flags() {
  local g
  for g in encode decode; do
    OMACVM_VIDEO_FLAGS_MARK=$T/video-flags.json python3 "$G/app/guest/browser-video-encode.py" "$LU" "$1" $g >/dev/null 2>&1
  done
}

# run_all: every guest script with a part in the home, as apply runs them (their
# own failures are fine here: the links make the user's writes fail).
run_all() {
  ( cd "$G/workspaces/guest" && bash ./install.sh "$LU" ) >/dev/null 2>&1
  ( cd "$G/keyboard/guest" && bash ./install.sh "$LU" us ) >/dev/null 2>&1
  ( cd "$G/display/guest" && bash ./install.sh "$LU" ) >/dev/null 2>&1
  ( cd "$G/clipboard/guest" && bash ./install.sh "$LU" ) >/dev/null 2>&1
  bash "$G/gestures/guest/glide.sh" "$LU" on >/dev/null 2>&1
  bash "$G/gestures/guest/glide.sh" "$LU" off >/dev/null 2>&1
  bash "$G/clock/guest/clock.sh" "$LU" on "HH:mm" >/dev/null 2>&1
  bash "$G/clock/guest/clock.sh" "$LU" off >/dev/null 2>&1
  bash "$G/lib/install-plugin.sh" "$LU" "$G/workspaces/plugins/omacvm.workspaces" >/dev/null 2>&1
  python3 "$G/guest/shell-colors.py" --user "$LU" --qmltypes "$T/qt.qmltypes" >/dev/null 2>&1
  video_flags on; video_flags off
  # guest/off.sh, as guest/install.sh sources it.
  ( U=$LU R=$G ROOT=""
    log() { :; }; user_ctl() { return 1; }; in_session() { return 1; }; restart_shell_later() { :; }
    source "$G/guest/off.sh"
    plugins_off_at_login omacvm.wifi; off_lines "$H/.config/hypr/hyprland.lua" x ) >/dev/null 2>&1
  # apply's token and control key (the remote command run here).
  ( U=$LU IP=x; gssh() { shift; /bin/bash -c "$1"; }; die() { exit 1; }
    eval "$(sed -n '/^vm_user_file() {/,/^}/p' "$SRC/cmd/apply.sh")"
    vm_user_file token < "$S/file"; vm_user_file vm-key < "$S/file" ) >/dev/null 2>&1
  OMACVM_MAC_FOLDER_USER=$LU OMACVM_MAC_FOLDER_FS=tmpfs bash "$G/app/guest/omacvm-mac-folder" >/dev/null 2>&1
  OMACVM_MAC_FOLDER_USER=$LU bash "$G/app/guest/omacvm-mac-folder" --stop >/dev/null 2>&1
}
fresh_home() {   # the user's own folders, as Omarchy has them
  local d
  for d in "$H/Mac" "$H/.config" "$H/.local" "$H/.cache"; do
    umount "$d" 2>/dev/null; rm -rf "$d"
  done
  mkdir -p "$H/.config/hypr" "$H/.config/omarchy/plugins" "$H/.config/systemd/user" "$H/.local/state/omacvm"
  chown -R "$LU:" "$H/.config" "$H/.local"
}
plant() {   # LINK TARGET: a link of the user's
  mkdir -p "$(dirname "$1")"; rm -rf "$1"; ln -s "$2" "$1"; chown -h "$LU:" "$1"
}
after() {   # WHAT: root's folder as it was, nothing secret of root's in the home
  expect "$1: nothing of root's changed" "$before" "$(snapshot)"
  expect "$1: nothing of root's secret in the home" "" "$(grep -rlF "$SECRET" "$H" 2>/dev/null)"
}
before=$(snapshot)

# 1. Files in the home linked to root's files (and the temp names root used).
fresh_home
for f in hyprland.lua input.lua autostart.lua monitor_workspaces.lua omacvm_glide.lua .omacvm_glide.lua.new .monitor_workspaces.lua.new; do
  plant "$H/.config/hypr/$f" "$S/file"
done
plant "$H/.config/hypr/bindings.lua" "$S/secret"
plant "$H/.config/hypr/monitors.lua" "$S/secret"
for f in glide-flags pending-plugins pending-plugins-off pending-clock restart-shell; do plant "$H/.local/state/omacvm/$f" "$S/file"; done
plant "$H/.config/chromium-flags.conf" "$S/file"
plant "$H/.config/chrome-flags.conf" "$S/file"; plant "$H/.config/brave-flags.conf" "$S/secret"
plant "$H/.config/omarchy/shell.json" "$S/json"
plant "$H/.config/omacvm/clock-before.json" "$S/secret"
plant "$H/.config/omacvm-bridge/token" "$S/secret"; plant "$H/.config/omacvm-bridge/vm-key" "$S/file"
mkdir -p "$H/.config/omarchy/plugins/p"; qml > "$H/.config/omarchy/plugins/p/Bar.qml"
plant "$H/.config/omarchy/plugins/p/Bar.qml.omacvm-tmp" "$S/file"
chown -R "$LU:" "$H/.config/omarchy/plugins/p" "$H/.config/omacvm" "$H/.config/omacvm-bridge"
run_all
after "files linked to root's"

# 2. Folders in the home linked to root's folder.
fresh_home
for d in .config/hypr .local/state/omacvm .config/omarchy/plugins .config/omacvm-bridge .config/systemd/user .config/omacvm Mac; do
  plant "$H/$d" "$S/dir"
done
run_all
after "folders linked to root's"

# 3. ~/Mac linked to a folder something is mounted on: --stop leaves it mounted.
fresh_home; mkdir -p "$T/m"; mount -t tmpfs none "$T/m"; plant "$H/Mac" "$T/m"
OMACVM_MAC_FOLDER_USER=$LU bash "$G/app/guest/omacvm-mac-folder" --stop >/dev/null 2>&1
expect "~/Mac linked to a mounted folder: --stop unmounts nothing" yes "$(mountpoint -q "$T/m" && echo yes || echo no)"
umount "$T/m"

# 4. A plain home: everything still lands, as the user's.
fresh_home
printf -- '-- hyprland\n' > "$H/.config/hypr/hyprland.lua"; : > "$H/.config/hypr/bindings.lua"; : > "$H/.config/hypr/autostart.lua"
printf 'local omarchy_monitor_scale = 1.5\n' > "$H/.config/hypr/monitors.lua"
cp "$S/json" "$H/.config/omarchy/shell.json"; echo "--old" > "$H/.config/chromium-flags.conf"
echo "--disable-features=Foo" > "$H/.config/chrome-flags.conf"; : > "$H/.config/brave-flags.conf"
chown "$LU:" "$H/.config/chrome-flags.conf" "$H/.config/brave-flags.conf"
mkdir -p "$H/.config/omarchy/plugins/p"; qml > "$H/.config/omarchy/plugins/p/Bar.qml"
# Left by older versions as root's: a folder above the user's units, a marker.
mkdir -p "$H/.config/systemd/user"; chown root: "$H/.config/systemd" "$H/.config/systemd/user"
chown -R "$LU:" "$H/.config/hypr" "$H/.config/omarchy" "$H/.config/chromium-flags.conf" "$H/.local"
echo old > "$H/.local/state/omacvm/restart-shell"
( cd "$G/workspaces/guest" && bash ./install.sh "$LU" ) >/dev/null 2>&1
( cd "$G/keyboard/guest" && bash ./install.sh "$LU" us ) >/dev/null 2>&1
( cd "$G/display/guest" && bash ./install.sh "$LU" ) >/dev/null 2>&1
bash "$G/gestures/guest/glide.sh" "$LU" on >/dev/null 2>&1
bash "$G/clock/guest/clock.sh" "$LU" on "HH:mm" >/dev/null 2>&1
python3 "$G/guest/shell-colors.py" --user "$LU" --qmltypes "$T/qt.qmltypes" >/dev/null 2>&1
video_flags on
( U=$LU IP=x; gssh() { shift; /bin/bash -c "$1"; }; die() { exit 1; }
  eval "$(sed -n '/^vm_user_file() {/,/^}/p' "$SRC/cmd/apply.sh")"
  echo tok > "$T/tok"; vm_user_file token < "$T/tok" ) >/dev/null 2>&1
OMACVM_MAC_FOLDER_USER=$LU OMACVM_MAC_FOLDER_FS=tmpfs bash "$G/app/guest/omacvm-mac-folder" >/dev/null 2>&1
mounted=$(mountpoint -q "$H/Mac" && echo yes || echo no)
OMACVM_MAC_FOLDER_USER=$LU bash "$G/app/guest/omacvm-mac-folder" --stop >/dev/null 2>&1
owner() { stat -c '%U' "$1" 2>/dev/null; }
expect "plain home: per-display workspaces in bindings.lua" 1 "$(grep -c 'require("hypr.monitor_workspaces")' "$H/.config/hypr/bindings.lua")"
expect "... keyboard layout in input.lua, the user's file" "1 $LU" "$(grep -c 'kb_layout = "us"' "$H/.config/hypr/input.lua") $(owner "$H/.config/hypr/input.lua")"
expect "... monitors.lua keeps the scale, the user's, 644" "1 $LU 644" \
  "$(grep -c '^local omarchy_monitor_scale = 1.5$' "$H/.config/hypr/monitors.lua") $(owner "$H/.config/hypr/monitors.lua") $(stat -c %a "$H/.config/hypr/monitors.lua")"
expect "... Glide in hyprland.lua and the flags file" "1 1" \
  "$(grep -c 'require("hypr.omacvm_glide")' "$H/.config/hypr/hyprland.lua") $(grep -c -- '--disable-smooth-scrolling' "$H/.config/chromium-flags.conf")"
expect "... Chrome's video switches merged into its flags file (after Glide's line), the user's" \
  "--disable-features=Foo,AcceleratedVideoDecodeLinuxZeroCopyGL --disable-smooth-scrolling --enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder $LU" \
  "$(tr '\n' ' ' < "$H/.config/chrome-flags.conf")$(owner "$H/.config/chrome-flags.conf")"
expect "... Brave's (empty) flags file: both lines, still the user's" \
  "--disable-smooth-scrolling --enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder --disable-features=AcceleratedVideoDecodeLinuxZeroCopyGL $LU" \
  "$(tr '\n' ' ' < "$H/.config/brave-flags.conf")$(owner "$H/.config/brave-flags.conf")"
expect "... the clock moved in shell.json, the user's" "1 $LU" "$(jq '.bar.layout.right[-1].format == "HH:mm"' "$H/.config/omarchy/shell.json" | grep -c true) $(owner "$H/.config/omarchy/shell.json")"
expect "... the plugin clone pinned, still the user's" "1 $LU" "$(grep -c '^import QtQuick 6.11 ' "$H/.config/omarchy/plugins/p/Bar.qml") $(owner "$H/.config/omarchy/plugins/p/Bar.qml")"
expect "... the plugin's queue link, in a folder root had left" "yes $LU" \
  "$([[ -L $H/.config/systemd/user/graphical-session.target.wants/omacvm-plugins.service ]] && echo yes) $(owner "$H/.config/systemd/user")"
# A plugin from a folder only root can read (the app's display widget is built in a temp folder).
mkdir -m 700 "$T/rootonly"; cp -R "$G/workspaces/plugins/omacvm.workspaces" "$T/rootonly/p"
rm -rf "$H/.config/omarchy/plugins/omacvm.workspaces"
bash "$G/lib/install-plugin.sh" "$LU" "$T/rootonly/p" >/dev/null 2>&1
expect "... a plugin from a folder only root reads: the user's copy" "yes $LU" \
  "$([[ -f $H/.config/omarchy/plugins/omacvm.workspaces/manifest.json ]] && echo yes) $(owner "$H/.config/omarchy/plugins/omacvm.workspaces/manifest.json")"
( U=$LU; source "$G/guest/home-files.sh"; echo new | home_append "$H/.local/state/omacvm/restart-shell" ) >/dev/null 2>&1
expect "... a file root had left there: added to, now the user's" "old new $LU" \
  "$(tr '\n' ' ' < "$H/.local/state/omacvm/restart-shell")$(owner "$H/.local/state/omacvm/restart-shell")"
expect "... the bridge token: 600 in a 700 folder, the user's" "tok 600 700 $LU" \
  "$(cat "$H/.config/omacvm-bridge/token") $(stat -c %a "$H/.config/omacvm-bridge/token") $(stat -c %a "$H/.config/omacvm-bridge") $(owner "$H/.config/omacvm-bridge/token")"
expect "... the Mac folder mounted at ~/Mac, gone after --stop" "yes no $LU" \
  "$mounted $(mountpoint -q "$H/Mac" && echo yes || echo no) $(owner "$H/Mac")"
exit $fail
