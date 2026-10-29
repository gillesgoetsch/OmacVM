#!/bin/bash
# The control centre in the VM (feature control-centre). Run as root by
# ../../guest/install.sh:
#   control/guest/install.sh <desktop-user> on|off [vm-type]
# On: Textual (OmacVM's own copy), /usr/local/bin/omacvm, the root check socket (the
# guest checks for the control centre: a fixed command, nothing read from the
# caller), the app launcher entry, an "OmacVM" row in the Omarchy menu, the
# OmacVM item in the bar, the window rule that floats it in the middle
# (~/.config/hypr/omacvm_cc.lua), and the update notice (a user timer). OmacVM.app:
# the desktop user may open the app's control port. Off: all of it goes
# again. Idempotent. The menu, the bar and the launcher run `omacvm --window`.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> on|off [vm-type]}; WANT=${2:?on|off}; TYPE=${3:-}
PORT_RULE=/etc/udev/rules.d/70-omacvm-control.rules
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
SHARE=/usr/local/share/omacvm
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
user_ctl() { systemctl --user -M "$U@" "$@"; }
as_user() {
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}

# The menu row: two lines (a marker comment, then the row) in the user's own
# extension file, right after its opening brace; the rest of the file stays
# theirs. Omarchy strips only whole-line comments and trailing commas. As the user.
menu_line() {
  [[ -f $MENU || $1 == on ]] || return 0
  home_mkdir "$(dirname "$MENU")"
  home_run python3 - "$MENU" "$1" <<'PY'
import os, sys
path, want = sys.argv[1], sys.argv[2]
mark = "  // OmacVM control centre, the next line (on the Mac: omacvm disable control-centre)"
row = ('  "omacvm": {"icon":"\U000f0633","label":"OmacVM","description":"features, updates, report a problem",'
       '"action":"omarchy-launch-or-focus-tui omacvm --window"},')
old = open(path, encoding="utf-8").read() if os.path.exists(path) else "{\n}\n"
out, skip = [], False
for line in old.split("\n"):
    if skip:
        skip = False
    elif line.strip() == mark.strip():
        skip = True
    else:
        out.append(line)
if want == "on":
    at = next((i for i, l in enumerate(out) if l.strip() == "{"), None)
    if at is None:
        sys.exit("  the Omarchy menu file has no line with only '{': add an OmacVM row yourself (omarchy-launch-or-focus-tui omacvm --window)")
    out[at + 1:at + 1] = [mark, row]
new = "\n".join(out)
if new != old:
    tmp = path + ".omacvm"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.replace(tmp, path)
PY
}

# The window rule: omacvm_cc.lua, required from the user's hyprland.lua (a
# marker comment, then the line, as Glide does); a running Hyprland reloads.
HY=$H/.config/hypr
CC_LINE='require("hypr.omacvm_cc")'
CC_MARK='-- OmacVM control centre: a floating window in the middle.'
window_rule() {
  [[ -f $HY/hyprland.lua ]] || return 0   # not Omarchy 4's Lua config: nothing to add to
  local run sig
  if [[ $1 == on ]]; then
    if home_same "$HY/omacvm_cc.lua" omacvm_cc.lua && home_grep "$HY/hyprland.lua" -qxF "$CC_LINE"; then return 0; fi
    home_put "$HY/omacvm_cc.lua" < omacvm_cc.lua
    home_grep "$HY/hyprland.lua" -qxF "$CC_LINE" ||
      printf -- '%s\n%s\n' "$CC_MARK" "$CC_LINE" | home_append "$HY/hyprland.lua"
  else
    home_grep "$HY/hyprland.lua" -qxF "$CC_LINE" || [[ -f $HY/omacvm_cc.lua ]] || return 0
    # Only these two whole lines go; the file keeps its owner and mode.
    local keep; keep=$(mktemp)
    grep -vxF -e "$CC_MARK" -e "$CC_LINE" < <(home_cat "$HY/hyprland.lua") > "$keep" || true
    home_write "$HY/hyprland.lua" < "$keep"; rm -f "$keep"
    home_run rm -f "$HY/omacvm_cc.lua"
  fi
  # A running Hyprland picks it up now (no session yet, e.g. during a build: nothing to reload).
  run=/run/user/$(id -u "$U")
  sig=$(ls -t "$run/hypr" 2>/dev/null | head -1 || true)
  [[ -n $sig ]] && sudo -u "$U" env XDG_RUNTIME_DIR="$run" HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl reload >/dev/null 2>&1 || true
}

# Textual: OmacVM's own copy (control/vendor, pinned wheels), unpacked into
# the desktop user's cache here so the first start is quick. No pacman: until
# 3.0.6 it came from python-textual, which a VM whose package list is older
# than the mirrors cannot get (every download a 404), and the control centre
# stayed plain text. Not fatal: omacvm unpacks it itself at its next start.
# The bar item off: out of the bar, the folder gone, nothing queued. Under
# Omarchy's lock the folder stays (a write in ~/.config/omarchy/plugins would
# bring the lock screen back without its password field): out of the bar it
# does nothing, and the next apply removes it (guest/install.sh runs this
# while it is there).
bar_item_off() {
  local P=$H/.config/omarchy/plugins/omacvm.control C=$H/.config/omarchy/shell.json tmp st
  local Q=$H/.local/state/omacvm/pending-plugins
  # Neither a copy staged under the lock (lib/install-plugin.sh) nor a queued enable comes.
  home_run rm -rf "$H/.local/state/omacvm/plugins-staged/omacvm.control" < /dev/null
  if home_grep "$Q" -qxF omacvm.control; then { grep -vxF omacvm.control < <(home_cat "$Q") || true; } | home_put "$Q"; fi
  [[ -d $P ]] || return 0
  # Without a running shell, out of its bar settings by hand (it reads them when it starts).
  if ! as_user omarchy plugin disable omacvm.control >/dev/null 2>&1 && [[ -f $C ]]; then
    tmp=$(mktemp)
    if jq '(.bar.layout[]?) |= map(select(.id != "omacvm.control")) | (.plugins // empty) |= map(select(.id != "omacvm.control"))' \
         < <(home_cat "$C") > "$tmp"; then
      home_write "$C" < "$tmp"
    fi
    rm -f "$tmp"
  fi
  st=$(as_user bash ../../guest/session-lock.sh 2>/dev/null) || st=down
  if [[ $st == locked || $st == busy ]]; then return 0; fi
  home_run rm -rf "$P" < /dev/null
}

textual() {
  local out why try
  command -v python3 >/dev/null || ../../guest/pkg-add python || true
  for try in 1 2; do
    out=$(sudo -u "$U" env HOME="$H" python3 -I ../omacvm_cc/vendor.py 2>&1) || { why=$out; break; }
    why=$(sudo -u "$U" env HOME="$H" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import textual.app' "$out" 2>&1) && return 0
    # Unpacked before and damaged since (a file gone from the cache): the
    # finished set is never unpacked again by itself, so once more here (the
    # control centre's repair runs this).
    [[ $try == 1 && $out == "$H/.cache/omacvm/python/"* && $out != *..* && -d $out ]] || break
    home_run rm -rf "$out"
  done
  echo "  Textual is not ready (omacvm shows a plain table until it is): $(tail -n1 <<<"$why" | cut -c1-200)"
  return 1
}

if [[ $WANT == on ]]; then
  textual || true
  ln -sfn "$SHARE/control/omacvm" /usr/local/bin/omacvm
  # The guest checks run as root (they read services, the firewall, other
  # users' processes); the desktop user may ask for them through this socket.
  sed "s/@USER@/$U/g" omacvm-check.socket > /etc/systemd/system/omacvm-check.socket
  sed "s/@USER@/$U/g" omacvm-check@.service > /etc/systemd/system/omacvm-check@.service
  systemctl daemon-reload
  systemctl enable omacvm-check.socket >/dev/null 2>&1
  systemctl restart omacvm-check.socket
  install -Dm644 omacvm.desktop /usr/local/share/applications/omacvm.desktop
  # OmacVM.app: the requests go through the app's control port, which only
  # the desktop user may open.
  if [[ $TYPE == app ]]; then
    printf 'SUBSYSTEM=="virtio-ports", ATTR{name}=="org.omacvm.control", OWNER="%s", MODE="0600"\n' "$U" > "$PORT_RULE"
    udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
  fi
  install -m644 omacvm-notify.service omacvm-notify.timer /etc/systemd/user/
  user_ctl daemon-reload 2>/dev/null || true
  user_ctl enable --now omacvm-notify.timer >/dev/null 2>&1 ||
    { home_mkdir "$H/.config/systemd/user/timers.target.wants"
      home_run ln -sf /etc/systemd/user/omacvm-notify.timer "$H/.config/systemd/user/timers.target.wants/"; }
  menu_line on
  window_rule on
  ../../lib/install-plugin.sh "$U" ../plugins/omacvm.control
else
  [[ -L /usr/local/bin/omacvm ]] && rm -f /usr/local/bin/omacvm
  systemctl disable --now omacvm-check.socket >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/omacvm-check.socket /etc/systemd/system/omacvm-check@.service
  systemctl daemon-reload
  rm -f /usr/local/share/applications/omacvm.desktop
  if [[ -f $PORT_RULE ]]; then rm -f "$PORT_RULE"; udevadm control --reload 2>/dev/null || true; fi
  user_ctl disable --now omacvm-notify.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/user/omacvm-notify.service /etc/systemd/user/omacvm-notify.timer
  home_run rm -f "$H/.config/systemd/user/timers.target.wants/omacvm-notify.timer"
  menu_line off
  window_rule off
  bar_item_off
  home_run rm -rf "$H/.cache/omacvm"
fi
