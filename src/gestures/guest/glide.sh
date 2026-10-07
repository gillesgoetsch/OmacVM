#!/bin/bash
# Glide (experimental), guest side: ./glide.sh <desktop-user> on|off (root).
# The daemon reads the choice from /etc/omacvm/env (guest/install.sh writes it
# and restarts the daemon); this sets up the rest:
#  * ~/.config/hypr/omacvm_glide.lua (scroll factor for the virtual trackpad,
#    Chromium-based apps), loaded from hyprland.lua;
#  * --disable-smooth-scrolling in Chromium's and Chrome's flags files, so
#    Chromium does not animate on top of macOS's momentum (tested with it).
#    Only files that exist; a marker remembers which ones OmacVM changed, so
#    turning Glide off never removes a flag the user set.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: glide.sh <desktop-user> on|off}; ON=${2:?on|off}
H=$(getent passwd "$U" | cut -d: -f6)
HY=$H/.config/hypr
LINE='require("hypr.omacvm_glide")'
MARK=$H/.local/state/omacvm/glide-flags
FLAG=--disable-smooth-scrolling
# Hyprland's config is touched (and reloaded below) only when it changes: a
# reload moves the displays, a flicker on every apply.
changed=0
if [[ $ON == on ]]; then
  # In one step: hyprland.lua requires it and Omarchy reloads on every change.
  if ! cmp -s omacvm_glide.lua "$HY/omacvm_glide.lua"; then
    install -o "$U" -g "$U" -m644 omacvm_glide.lua "$HY/.omacvm_glide.lua.new"
    mv -f "$HY/.omacvm_glide.lua.new" "$HY/omacvm_glide.lua"
    changed=1
  fi
  if ! grep -qxF "$LINE" "$HY/hyprland.lua"; then
    printf -- '-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.\n%s\n' "$LINE" >> "$HY/hyprland.lua"
    chown "$U:$U" "$HY/hyprland.lua"
    changed=1
  fi
  install -d -o "$U" -g "$U" "$(dirname "$MARK")"
  for f in "$H/.config/chromium-flags.conf" "$H/.config/chrome-flags.conf" "$H/.config/brave-flags.conf"; do
    [[ -f $f ]] || continue
    grep -qxF -- "$FLAG" "$f" && continue
    printf '%s\n' "$FLAG" >> "$f"
    grep -qxF "$f" "$MARK" 2>/dev/null || echo "$f" >> "$MARK"
  done
  [[ -f $MARK ]] && chown "$U:$U" "$MARK"
  echo "scroll momentum: on (restart Chromium-based apps once)"
else
  if grep -qxF "$LINE" "$HY/hyprland.lua" 2>/dev/null || [[ -e $HY/omacvm_glide.lua ]]; then
    sed -i '/^-- OmacVM Glide (experimental): scrolling settings for the virtual trackpad.$/d' "$HY/hyprland.lua" 2>/dev/null || true
    sed -i "/^require(\"hypr.omacvm_glide\")$/d" "$HY/hyprland.lua" 2>/dev/null || true
    rm -f "$HY/omacvm_glide.lua"
    changed=1
  fi
  if [[ -f $MARK ]]; then
    while IFS= read -r f; do
      [[ -f $f ]] && sed -i "/^$FLAG\$/d" "$f"
    done < "$MARK"
    rm -f "$MARK"
  fi
  echo "scroll momentum: off"
fi
# A running Hyprland picks the change up now.
(( changed )) || exit 0
RUN=/run/user/$(id -u "$U")
# (No session yet, e.g. during a build: no hypr folder, nothing to reload.)
sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -1 || true)
[[ -n $sig ]] && sudo -u "$U" env XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload >/dev/null 2>&1 || true
