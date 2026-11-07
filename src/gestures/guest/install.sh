#!/bin/bash
# omacvm-gestures, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Idempotent. Installs the daemon (virtual Apple touchpad fed by the Mac helper)
# and Hyprland's 3/4-finger workspace swipes, with the workspaces sliding.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user

../../guest/pkg-add python-evdev
install -m755 omacvm-gestures /usr/local/bin/omacvm-gestures
install -m644 omacvm-gestures.service /etc/systemd/system/omacvm-gestures.service
systemctl daemon-reload
systemctl enable omacvm-gestures >/dev/null 2>&1
systemctl restart omacvm-gestures

I=$H/.config/hypr/input.lua
# Each swipe only when no active sideways gesture with that many fingers is
# there yet: Hyprland refuses a second one (a config error on screen), and a
# count given to something else stays so (Omarchy's example moves focus with
# 3 fingers left and right; the swipe out follows what is set, #342).
# Omarchy ships the 3-finger workspace line commented out as an example.
# The daemon reads the gestures as the swipe out does (tables over several
# lines too); "?" (a count it cannot tell): nothing added; without it, a
# one-line check.
missing=()
if taken=$(home_run python3 "$PWD/omacvm-gestures" --sideways "$H" 2>/dev/null); then
  [[ $taken == *"?"* ]] || for n in 3 4; do [[ " $taken " == *" $n "* ]] || missing+=("$n"); done
else
  for n in 3 4; do
    grep -Eq "^[[:space:]]*hl\.gesture\(\{ *fingers *= *$n *, *direction *= *\"(horizontal|horiz|left|l|right|r|swipe)\"" \
      < <(home_run cat -- "$H"/.config/hypr/*.lua 2>/dev/null) || missing+=("$n")
  done
fi
if (( ${#missing[@]} )); then
  {
    home_grep "$I" -q "^-- OmacVM trackpad: the Mac's multi-finger" || printf '\n%s\n%s\n' \
      "-- OmacVM trackpad: the Mac's multi-finger gestures arrive on a virtual" \
      "-- touchpad while the VM is full screen. Swipe between workspaces like Spaces."
    for n in "${missing[@]}"; do
      echo "hl.gesture({ fingers = $n, direction = \"horizontal\", action = \"workspace\" })"
    done
  } | home_append "$I"
fi
# The virtual trackpad never taps: a tap or click on the Mac's trackpad comes
# through the VM app's pointer, as macOS's own settings make it. Omarchy 4.5
# leaves tap-to-click at Hyprland's default (on; omarchy-mac's 4.0 had it off),
# so the two still fingers at the start of a pinch, lifted when macOS calls it a
# pinch, were a two-finger tap there: a right click. Unless you set it yourself
# (a line that is not a comment; an hl.device table for it over several lines is
# not seen: OmacVM's line is added too, and the one that loads later wins).
if ! grep -Eq '^[[:space:]]*hl\.device\(.*magic-trackpad-\(omacvm\).*tap_to_click' \
    < <(home_run cat -- "$H"/.config/hypr/*.lua 2>/dev/null); then
  printf '%s\n' '-- OmacVM taps: no tap-to-click on the virtual trackpad (the Mac'"'"'s taps and clicks still count).' \
    'hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = false })' | home_append "$I"
fi
# Omarchy turns the workspace animation off, so a swipe jumped to the next
# workspace when the fingers lifted. Slide like Spaces, unless you set your own.
if ! grep -q 'leaf *= *"workspaces"' < <(home_run cat -- "$H"/.config/hypr/*.lua 2>/dev/null); then
  printf '%s\n' '-- OmacVM trackpad: workspaces slide into place after a swipe, like Spaces.' \
    'hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "default", style = "slide" })' | home_append "$I"
fi
echo "omacvm-gestures guest side installed"
