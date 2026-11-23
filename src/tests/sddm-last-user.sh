#!/bin/bash
# Omarchy's login screen has no user field and sends SDDM's last user (#837):
# guest/autologin.sh's sddm_last_user_set gives a VM whose state names nobody
# (no file, an empty User=, the image's placeholder) the desktop user, and
# leaves a real last user, the rest of the file and other folders alone;
# guest/install.sh calls it, guest/check.sh warns while it names nobody.
#   src/tests/sddm-last-user.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
expect() { if [[ "$3" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: wanted [$2], got [$3]"; fail=1; fi; }

root() {   # a fresh root: users xa4 and other, SDDM's folder, Omarchy 4.5's session file
  rm -rf "$T/r"; mkdir -p "$T/r/etc" "$T/r/var/lib/sddm" "$T/r/usr/local/share/wayland-sessions" "$T/r/usr/share/wayland-sessions"
  printf 'root:x:0:0::/root:/bin/bash\nxa4:x:1000:1000::/home/xa4:/bin/bash\nother:x:1001:1001::/home/other:/bin/bash\n' > "$T/r/etc/passwd"
  : > "$T/r/usr/local/share/wayland-sessions/omarchy.desktop"
  : > "$T/r/usr/share/wayland-sessions/hyprland-uwsm.desktop"
}
set_() { (SDDM_ROOT=$T/r; source "$R/src/guest/autologin.sh"; sddm_last_user_set "$1"); }
last() { (SDDM_ROOT=$T/r; source "$R/src/guest/autologin.sh"; sddm_last_user); }
st() { cat "$T/r/var/lib/sddm/state.conf" 2>/dev/null | paste -sd '|' -; }

root
expect "no state file: nobody" "" "$(last)"
out=$(set_ xa4)
expect "no state file: written with the user and Omarchy's session" \
  "[Last]|Session=/usr/local/share/wayland-sessions/omarchy.desktop|User=xa4" "$(st)"
expect "... and said so" "login screen: SDDM's last user is xa4 now (it named nobody), so Omarchy's login screen logs in as xa4" "$out"
expect "... no temporary file left" "" "$(ls -A "$T/r/var/lib/sddm" | grep -v '^state.conf$')"
expect "again: nothing to do, nothing said" "" "$(set_ xa4)"

root; rm "$T/r/usr/local/share/wayland-sessions/omarchy.desktop"
set_ xa4 >/dev/null
expect "Omarchy 4.0 (no omarchy.desktop): hyprland-uwsm's session" "[Last]|Session=/usr/share/wayland-sessions/hyprland-uwsm.desktop|User=xa4" "$(st)"

root; printf '[Last]\nSession=/usr/share/wayland-sessions/hyprland-uwsm.desktop\nUser=\n' > "$T/r/var/lib/sddm/state.conf"
set_ xa4 >/dev/null
expect "an empty User=: the user, its session kept" "[Last]|Session=/usr/share/wayland-sessions/hyprland-uwsm.desktop|User=xa4" "$(st)"

root; printf '[Last]\n# kept\nSession=\nUser=pbuser\n\n[Other]\nUser=x\n' > "$T/r/var/lib/sddm/state.conf"
set_ xa4 >/dev/null
expect "the image's placeholder (no such user): replaced, an empty Session= filled, other sections kept" \
  "[Last]|# kept|User=xa4||Session=/usr/local/share/wayland-sessions/omarchy.desktop|[Other]|User=x" "$(st)"

root; printf '[Last]\nSession=/x.desktop\nUser=other\n' > "$T/r/var/lib/sddm/state.conf"
ino=$(ls -i "$T/r/var/lib/sddm/state.conf" | awk '{print $1}')
expect "a real last user: left alone, nothing said" "" "$(set_ xa4)"
expect "... the file untouched" "$ino [Last]|Session=/x.desktop|User=other" "$(ls -i "$T/r/var/lib/sddm/state.conf" | awk '{print $1}') $(st)"

root; printf 'secret\n' > "$T/target"; ln -s "$T/target" "$T/r/var/lib/sddm/state.conf"
set_ xa4 >/dev/null
expect "state.conf a link: replaced by a file, its target untouched" \
  "file secret" "$([[ -L $T/r/var/lib/sddm/state.conf ]] && echo link || echo file) $(cat "$T/target")"

root; rm -rf "$T/r/var/lib/sddm"
expect "no SDDM folder: nothing made" "|no" "$(set_ xa4)|$([[ -e $T/r/var/lib/sddm ]] && echo yes || echo no)"

# The wiring: install.sh sets it on every run, after the autologin step; check.sh warns.
expect "install.sh sets SDDM's last user" 1 "$(grep -c '^r=$(sddm_last_user_set "$U")' "$R/src/guest/install.sh")"
expect "check.sh warns while it names nobody" 1 "$(grep -c 'warn "login screen" "names no user' "$R/src/guest/check.sh")"

exit $fail
