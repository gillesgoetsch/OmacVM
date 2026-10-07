#!/bin/bash
# Keyboard, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <xkb-layout> [xkb-variant]
# (build.sh passes the layout read from the Mac by ../mac-layout.sh)
# Sets the layout in Hyprland and the console, makes Cmd+V paste everywhere,
# and the Mac's globe key (XF86Launch3 from OmacVM.app) open the emoji picker.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <layout> [variant]}; L=${2:?layout}; V=${3:-}
H=$(getent passwd "$U" | cut -d: -f6)

I=$H/.config/hypr/input.lua
# The two-line block, replaced where it is (else added at the end). Written
# next to the file and moved into place, and only when it changes, since
# Hyprland reloads on every write.
tmp=$(mktemp "$I.XXXXXX"); src=$I; [[ -f $I ]] || src=/dev/null
awk -v l="$L" -v v="$V" '
  function block() { print "-- OmacVM keyboard layout (from the Mac)"
                     printf "hl.config({ input = { kb_layout = \"%s\", kb_variant = \"%s\" } })\n", l, v; done = 1 }
  skip { skip = 0; if ($0 ~ /^hl[.]config[(][{] input = [{] kb_layout = /) next }
  $0 == "-- OmacVM keyboard layout (from the Mac)" { if (!done) block(); skip = 1; next }
  { print }
  END { if (!done) block() }' "$src" > "$tmp"
if cmp -s "$tmp" "$I"; then rm -f "$tmp"
else chmod 644 "$tmp"; chown "$U:$U" "$tmp"; mv -f "$tmp" "$I"; fi
localectl set-x11-keymap "$L" "" "$V" 2>/dev/null || true

B=$H/.config/hypr/bindings.lua
grep -q '"Universal paste"' "$B" 2>/dev/null || cat mac-paste.lua >> "$B"
grep -q '"Emojis (Mac globe key)"' "$B" 2>/dev/null || cat globe-key.lua >> "$B"
chown "$U:$U" "$B"
echo "keyboard: $L${V:+ ($V)}, Cmd+V paste, globe key: emoji picker"
