#!/bin/bash
# Hyprland settings every OmacVM VM needs, on every route: omacvm_vm.lua,
# required from the user's hyprland.lua. Run as root by guest/install.sh at
# every apply:
#   guest/hypr-vm.sh <desktop-user>
# Prints "added" or "updated" when it wrote something, nothing when all was in
# place. Idempotent. No guest-side uninstall, as for omacvm_app.lua.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: hypr-vm.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ./home-files.sh   # the home is written as the user
HY=$H/.config/hypr
LINE='require("hypr.omacvm_vm")'
MARK='-- OmacVM: Hyprland settings every VM needs (omacvm_vm.lua says why).'
[[ -f $HY/hyprland.lua ]] || exit 0   # not Omarchy 4's Lua config: nothing to add to
# Hyprland reloads on every write to a file it loaded: only what changed, the
# file before the line that requires it (one reload, and the line never
# points at a missing file).
if home_grep "$HY/hyprland.lua" -qxF "$LINE"; then
  home_same "$HY/omacvm_vm.lua" omacvm_vm.lua && exit 0
  home_put "$HY/omacvm_vm.lua" < omacvm_vm.lua
  echo updated
else
  home_put "$HY/omacvm_vm.lua" < omacvm_vm.lua
  printf -- '%s\n%s\n' "$MARK" "$LINE" | home_append "$HY/hyprland.lua"
  echo added
fi
