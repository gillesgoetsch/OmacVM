#!/bin/bash
# Fewer animations (feature fewer-animations: experimental, off by default;
# docs/features.md): a window's border takes its new colour at once on a
# focus change instead of fading. OmacVM's own small Hyprland file,
# omacvm_animations.lua (Hyprland's border and borderangle animations off),
# required from the user's hyprland.lua; every other animation, blur and
# shadows stay as Omarchy has them, and Omarchy's own "no animations" toggle
# stays Omarchy's. Omarchy 4.0 and 4.5 alike (both have the Lua config).
# Why: Hyprland redraws the whole of both windows while their border colours
# fade, so moving the pointer across windows makes whole-screen frames (about
# 0.43 W on a MacBook Air M2). As root in the VM:
#   install.sh USER on|off
#   install.sh USER --status     on, off, partial (one of the two parts
#                                missing or changed) or none (no Lua config)
# Hyprland reads the change on its own (it reloads when a file it loaded is
# written); a reload is asked for only when no such file changed. Exit 3: no
# hyprland.lua (not Omarchy 4's Lua config; nothing done). Tests:
# src/tests/fewer-animations.sh (OMACVM_ANIM_HOME, OMACVM_ANIM_RUN and a
# stand-in hyprctl on PATH).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$here/../.." && pwd)   # this copy of src/
U=${1:?usage: install.sh USER on|off|--status}
ACTION=${2:?usage: install.sh USER on|off|--status}
H=${OMACVM_ANIM_HOME:-$(getent passwd "$U" | cut -d: -f6)}
RUN=${OMACVM_ANIM_RUN:-/run/user/$(id -u "$U" 2>/dev/null)}
# shellcheck source=../../guest/home-files.sh
source "$R/guest/home-files.sh"   # the home is written as the user
HY=$H/.config/hypr
B=$HY/hyprland.lua
FILE=$HY/omacvm_animations.lua
LINE='require("hypr.omacvm_animations")'
MARK='-- OmacVM: Fewer animations (omacvm_animations.lua says what it does).'

# A running Hyprland reads its config again (only when no file it loaded
# changed; no session, e.g. during a build: it reads the files when it starts).
reload() {
  local sig
  sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -n 1 || true)
  [[ -n $sig ]] || return 0
  home_run env XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" timeout 10 hyprctl reload >/dev/null 2>&1 < /dev/null || true
}

status() {
  [[ -f $B ]] || { echo none; return; }
  local f=0 l=0
  home_same "$FILE" "$here/omacvm_animations.lua" && f=1
  home_grep "$B" -qxF "$LINE" && l=1
  case $f$l in 11) echo on ;; 00) [[ -e $FILE || -L $FILE ]] && echo partial || echo off ;; *) echo partial ;; esac
}

case $ACTION in
  on)
    if [[ ! -f $B ]]; then
      echo "OmacVM: it needs Omarchy's Lua config (~/.config/hypr/hyprland.lua, Omarchy 4): nothing done"
      exit 3
    fi
    wrote=none
    # The file first, then the line that requires it: the line never points at a missing file.
    if ! home_same "$FILE" "$here/omacvm_animations.lua"; then
      [[ -e $FILE ]] && wrote=changed || wrote=new
      home_put "$FILE" < "$here/omacvm_animations.lua" || { echo "OmacVM: could not write $FILE"; exit 1; }
    fi
    if home_grep "$B" -qxF "$LINE"; then
      # Already required: Hyprland reloads by itself on a write to a file it
      # loaded; one it could not load (it was missing) needs the reload.
      [[ $wrote == new ]] && reload
      if [[ $wrote == none ]]; then echo "fewer animations: on"
      else echo "fewer animations: on (borders change colour at once)"; fi
    else
      printf -- '%s\n%s\n' "$MARK" "$LINE" | home_append "$B" || { echo "OmacVM: could not write $B"; exit 1; }
      echo "fewer animations: on (borders change colour at once)"
    fi ;;
  off)
    said=0
    # The line first (Hyprland reloads on that write), then the file.
    if [[ -f $B ]] && home_grep "$B" -qxF "$LINE"; then
      t=$(mktemp) || exit 1
      { home_cat "$B" | grep -vxF -e "$LINE" -e "$MARK"; } > "$t" || true
      home_write "$B" < "$t" || { rm -f "$t"; echo "OmacVM: could not write $B"; exit 1; }
      rm -f "$t"
      said=1
    fi
    if [[ -e $FILE || -L $FILE ]]; then
      home_run rm -f -- "$FILE" < /dev/null || { echo "OmacVM: could not remove $FILE"; exit 1; }
      said=1
    fi
    (( said )) && echo "fewer animations: off (Omarchy's border animation back)"
    exit 0 ;;
  --status) status ;;
  *) echo "usage: install.sh USER on|off|--status" >&2; exit 2 ;;
esac
