#!/bin/bash
# Glide (experimental), guest side: ./glide.sh <desktop-user> on|off (root).
# The daemon reads the choice from /etc/omacvm/env (guest/install.sh writes it
# and restarts the daemon); this sets up the rest:
#  * ~/.config/hypr/omacvm_glide.lua (scroll factor for the virtual trackpad,
#    Chromium-based apps), loaded from hyprland.lua;
#  * --disable-smooth-scrolling in Chromium's and Chrome's flags files, so
#    Chromium does not animate on top of macOS's momentum (tested with it);
#  * WaylandUnscaledTouchpadScrolling in their last --disable-features, so
#    Chromium scrolls a touchpad at the scale its factor is tuned for
#    (glide-flags.py).
#    Only files that exist; markers remember which ones OmacVM changed, so
#    turning Glide off never removes a flag the user set.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: glide.sh <desktop-user> on|off}; ON=${2:?on|off}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
HY=$H/.config/hypr
LINE='require("hypr.omacvm_glide")'
MARK=$H/.local/state/omacvm/glide-flags
FLAG=--disable-smooth-scrolling
# Hyprland's config is touched (and reloaded below) only when it changes: a
# reload moves the displays, a flicker on every apply.
changed=0
if [[ $ON == on ]]; then
  # In one step: hyprland.lua requires it and Omarchy reloads on every change.
  if ! home_same "$HY/omacvm_glide.lua" omacvm_glide.lua; then
    home_put "$HY/omacvm_glide.lua" < omacvm_glide.lua
    changed=1
  fi
  if ! home_grep "$HY/hyprland.lua" -qxF "$LINE"; then
    printf -- '-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.\n%s\n' "$LINE" | home_append "$HY/hyprland.lua"
    changed=1
  fi
  home_mkdir "$(dirname "$MARK")"
  for f in "$H/.config/chromium-flags.conf" "$H/.config/chrome-flags.conf" "$H/.config/brave-flags.conf"; do
    [[ -f $f ]] || continue
    home_grep "$f" -qxF -- "$FLAG" && continue
    printf '%s\n' "$FLAG" | home_append "$f"
    home_grep "$MARK" -qxF "$f" || echo "$f" | home_append "$MARK"
  done
  home_run python3 -I - on "$H" < glide-flags.py
  echo "scroll momentum: on (restart Chromium-based apps once)"
else
  if home_grep "$HY/hyprland.lua" -qxF "$LINE" || [[ -e $HY/omacvm_glide.lua ]]; then
    home_run sed -i -e '/^-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.$/d' \
      -e "/^require(\"hypr.omacvm_glide\")$/d" "$HY/hyprland.lua" 2>/dev/null || true
    home_run rm -f "$HY/omacvm_glide.lua"
    changed=1
  fi
  if [[ -f $MARK ]]; then
    while IFS= read -r f; do
      # Only the flags files this script names (the marker is the user's file).
      case $f in "$H/.config/chromium-flags.conf"|"$H/.config/chrome-flags.conf"|"$H/.config/brave-flags.conf") ;; *) continue ;; esac
      [[ -f $f ]] && home_run sed -i "/^$FLAG\$/d" "$f"
    done < <(home_cat "$MARK")
    home_run rm -f "$MARK"
  fi
  home_run python3 -I - off "$H" < glide-flags.py
  echo "scroll momentum: off"
fi
# A running Hyprland picks the change up now.
(( changed )) || exit 0
RUN=/run/user/$(id -u "$U")
# (No session yet, e.g. during a build: no hypr folder, nothing to reload.)
sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -1 || true)
[[ -n $sig ]] && sudo -u "$U" env XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload >/dev/null 2>&1 || true
