#!/bin/bash
# Install the guest side of Omanotch. Run inside the Omarchy VM as the
# desktop user (not root), from a checkout of this repository.
#
#   ./guest/install.sh
#
# What it does (all under your home directory, nothing in /usr):
#   1. builds notchcast and installs it to ~/.local/bin
#   2. clones Omarchy's bar into ~/.config/omarchy/plugins/$USER.bar (Omarchy's
#      supported way to customise the bar) and applies the notch patch to it
#   3. clones Omarchy's background into ~/.config/omarchy/plugins/$USER.background
#      and patches it so the wallpaper runs through the notch strip and the
#      built-in display as one image (seen when the bar is hidden)
#      Both copies follow Omarchy's updates and keep your own edits, as
#      Omarchy's plugins do (guest/copies.py, ~/.local/lib/omanotch, the user
#      service omanotch-copies.service)
#   4. clones Omarchy's display panel into ~/.config/omarchy/plugins/omanotch.monitor
#      with the hidden NOTCH output left out of its display list
#      (~/.local/bin/omanotch-display-panel builds it again after an Omarchy update)
#   5. installs ~/.config/hypr/notchbar.lua (hidden NOTCH output) and loads it
#      from ~/.config/hypr/hyprland.lua
#   6. installs and starts the systemd user service notchcast.service
# Undo with ./guest/uninstall.sh.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin=$HOME/.local/bin
plugins=$HOME/.config/omarchy/plugins
hypr=$HOME/.config/hypr
units=$HOME/.config/systemd/user
clone=$plugins/$USER.bar

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your desktop user, not root"
[[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || die "run inside the Hyprland session (HYPRLAND_INSTANCE_SIGNATURE is unset)"
for c in gcc wayland-scanner python3 git qs hyprctl omarchy-plugin-clone systemctl; do
  command -v "$c" >/dev/null || die "missing command: $c"
done
[[ -f /usr/include/lz4.h ]] || die "missing lz4 headers (pacman -S lz4)"
[[ -d /usr/share/wayland-protocols/staging/ext-image-copy-capture ]] || die "wayland-protocols too old (needs ext-image-copy-capture)"

say "building notchcast"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cp "$here/notchcast/notchcast.c" "$here/notchcast/notch-place.h" "$here/notchcast/notchrule.h" "$here/notchcast/build.sh" "$build/"
bash "$build/build.sh" "$build/out" >/dev/null
mkdir -p "$bin"
install -m 755 "$build/out/notchcast" "$bin/notchcast"

say "leaving NOTCH out of Omarchy's display panel"
install -m 755 "$here/monitor/display-panel.py" "$bin/omanotch-display-panel"
panel_result=$("$bin/omanotch-display-panel") || panel_result="failed (Omarchy's own display panel stays)"
echo "    $panel_result"

say "Omarchy's bar and background with the notch patch (they follow Omarchy's updates)"
lib=$HOME/.local/lib/omanotch
mkdir -p "$lib/bar" "$lib/background" "$units"
install -m 644 "$here/copies.py" "$lib/copies.py"
install -m 644 "$here/bar/apply-patch.py" "$lib/bar/apply-patch.py"
install -m 644 "$here/bar/workspaces-patch.py" "$lib/bar/workspaces-patch.py"
install -m 644 "$here/background/apply-patch.py" "$lib/background/apply-patch.py"
install -m 644 "$here/systemd/omanotch-copies.service" "$units/omanotch-copies.service"
systemctl --user daemon-reload
systemctl --user enable omanotch-copies.service >/dev/null 2>&1
# Makes a missing copy, patches it, and brings a copy up to Omarchy's plugin
# and this patch, keeping your edits; restarts the shell when it changed one.
copies_rc=0
copies_out=$(python3 "$lib/copies.py" --install) || copies_rc=$?
sed 's/^/    /' <<<"$copies_out"
[[ -f $clone/Bar.qml ]] || die "bar clone not found at $clone"
grep -q omarchy-notch-bar "$clone/Bar.qml" || die "the notch patch is not in $clone/Bar.qml (see above)"
if command -v omarchy-bar-use >/dev/null; then
  omarchy-bar-use "$USER.bar" >/dev/null 2>&1 || true
fi
# A locked session: the service does it right after the unlock.
if (( copies_rc == 3 )); then systemctl --user start --no-block omanotch-copies.service 2>/dev/null || true; fi

# The shell caches plugin code: a changed panel only takes effect after a restart.
if [[ $panel_result == patched && $copies_out != *"the shell restarted"* ]]; then
  omarchy-restart-shell >/dev/null 2>&1 || true
fi

# Heartbeat and bar state files (see guest/bar/apply-patch.py).
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/omanotch"

# A development build cloned Omarchy's notification service. Omarchy runs
# cloned services sandboxed, which keeps their popups from showing: undo it.
if [[ -d $plugins/$USER.notifications ]]; then
  omarchy-plugin-enable omarchy.notifications >/dev/null 2>&1 || true
  rm -rf "$plugins/$USER.notifications"
fi

say "installing Hyprland config"
mkdir -p "$hypr"
sed -e "s|^local NOTCH_OUTPUT = .*|local NOTCH_OUTPUT = \"${NOTCHBAR_OUTPUT:-NOTCH}\"|" \
    -e "s|^local BUILTIN_OUTPUT = .*|local BUILTIN_OUTPUT = \"${NOTCHBAR_SCREEN:-Virtual-1}\"|" \
    "$here/hypr/notchbar.lua" > "$hypr/notchbar.lua"
if ! grep -q 'require("hypr.notchbar")' "$hypr/hyprland.lua"; then
  cp -p "$hypr/hyprland.lua" "$hypr/hyprland.lua.before-notchbar"
  printf '\n-- omarchy-notch-bar: hidden output for the macOS notch helper.\nrequire("hypr.notchbar")\n' >> "$hypr/hyprland.lua"
fi
hyprctl reload >/dev/null

say "installing the notchcast service"
mkdir -p "$units"
install -m 644 "$here/systemd/notchcast.service" "$units/notchcast.service"
systemctl --user daemon-reload
systemctl --user enable notchcast.service >/dev/null 2>&1
# One start, with the start limit cleared: an older unit may have hit it
# while notchcast was being built again.
systemctl --user reset-failed notchcast.service 2>/dev/null || true
# OmacVM.app's FullPanel start: the bar sits in the strip itself and
# notchcast stays off for this boot (the unit's ExecCondition).
if grep -qs '^OMACVM_FULLPANEL=' /run/omacvm/host.env; then
  say "done: FullPanel start, notchcast stays off until the next native start"
  exit 0
fi
systemctl --user restart notchcast.service

sleep 2
if systemctl --user is-active --quiet notchcast.service; then
  say "done: notchcast is running (journalctl --user -u notchcast -f)"
else
  die "notchcast.service did not start; see journalctl --user -u notchcast"
fi
