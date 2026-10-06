# OmacVM, guest side: "off" for the features that run something in the VM
# that talks to the Mac. Sourced by guest/install.sh (and by
# src/tests/features-off.sh on macOS: bash 3.2, GNU-only options avoided).
# Each *_off leaves nothing that runs or connects to the Mac, whatever state
# the VM is in: session running or not, an install cut off, an install
# queued for the next login. Nothing of the feature there: no output.
# Needs from the caller: U, H (the desktop user and home), R (this copy of
# src/), ROOT ("" in the VM; the tests' scratch folder), and the functions
# log, user_ctl (systemctl --user for U), in_session (a command in U's
# session) and restart_shell_later.

# off_any PATH...: one of them is there (a file, folder or link)
off_any() {
  local p
  for p in "$@"; do [[ -e $ROOT$p || -L $ROOT$p ]] && return 0; done
  return 1
}

# off_lines FILE LINE...: FILE without those lines (owner and mode kept)
off_lines() {
  local f=$ROOT$1 t l; shift
  [[ -f $f ]] || return 0
  t=$(mktemp) || return 0
  cp "$f" "$t"
  # grep finds nothing once the last line goes (status 1): not a failure.
  for l in "$@"; do { grep -vxF -e "$l" "$t" || true; } > "$t.n"; mv -f "$t.n" "$t"; done
  cmp -s "$t" "$f" || cat "$t" > "$f"
  rm -f "$t"
}

# user_units_off UNIT...: off for the desktop user, also while nobody is
# logged in (no user manager to ask): stopped, not enabled for everyone, no
# links of the user's own.
user_units_off() {
  local u w
  for u in "$@"; do
    user_ctl disable --now "$u" >/dev/null 2>&1 || true
    systemctl --global disable "$u" >/dev/null 2>&1 || true
    for w in "$ROOT$H"/.config/systemd/user/*.wants/"$u" "$ROOT"/etc/systemd/user/*.wants/"$u"; do
      if [[ -L $w ]]; then rm -f "$w"; fi
    done
  done
}

# plugins_off_at_login ID...: omacvm-plugins disables them at the next login.
plugins_off_at_login() {
  local s=$ROOT$H/.local/state/omacvm w=$ROOT$H/.config/systemd/user/graphical-session.target.wants id
  mkdir -p "$s"
  for id in "$@"; do grep -qxF "$id" "$s/pending-plugins-off" 2>/dev/null || echo "$id" >> "$s/pending-plugins-off"; done
  if [[ -f $ROOT/etc/systemd/user/omacvm-plugins.service && ! -e $w/omacvm-plugins.service ]]; then
    mkdir -p "$w"; ln -sf /etc/systemd/user/omacvm-plugins.service "$w/"
  fi
  chown -R "$U:$U" "$s" 2>/dev/null; chown -hR "$U:$U" "$ROOT$H/.config/systemd" 2>/dev/null
  return 0
}

# Gestures: the daemon (a system service) on every route; on UTM, Fusion and
# OmacVM.app it also typed Cmd as Super, which goes with it.
gestures_off() {
  systemctl is-enabled -q omacvm-gestures 2>/dev/null || systemctl is-active -q omacvm-gestures 2>/dev/null || return 0
  log "gestures: off"
  systemctl disable --now omacvm-gestures >/dev/null 2>&1 || true
}

# Omanotch: notchcast, and its install queued for the next login
# (omacvm-omanotch.service builds it there when the session was not running).
omanotch_off() {
  local n=$H/.local/bin/notchcast u=$H/.config/systemd/user/notchcast.service
  local q=/etc/systemd/user/omacvm-omanotch.service hook=/etc/pacman.d/hooks/zz-omacvm-omanotch-notifications.hook
  local panel=$H/.config/omarchy/plugins/omanotch.monitor
  off_any "$n" "$u" "$u.d" "$q" "$hook" "$H/.config/hypr/notchbar.lua" "$H/.local/state/omacvm/omanotch" "$panel" || return 0
  log "Omanotch: off"
  user_units_off omacvm-omanotch.service
  rm -f "$ROOT$q" "$ROOT$hook"
  [[ -z $("$R/guest/omanotch-notifications.sh" off 2>/dev/null || true) ]] || restart_shell_later
  # Omanotch's own uninstall needs the session (Hyprland, the shell); the
  # files go here too, so it is off also without one.
  if off_any "$n" "$u"; then in_session bash "$R/omanotch/guest/uninstall.sh" >/dev/null 2>&1 || true; fi
  # Its display panel clone (UTM, Fusion, Parallels): without the session,
  # Omarchy's panel goes back in its place in shell.json itself.
  if [[ -d $ROOT$panel ]]; then
    XDG_CONFIG_HOME=$ROOT$H/.config python3 "$R/omanotch/guest/monitor/display-panel.py" --drop >/dev/null 2>&1 || true
  fi
  user_units_off notchcast.service
  rm -rf "$ROOT$u" "$ROOT$u.d"
  rm -f "$ROOT$n" "$ROOT$H/.local/bin/omanotch-display-panel" "$ROOT$H/.config/hypr/notchbar.lua" "$ROOT$H/.local/state/omacvm/omanotch" "$ROOT$H/.local/state/omanotch/expect"
  off_lines "$H/.config/hypr/hyprland.lua" '-- omarchy-notch-bar: hidden output for the macOS notch helper.' 'require("hypr.notchbar")'
}

# The Bridge: its event stream, the media keys OSD, the bar widgets (also the
# ones queued for the next login) and the client itself, so a widget left in
# the bar cannot reach the Mac either. Omarchy's own widgets come back.
BRIDGE_WIDGETS="omacvm.bluetooth omacvm.wifi omacvm.audio omacvm.wifiqr omacvm.nightshift"
bridge_widgets_in_bar() {
  # shellcheck disable=SC2086
  jq -e --arg w "$BRIDGE_WIDGETS" '($w | split(" ")) as $w | [.bar.layout[]?[]?.id, .plugins[]?.id] | any(. as $i | $w | index($i))' \
    "$ROOT$H/.config/omarchy/shell.json" >/dev/null 2>&1
}
bridge_off() {
  local b=/usr/local/bin e=/etc/systemd/user p q=$H/.local/state/omacvm/pending-plugins
  local nl=$ROOT$H/.local/state/omacvm/nightlight-indicator c=$ROOT$H/.config/omarchy/shell.json tmp
  off_any $b/omacvm-bridge $b/omacvm-bridge-osd $b/omacvm-bridge-events $e/omacvm-bridge-osd.service \
    $e/omacvm-bridge-events.socket $e/omacvm-bridge-events.service $b/omarchy-toggle-nightlight ||
    bridge_widgets_in_bar || return 0
  log "bridge: off"
  user_units_off omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service
  # shellcheck disable=SC2086
  off_lines "$q" $BRIDGE_WIDGETS
  # Disabling needs the running shell; without one (nobody logged in) they
  # are disabled at the next login (omacvm-plugins), and cannot reach the
  # Mac before that (their client goes below).
  # shellcheck disable=SC2086
  if in_session omarchy-shell shell ping >/dev/null 2>&1; then
    in_session bash -c 'for p in "$@"; do omarchy plugin disable "$p" >/dev/null 2>&1; done' _ $BRIDGE_WIDGETS >/dev/null 2>&1 || true
  else
    plugins_off_at_login $BRIDGE_WIDGETS
  fi
  # Widgets that still stream from the Mac.
  pkill -u "$U" -f -- "$b/omacvm-bridge" 2>/dev/null || true
  pkill -u "$U" -f -- "-N http://[^ ]*:47831/events" 2>/dev/null || true
  # Omarchy's own night light indicator, as it was before the Bridge.
  if [[ -f $nl && -f $c ]]; then
    tmp=$(mktemp "$c.XXXXXX")
    jq --argjson items "$(cat "$nl")" '(.bar.layout[]?[]? | select(.id == "omarchy.indicators")) |= (if $items == null then del(.items) else .items = $items end)' "$c" > "$tmp" &&
      cat "$tmp" > "$c"
    rm -f "$tmp" "$nl"
  fi
  for p in omarchy-toggle-nightlight omarchy-network-qr omarchy-network-password omacvm-bridge omacvm-bridge-osd omacvm-bridge-events; do
    rm -f "$ROOT$b/$p"
  done
  rm -f "$ROOT$e/omacvm-bridge-osd.service" "$ROOT$e/omacvm-bridge-events.socket" "$ROOT$e/omacvm-bridge-events.service"
}

# The wallpaper on the Mac: its watcher (through the Bridge).
wallpaper_off() {
  local e=/etc/systemd/user
  off_any /usr/local/bin/omacvm-wallpaper $e/omacvm-wallpaper.path $e/omacvm-wallpaper.service || return 0
  log "wallpaper: off"
  user_units_off omacvm-wallpaper.path omacvm-wallpaper.service
  rm -f "$ROOT/usr/local/bin/omacvm-wallpaper" "$ROOT$e/omacvm-wallpaper.path" "$ROOT$e/omacvm-wallpaper.service"
}
