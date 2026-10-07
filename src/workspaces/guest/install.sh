#!/bin/bash
# Per-display workspaces, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Every display gets its own workspaces 1..0 (keys and bar), like Spaces on the
# Mac. Unplugging a display parks its workspaces on the main one and replugging
# puts them back (monitor_workspaces.lua).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
# Replaced in one step: Omarchy reloads its config on every change, and
# bindings.lua requires this file (a reload in between showed "module not found").
# Only when it changed: a reload moves the displays (a flicker on each apply).
if ! cmp -s monitor_workspaces.lua "$H/.config/hypr/monitor_workspaces.lua"; then
  install -o "$U" -g "$U" -m644 monitor_workspaces.lua "$H/.config/hypr/.monitor_workspaces.lua.new"
  mv -f "$H/.config/hypr/.monitor_workspaces.lua.new" "$H/.config/hypr/monitor_workspaces.lua"
fi
B=$H/.config/hypr/bindings.lua
grep -q 'require("hypr.monitor_workspaces")' "$B" 2>/dev/null || { cat workspace-bindings.lua >> "$B"; chown "$U:$U" "$B"; }
../../lib/install-plugin.sh "$U" ../plugins/omacvm.workspaces
echo "per-display workspaces installed"
