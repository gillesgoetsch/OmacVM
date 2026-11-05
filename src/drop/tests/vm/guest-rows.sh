#!/bin/bash
# guest-rows.sh STEP (in the test VM as the desktop user): the helpers src/tests/e2e/drag-drop.sh calls
# between its drops, from /tmp/dnd (its guest.tar). Out: one line per call on stdout.
#   window            start the spike's test window (dnd-dst) and print its centre "X Y" (logical px)
#   window-drops      the test window's drops so far, and the last dropped text
#   nautilus DIR      open Nautilus on DIR and print its centre "X Y"
#   desktop           no window left open: print the output's centre "X Y"
#   ls DIR            names and sha256 of the files in DIR
#   status            omacvm-drop status (JSON)
D=/tmp/dnd; cd "$D" || exit 1
case $1 in
  window)
    if [[ ! -x dnd-dst ]]; then
      wayland-scanner client-header xdg-shell.xml xdg-shell-client-protocol.h
      wayland-scanner private-code xdg-shell.xml xdg-shell.c
      gcc -O1 -Wall -o dnd-dst dnd-dst.c xdg-shell.c -lwayland-client || { echo "build failed"; exit 1; }
    fi
    : > "$D/dst.txt"
    setsid ./dnd-dst "$D/dst.txt" >/dev/null 2>&1 < /dev/null &
    for _ in $(seq 50); do grep -q READY "$D/dst.txt" && break; sleep 0.1; done
    sleep 1
    C=$(hyprctl clients -j | jq -c '.[] | select(.class=="dnd-dst") | {at,size}' | head -1)
    echo "$(( $(jq '.at[0]' <<<"$C") + $(jq '.size[0]' <<<"$C") / 2 )) $(( $(jq '.at[1]' <<<"$C") + $(jq '.size[1]' <<<"$C") / 2 ))" ;;
  window-drops)
    echo "drops=$(grep -c '^DROP' "$D/dst.txt") last=$(awk '/^DROP/{getline; l=$0} END{print l}' "$D/dst.txt")" ;;
  window-close)
    pkill -x dnd-dst; echo closed ;;
  nautilus)
    rm -rf "$2"; mkdir -p "$2"
    setsid nautilus --new-window "$2" >/dev/null 2>&1 < /dev/null &
    for _ in $(seq 60); do C=$(hyprctl clients -j | jq -c '.[] | select(.class=="org.gnome.Nautilus") | {at,size}' | head -1); [[ -n $C ]] && break; sleep 0.25; done
    sleep 2
    echo "$(( $(jq '.at[0]' <<<"$C") + $(jq '.size[0]' <<<"$C") * 2 / 3 )) $(( $(jq '.at[1]' <<<"$C") + $(jq '.size[1]' <<<"$C") / 2 ))" ;;
  nautilus-close)
    pkill -x nautilus; echo closed ;;
  desktop)
    pkill -x dnd-dst; pkill -x nautilus; sleep 1
    M=$(hyprctl monitors -j | jq -c '[.[] | select(.name != "NOTCH")][0]')
    echo "$(( $(jq '.width / .scale | floor' <<<"$M") / 2 )) $(( $(jq '.height / .scale | floor' <<<"$M") / 2 ))" ;;
  size)
    M=$(hyprctl monitors -j | jq -c '[.[] | select(.name != "NOTCH")][0]')
    echo "$(jq '.width / .scale | floor' <<<"$M") $(jq '.height / .scale | floor' <<<"$M")" ;;
  ls)
    ( cd "$2" 2>/dev/null && for f in *; do [[ -f $f ]] && echo "$(sha256sum "$f" | cut -c1-16) $(stat -c %s "$f") $f"; done ) ;;
  status)
    omacvm-drop status ;;
  cursor)
    hyprctl cursorpos ;;
esac
