#!/bin/bash
# Touch ID for sudo and polkit (ADR 0041), guest side, as root:
#   touchid.sh on | off [desktop-user]
# on: the PAM client, one PAM line at the top of the auth of sudo, sudo-i and
# polkit-1, the polkit rule and its note writer, their /run folder. The keys
# (/etc/omacvm/touchid-key, touchid-token) come from omacvm apply. For the
# desktop user: omacvm-touchid-theme and its user units, which send the
# Omarchy theme's colours to the Mac's Touch ID panel; omacvm-touchid-apps
# and its units, which tell the person once when an app such as 1Password
# needs its own switch for Touch ID (at the first on, at login, after an
# install; its marks are cleared each time Touch ID is turned on).
# off: all of it gone again, the keys too. The password works either way.
# A service with only the vendor's file (/usr/lib/pam.d/polkit-1 since
# polkit 127) gets a copy in /etc/pam.d with our line, made again on each
# on; off removes the copy.
# polkit 127 starts its helper in a sandbox without network: a drop-in lets
# it (and so the PAM client) reach the Mac's Bridge address, nothing else.
# OmacVM.app's VMs ask through the virtio port org.omacvm.auth: a udev rule
# keeps it root's alone (0600), so no user program can hold it open; on and
# off alike (every app VM has the port from 3.0.4, off or on).
# OMACVM_TOUCHID_ROOT: another root folder (tests).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${OMACVM_TOUCHID_ROOT:-}
BIN=$ROOT/usr/lib/omacvm/omacvm-touchid
NOTE=$ROOT/usr/lib/omacvm/omacvm-touchid-note
RULE=$ROOT/etc/polkit-1/rules.d/00-omacvm-touchid.rules
OLDRULE=$ROOT/etc/polkit-1/rules.d/49-omacvm-touchid.rules
THEME=$ROOT/usr/lib/omacvm/omacvm-touchid-theme
APPS=$ROOT/usr/lib/omacvm/omacvm-touchid-apps
APP_UNITS="omacvm-touchid-apps.service omacvm-touchid-apps.path"
UNITS=$ROOT/etc/systemd/user
U=${2:-}
TMPF=$ROOT/etc/tmpfiles.d/omacvm-touchid.conf
DROPIN=$ROOT/etc/systemd/system/polkit-agent-helper@.service.d/omacvm-touchid.conf
PAMD=$ROOT/etc/pam.d
PORT_RULE=$ROOT/etc/udev/rules.d/70-omacvm-auth.rules
VENDOR=$ROOT/usr/lib/pam.d
SERVICES="sudo sudo-i polkit-1"
MARK='# omacvm touch-id (ADR 0041): the Mac'"'"'s Touch ID first, the password after'
LINE='auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid'

COPY='# omacvm touch-id: a copy of'
pam_add() {   # <service>: our two lines before its first auth line
  local f=$PAMD/$1 src=$PAMD/$1
  if [[ ! -f $f ]] || grep -q "^$COPY /usr/lib/pam.d/$1 " "$f"; then
    # None, or our copy: made again from the vendor's file each time, so an
    # update of it (polkit's) is not hidden behind an old copy.
    [[ -f $VENDOR/$1 ]] || return 0   # no such service here: nothing to unlock
    { echo "$COPY /usr/lib/pam.d/$1 (omacvm disable touch-id removes it)"; cat "$VENDOR/$1"; } > "$f.omacvm-copy"
    src=$f.omacvm-copy
  elif grep -qxF "$LINE" "$f"; then
    return 0
  fi
  awk -v m="$MARK" -v l="$LINE" '!d && /^[[:space:]]*-?auth[[:space:]]/ { print m; print l; d = 1 } { print } END { if (!d) { print m; print l } }' \
    "$src" > "$f.omacvm-new"
  rm -f "$f.omacvm-copy"
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}
pam_remove() {
  local f=$PAMD/$1
  [[ -f $f ]] || return 0
  if grep -q "^$COPY /usr/lib/pam.d/$1 " "$f"; then rm -f "$f"; return 0; fi   # ours: the vendor's file counts again
  grep -qxF -e "$LINE" -e "$MARK" "$f" || return 0
  grep -vxF -e "$LINE" -e "$MARK" "$f" > "$f.omacvm-new" || true
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}

# The theme sender's and the app hint's user units, for the desktop user (only in a real VM).
# The theme sender's record of what it sent goes either way: the Mac may not
# have the theme (Touch ID was off, the Bridge is new), so "on" sends it again at once.
user_units() {   # on|off [first: Touch ID was off before]
  [[ -n $U && -z $ROOT ]] || return 0
  local uc=(systemctl --user -M "$U@") H
  H=$(getent passwd "$U" | cut -d: -f6) || true
  # shellcheck source=../../guest/home-files.sh
  source "$HERE/../../guest/home-files.sh"   # the home is written as the user
  [[ $H == /* ]] && home_run rm -f "$H/.local/state/omacvm/touchid-theme-sent"
  if [[ $1 == on ]]; then
    # Turned on now: the app hints may show again (once each).
    if [[ ${2:-} == first && $H == /* ]]; then home_run rm -f "$H"/.local/state/omacvm/touchid-hint-*; fi
    "${uc[@]}" daemon-reload 2>/dev/null || true
    # shellcheck disable=SC2086
    "${uc[@]}" enable omacvm-touchid-theme.path omacvm-touchid-theme.service $APP_UNITS >/dev/null 2>&1 || true
    "${uc[@]}" restart omacvm-touchid-theme.path omacvm-touchid-apps.path >/dev/null 2>&1 || true
    "${uc[@]}" start --no-block omacvm-touchid-theme.service omacvm-touchid-apps.service >/dev/null 2>&1 || true
  else
    # shellcheck disable=SC2086
    "${uc[@]}" disable --now omacvm-touchid-theme.path omacvm-touchid-theme.service $APP_UNITS >/dev/null 2>&1 || true
  fi
}

is_app() { grep -qsE "^OMACVM_VM_TYPE=['\"]?app['\"]?$" "$ROOT/etc/omacvm/env"; }
# OmacVM.app's port (every app VM has it from 3.0.4, whatever the setting):
# root's alone, so no user program can open it or hold it open.
port_rule() {
  local r='SUBSYSTEM=="virtio-ports", ATTR{name}=="org.omacvm.auth", OWNER="root", GROUP="root", MODE="0600"'
  [[ $(cat "$PORT_RULE" 2>/dev/null) == "$r" ]] && return 0
  mkdir -p "$(dirname "$PORT_RULE")"
  echo "$r" > "$PORT_RULE"
  if [[ -z $ROOT ]]; then udevadm control --reload 2>/dev/null || true; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true; fi
}

case ${1:-} in
  on)
    first=""; [[ -e $BIN ]] || first=first
    mkdir -p "$(dirname "$BIN")" "$(dirname "$RULE")" "$(dirname "$TMPF")"
    install -m755 "$HERE/omacvm-touchid" "$BIN"
    install -m755 "$HERE/omacvm-touchid-note" "$NOTE"
    install -m755 "$HERE/omacvm-touchid-theme" "$THEME"
    install -m755 "$HERE/omacvm-touchid-apps" "$APPS"
    mkdir -p "$UNITS"
    install -m644 "$HERE/omacvm-touchid-theme.service" "$HERE/omacvm-touchid-theme.path" \
      "$HERE/omacvm-touchid-apps.service" "$HERE/omacvm-touchid-apps.path" "$UNITS/"
    install -m644 "$HERE/00-omacvm-touchid.rules" "$RULE"
    rm -f "$OLDRULE"
    echo 'd /run/omacvm-touchid 0700 polkitd polkitd -' > "$TMPF"
    [[ -n $ROOT ]] || systemd-tmpfiles --create "$TMPF" 2>/dev/null || true
    host=$( { sed -n "s/^OMACVM_HOST=['\"]\{0,1\}\([0-9.]*\).*/\1/p" "$ROOT/etc/omacvm/env" 2>/dev/null || true; } | tail -1)
    [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || host=10.0.2.2   # the client's default too
    mkdir -p "$(dirname "$DROPIN")"
    if is_app; then
      # OmacVM.app: no network, only the port (bound into its private /dev; "-": a VM
      # started before touch-id was on has none yet, and polkit must still work).
      printf '%s\n' "# omacvm touch-id (ADR 0041): polkit's helper may open OmacVM.app's Touch ID port, nothing else" \
        '[Service]' 'BindPaths=-/dev/virtio-ports/org.omacvm.auth' 'DeviceAllow=char-virtio-portsdev rw' > "$DROPIN"
    else
      printf '%s\n' "# omacvm touch-id (ADR 0041): polkit's helper may reach the Mac's Bridge ($host), nothing else" \
        '[Service]' 'PrivateNetwork=no' 'RestrictAddressFamilies=AF_UNIX AF_INET' 'IPAddressDeny=any' "IPAddressAllow=$host" > "$DROPIN"
    fi
    [[ -n $ROOT ]] || systemctl daemon-reload 2>/dev/null || true
    port_rule
    for s in $SERVICES; do pam_add "$s"; done
    user_units on "$first" ;;
  off)
    user_units off
    rm -f "$THEME" "$UNITS/omacvm-touchid-theme.service" "$UNITS/omacvm-touchid-theme.path"
    rm -f "$APPS" "$UNITS/omacvm-touchid-apps.service" "$UNITS/omacvm-touchid-apps.path"
    for s in $SERVICES; do pam_remove "$s"; done
    rm -f "$RULE" "$OLDRULE" "$TMPF" "$BIN" "$NOTE" "$ROOT/etc/omacvm/touchid-key" "$ROOT/etc/omacvm/touchid-token"
    rm -rf "$ROOT/run/omacvm-touchid"
    # OmacVM.app gives every VM the port (3.0.4): it stays root's alone while off too.
    if is_app; then port_rule
    elif [[ -e $PORT_RULE ]]; then rm -f "$PORT_RULE"; [[ -n $ROOT ]] || udevadm control --reload 2>/dev/null || true; fi
    if [[ -e $DROPIN ]]; then
      rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
      [[ -n $ROOT ]] || systemctl daemon-reload 2>/dev/null || true
    fi ;;
  *) echo "touchid.sh on|off [desktop-user]" >&2; exit 2 ;;
esac
