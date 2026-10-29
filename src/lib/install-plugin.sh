#!/bin/bash
# Install one Omarchy shell plugin folder for the desktop user. Run as root:
#   lib/install-plugin.sh <desktop-user> <plugin-folder>
# Validates it and copies it to ~/.config/omarchy/plugins/<id>/ (nothing is
# written when that folder has it already). Enabling needs the running
# Omarchy shell: if it runs, the plugin is enabled now; otherwise
# (fresh build, nobody logged in yet) it is queued and omacvm-plugins
# enables it at the next login. A plugin may ship placement.sh (run as the
# user) to choose its spot in the bar.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=${1:?usage: install-plugin.sh <desktop-user> <plugin-folder>}; dir=$(cd "${2%/}" && pwd)
H=$(getent passwd "$U" | cut -d: -f6)
# shellcheck source=../guest/home-files.sh
source "$here/../guest/home-files.sh"   # the home is written as the user
# Omarchy's commands need its environment (OMARCHY_PATH, ...), which a root
# shell does not have: load Omarchy's own bootstrap first.
as_user() {
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}

id=$(jq -r .id "$dir/manifest.json")
dest=$H/.config/omarchy/plugins/$id
# The user copies it: from a copy the user can read (the caller's folder may
# be root's alone, as the app's display widget's temp folder).
pub=$(mktemp -d); trap 'rm -rf "$pub"' EXIT
cp -R "$dir/." "$pub/"; chmod -R a+rX,go-w "$pub"; dir=$pub
# Checked before anything is written: a plugin the shell would refuse never
# takes the place of one that works.
as_user omarchy plugin validate "$dir" >/dev/null
home_mkdir "$H/.config/omarchy/plugins" "$H/.local/state/omacvm"
# The folder in place has this content (and the same files executable).
xfiles() {
  home_run find "$1" -type f -perm -u+x < /dev/null 2>/dev/null |
    while IFS= read -r f; do printf '%s\n' "${f#"$1"}"; done | LC_ALL=C sort
}
same() {
  [[ -d $dest ]] && home_run diff -rq "$dir" "$dest" >/dev/null 2>&1 < /dev/null &&
    [[ $(xfiles "$dir") == "$(xfiles "$dest")" ]]
}
new=1
if same; then
  new=0   # nothing written: the shell reloads nothing and needs no restart for it
else
  # A running shell keeps the plugin it loaded: note real changes so
  # guest/install.sh restarts the shell once at the end.
  if [[ -d $dest ]]; then home_put "$H/.local/state/omacvm/restart-shell" < /dev/null; fi
  home_run rm -rf "$dest" < /dev/null
  home_run cp -r "$dir" "$dest" < /dev/null
fi

install -m755 "$here/omacvm-plugins" /usr/local/bin/omacvm-plugins
install -m644 "$here/omacvm-plugins.service" /etc/systemd/user/omacvm-plugins.service
Q=$H/.local/state/omacvm/pending-plugins
# On again before a disable queued at the next login ran: not disabled.
if [[ -f $Q-off ]]; then { grep -vxF "$id" < <(home_cat "$Q-off") || true; } | home_put "$Q-off"; fi
# Queued for the shell (rescan, enable, its place in the bar) only when there
# is something to do: a new or changed copy, or the plugin is not in
# shell.json (the user took it off the bar: placement.sh puts it back). An
# unchanged plugin in its place costs the shell nothing.
in_config() {
  jq -e --arg id "$id" '[.bar.layout[]?[]?.id, .plugins[]?.id] | index($id) != null' \
    < <(home_cat "$H/.config/omarchy/shell.json") >/dev/null 2>&1
}
queued=0
if (( new )) || ! in_config; then
  home_grep "$Q" -qx "$id" || echo "$id" | home_append "$Q"
  queued=1
fi
if as_user omarchy-shell shell ping >/dev/null 2>&1; then
  as_user /usr/local/bin/omacvm-plugins
elif (( queued )); then
  systemctl --user -M "$U@" enable omacvm-plugins.service >/dev/null 2>&1 ||
    { home_mkdir "$H/.config/systemd/user/graphical-session.target.wants"
      home_run ln -sf /etc/systemd/user/omacvm-plugins.service "$H/.config/systemd/user/graphical-session.target.wants/"; }
  echo "plugin $id installed (enabled at the next login)"
fi
