#!/bin/bash
# omacvm-gestures, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Idempotent. Installs the daemon (virtual Apple touchpad fed by the Mac helper)
# and Hyprland's 3/4-finger workspace swipes, with the workspaces sliding.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)

../../guest/pkg-add python-evdev
install -m755 omacvm-gestures /usr/local/bin/omacvm-gestures
install -m644 omacvm-gestures.service /etc/systemd/system/omacvm-gestures.service
systemctl daemon-reload
systemctl enable omacvm-gestures >/dev/null 2>&1
systemctl restart omacvm-gestures

I=$H/.config/hypr/input.lua
# Each swipe only when no active horizontal gesture with that many fingers is
# there yet (Hyprland rejects a second one; Omarchy ships the 3-finger line
# commented out as an example, and a hand-made one counts too).
missing=()
for n in 3 4; do
  grep -Eq "^[[:space:]]*hl\.gesture\(\{ *fingers *= *$n *, *direction *= *\"horizontal\"" "$I" 2>/dev/null || missing+=("$n")
done
if (( ${#missing[@]} )); then
  {
    grep -q '^-- OmacVM trackpad:' "$I" 2>/dev/null || printf '\n%s\n%s\n' \
      "-- OmacVM trackpad: the Mac's multi-finger gestures arrive on a virtual" \
      "-- touchpad while the VM is full screen. Swipe between workspaces like Spaces."
    for n in "${missing[@]}"; do
      echo "hl.gesture({ fingers = $n, direction = \"horizontal\", action = \"workspace\" })"
    done
  } >> "$I"
  chown "$U:$U" "$I"
fi
# Omarchy turns the workspace animation off, so a swipe jumped to the next
# workspace when the fingers lifted. Slide like Spaces, unless you set your own.
if ! grep -q 'leaf *= *"workspaces"' "$H"/.config/hypr/*.lua 2>/dev/null; then
  printf '%s\n' '-- OmacVM trackpad: workspaces slide into place after a swipe, like Spaces.' \
    'hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default", style = "slide" })' >> "$I"
  chown "$U:$U" "$I"
fi
echo "omacvm-gestures guest side installed"
