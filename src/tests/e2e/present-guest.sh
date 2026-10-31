#!/bin/bash
# present-locked.sh's helper in the test VM (root; copied to /root/omacvm-present and removed after).
#   links-off    the Mac links off (STANDARDS 18a: disable --now, mask fails for units in /etc):
#                omacvm-gestures (system), notchcast and the Bridge units (the desktop user's);
#                the enabled ones are noted in links-was; prints what it switched off
#   links-check  "inactive" when none of them runs, else the ones that do
#   links-back   enables again what was enabled (no start: the VM shuts down next)
#   mode         Virtual-1's mode from Hyprland: WxH@RATE
#   damage       "1 WHY" when the compositor's damage reaches QEMU (the kernel keeps it, or OmacVM's
#                driver with Linux 7.4's fix: guest/check.sh's "Changed parts"), else "0 WHY"
set -u
H=$(cd "$(dirname "$0")" && pwd)
U=$(id -nu 1000 2>/dev/null); X=/run/user/1000
SYS="omacvm-gestures.service"
USR="notchcast.service omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service"
asuser() {
  runuser -u "$U" -- env XDG_RUNTIME_DIR=$X DBUS_SESSION_BUS_ADDRESS=unix:path=$X/bus \
    HYPRLAND_INSTANCE_SIGNATURE="$(ls -t $X/hypr 2>/dev/null | head -1)" "$@"
}
case ${1:-} in
links-off)
  : > "$H/links-was"; off=""
  for u in $SYS; do
    [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] && echo "system $u" >> "$H/links-was"
    systemctl disable --now "$u" >/dev/null 2>&1 && off+="$u "
  done
  for u in $USR; do
    [[ $(asuser systemctl --user is-enabled "$u" 2>/dev/null) == enabled ]] && echo "user $u" >> "$H/links-was"
    asuser systemctl --user disable --now "$u" >/dev/null 2>&1 && off+="$u "
  done
  echo "off: ${off:-none there}"
  ;;
links-check)
  on=""
  for u in $SYS; do [[ $(systemctl is-active "$u" 2>/dev/null) == active ]] && on+="$u "; done
  for u in $USR; do [[ $(asuser systemctl --user is-active "$u" 2>/dev/null) == active ]] && on+="$u "; done
  [[ -z $on ]] && echo "inactive: $SYS $USR" || echo "active: $on"
  ;;
links-back)
  while read -r k u; do
    case $k in system) systemctl enable "$u" >/dev/null 2>&1 ;; user) asuser systemctl --user enable "$u" >/dev/null 2>&1 ;; esac
  done < "$H/links-was" 2>/dev/null
  ;;
mode)
  asuser hyprctl monitors 2>/dev/null | awk '/^Monitor Virtual-1 / { v = 1; next } v && $1 ~ /^[0-9]+x[0-9]+@/ { print $1; exit }'
  ;;
damage)
  k=$(uname -r); d=$(cat "/usr/local/lib/omacvm/virtio-gpu/$k/damage" 2>/dev/null); st=$(cat /run/omacvm/virtio-gpu 2>/dev/null)
  IFS=. read -r ma mi _ <<<"$k"; ma=${ma%%[!0-9]*}; mi=${mi%%[!0-9]*}; ma=${ma:-0}; mi=${mi:-0}
  if [[ $d == kernel ]] || (( ma > 7 || (ma == 7 && mi >= 4) )); then
    echo "1 Linux $k keeps the damage itself (loader: ${st:-no word})"
  elif [[ $d == ours && $st == omacvm* && $st != *"without damage_clips"* ]]; then echo "1 OmacVM's driver with the damage fix ($st, Linux $k)"
  else echo "0 Linux $k, build damage '${d:-none}', loader '${st:-no word}'"; fi
  ;;
*) echo "usage: present-guest.sh links-off|links-check|links-back|mode|damage" >&2; exit 2 ;;
esac
