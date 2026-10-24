#!/bin/bash
# Per-display workspaces, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Every display gets its own workspaces 1..0 (keys and bar), like Spaces on the
# Mac. Unplugging a display parks its workspaces on the main one and replugging
# puts them back (monitor_workspaces.lua).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
B=$H/.config/hypr/bindings.lua
BEGIN='-- >>> OmacVM per-display workspaces' END='-- <<< OmacVM per-display workspaces'

# Omarchy 4.5 gives every monitor its own workspaces 1..10 itself
# (default/hypr/monitor-workspaces.lua: blocks of ten as here, kept per
# monitor, and its own bar widget shows each monitor's). OmacVM's would fight
# it over the same keys and moves: there ours goes, with its bindings block
# and bar widget, and Omarchy's widget comes back. (Omarchy 4.5 is test only:
# branch omarchy-45.)
if [[ -f ${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr/monitor-workspaces.lua ]]; then
  # The block first: bindings.lua requires the file.
  if home_grep "$B" -qxF -e "$BEGIN"; then
    home_cat "$B" | awk -v b="$BEGIN" -v e="$END" '$0 == b { s = 1 } !s { print } s && $0 == e { s = 0 }' | home_write "$B"
  fi
  # Still required (a block changed by hand): the file stays.
  home_grep "$B" -q 'require("hypr.monitor_workspaces")' ||
    home_run rm -f "$H/.config/hypr/monitor_workspaces.lua" < /dev/null
  if [[ -d $H/.config/omarchy/plugins/omacvm.workspaces ]]; then
    R=$(cd ../.. && pwd) ROOT=""; source ../../guest/off.sh
    if sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" bash -c \
        'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; omarchy-shell shell ping && omarchy plugin disable omacvm.workspaces' \
        >/dev/null 2>&1; then
      home_run rm -rf "$H/.config/omarchy/plugins/omacvm.workspaces" < /dev/null
    else
      plugins_off_at_login omacvm.workspaces   # nobody logged in: at the next login
    fi
  fi
  echo "per-display workspaces: Omarchy's own"
  exit 0
fi

# Replaced in one step: Omarchy reloads its config on every change, and
# bindings.lua requires this file (a reload in between showed "module not found").
# Only when it changed: a reload moves the displays (a flicker on each apply).
home_same "$H/.config/hypr/monitor_workspaces.lua" monitor_workspaces.lua ||
  home_put "$H/.config/hypr/monitor_workspaces.lua" < monitor_workspaces.lua
home_grep "$B" -q 'require("hypr.monitor_workspaces")' || home_append "$B" < workspace-bindings.lua
../../lib/install-plugin.sh "$U" ../plugins/omacvm.workspaces
echo "per-display workspaces installed"
