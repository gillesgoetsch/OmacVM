#!/bin/bash
# Fewer animations (feature fewer-animations: experimental, off by default,
# Omarchy 4.5; docs/features.md): Omarchy's own no-animations toggle, the one
# behind `omarchy toggle animations` and its menu. Hyprland then draws no
# animations, blur or shadows; window opacity stays as it is. The feature is
# that toggle and nothing else: on puts Omarchy's file in the user's toggles,
# off takes it away, as omarchy-hyprland-toggle does, and a running Hyprland
# reads its config again. Switched in Omarchy's menu, it is the same switch
# (the Mac's probe reads it: OMACVM_REAL_fewer_animations). Why: Hyprland
# redraws the whole of both windows while their border colours fade after a
# focus change, so moving the pointer across windows makes whole-screen frames
# (about 0.46 W on a MacBook Air M2). As root in the VM:
#   install.sh USER on|off
#   install.sh USER --status     on, off, or none (no such toggle in this
#                                Omarchy: below 4.5)
# Exit 3: this Omarchy has no such toggle (nothing done). Tests:
# src/tests/fewer-animations.sh (OMACVM_ANIM_OMARCHY, OMACVM_ANIM_HOME,
# OMACVM_ANIM_RUN and a stand-in hyprctl on PATH).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$here/../.." && pwd)   # this copy of src/
U=${1:?usage: install.sh USER on|off|--status}
ACTION=${2:?usage: install.sh USER on|off|--status}
H=${OMACVM_ANIM_HOME:-$(getent passwd "$U" | cut -d: -f6)}
RUN=${OMACVM_ANIM_RUN:-/run/user/$(id -u "$U" 2>/dev/null)}
# shellcheck source=../../guest/home-files.sh
source "$R/guest/home-files.sh"   # the home is written as the user
SRC=${OMACVM_ANIM_OMARCHY:-/usr/share/omarchy}/default/hypr/toggles/no-animations.lua
FLAG=$H/.local/state/omarchy/toggles/hypr/no-animations.lua

# A running Hyprland reads its config again (omarchy-restart-hyprctl's step;
# no session, e.g. during a build: it reads the file when it starts).
reload() {
  local sig
  sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -n 1 || true)
  [[ -n $sig ]] || return 0
  home_run env XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" timeout 10 hyprctl reload >/dev/null 2>&1 < /dev/null || true
}

case $ACTION in
  on)
    if [[ ! -f $SRC ]]; then
      echo "OmacVM: it needs Omarchy 4.5 (this Omarchy has no animations toggle): Move to Omarchy 4.5 in OmacVM.app"
      exit 3
    fi
    # Already there (also when switched in Omarchy's menu): nothing to do.
    [[ -f $FLAG ]] && { echo "fewer animations: on"; exit 0; }
    home_mkdir "${FLAG%/*}" || { echo "OmacVM: could not make ${FLAG%/*}"; exit 1; }
    home_put "$FLAG" < "$SRC" || { echo "OmacVM: could not write $FLAG"; exit 1; }
    reload
    echo "fewer animations: on (Omarchy's animations, blur and shadows off)" ;;
  off)
    [[ -e $FLAG || -L $FLAG ]] || exit 0
    home_run rm -f -- "$FLAG" < /dev/null || { echo "OmacVM: could not remove $FLAG"; exit 1; }
    reload
    echo "fewer animations: off (Omarchy's animations back)" ;;
  --status)
    if [[ ! -f $SRC ]]; then echo none
    elif [[ -f $FLAG ]]; then echo on
    else echo off; fi ;;
  *) echo "usage: install.sh USER on|off|--status" >&2; exit 2 ;;
esac
