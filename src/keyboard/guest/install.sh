#!/bin/bash
# Keyboard, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <xkb-layout> [xkb-variant]
# (build.sh passes the layout read from the Mac by ../mac-layout.sh)
# Sets the layout in Hyprland and the console, makes Cmd+V paste everywhere,
# and the Mac's globe key (XF86Launch3 from OmacVM.app) open the emoji picker.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <layout> [variant]}; L=${2:?layout}; V=${3:-}
# They go into Hyprland's config: XKB names only.
[[ $L =~ ^[a-z]{2,8}$ && $V =~ ^[A-Za-z0-9_-]{0,32}$ ]] || { echo "keyboard: not an XKB layout: '$L' '$V'" >&2; exit 2; }
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user

I=$H/.config/hypr/input.lua
# The two-line block, replaced where it is (else added at the end). Written
# next to the file and moved into place, and only when it changes, since
# Hyprland reloads on every write.
src=$(mktemp); tmp=$(mktemp); trap 'rm -f "$src" "$tmp"' EXIT
home_cat "$I" > "$src" || true
awk -v l="$L" -v v="$V" '
  function block() { print "-- OmacVM keyboard layout (from the Mac)"
                     printf "hl.config({ input = { kb_layout = \"%s\", kb_variant = \"%s\" } })\n", l, v; done = 1 }
  skip { skip = 0; if ($0 ~ /^hl[.]config[(][{] input = [{] kb_layout = /) next }
  $0 == "-- OmacVM keyboard layout (from the Mac)" { if (!done) block(); skip = 1; next }
  { print }
  END { if (!done) block() }' "$src" > "$tmp"
home_same "$I" "$tmp" || home_put "$I" < "$tmp"
localectl set-x11-keymap "$L" "" "$V" 2>/dev/null || true

B=$H/.config/hypr/bindings.lua
home_grep "$B" -q '"Universal paste"' || home_append "$B" < mac-paste.lua
home_grep "$B" -q '"Emojis (Mac globe key)"' || home_append "$B" < globe-key.lua
echo "keyboard: $L${V:+ ($V)}, Cmd+V paste, globe key: emoji picker"
