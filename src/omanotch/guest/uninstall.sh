#!/bin/bash
# Remove the guest side of Omanotch. Run inside the Omarchy VM as the
# desktop user. Omarchy's own background, display and notification plugins are switched
# back on and the patched clones removed. The bar clone in ~/.config/omarchy/plugins/$USER.bar
# is kept (switch back with `omarchy bar use omarchy.bar`, then delete it if
# you like), unless you pass --remove-bar-clone.
set -euo pipefail

hypr=$HOME/.config/hypr
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

say "stopping notchcast"
systemctl --user disable --now notchcast.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/notchcast.service" "$HOME/.local/bin/notchcast"
# The bar clone stays patched: it must not start parked at the next login.
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/omanotch/expect"
systemctl --user daemon-reload

say "removing Hyprland config"
if [[ -f $hypr/hyprland.lua ]]; then
  sed -i '/-- omarchy-notch-bar: hidden output for the macOS notch helper./d; /require("hypr.notchbar")/d' "$hypr/hyprland.lua"
fi
rm -f "$hypr/notchbar.lua"
hyprctl output remove NOTCH >/dev/null 2>&1 || true
hyprctl eval 'hl.config({ cursor = { invisible = false } })' >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true

say "restoring Omarchy's background"
if [[ -d $HOME/.config/omarchy/plugins/$USER.background ]]; then
  omarchy-plugin-enable omarchy.background >/dev/null 2>&1 || true
  rm -rf "$HOME/.config/omarchy/plugins/$USER.background"
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
fi

say "restoring Omarchy's display panel"
if [[ -x $HOME/.local/bin/omanotch-display-panel ]]; then
  "$HOME/.local/bin/omanotch-display-panel" --remove || true
fi
rm -f "$HOME/.local/bin/omanotch-display-panel"

say "restoring Omarchy's notifications"
if [[ -d $HOME/.config/omarchy/plugins/$USER.notifications ]]; then
  omarchy-plugin-enable omarchy.notifications >/dev/null 2>&1 || true
  rm -rf "$HOME/.config/omarchy/plugins/$USER.notifications"
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
fi

say "restoring Omarchy's bar"
omarchy-shell -q notchbar setParked false || true
if [[ ${1:-} == --remove-bar-clone ]]; then
  if command -v omarchy-bar-use >/dev/null; then omarchy-bar-use omarchy.bar >/dev/null 2>&1 || true; fi
  rm -rf "$HOME/.config/omarchy/plugins/$USER.bar"
fi
say "done"
