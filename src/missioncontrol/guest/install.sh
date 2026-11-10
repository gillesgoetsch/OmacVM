#!/bin/bash
# Mission Control (feature mission-control: experimental, off by default,
# Omarchy 4.5, needs Trackpad gestures; docs/features.md): the Mac Mission
# Control plugin by Gilles Goetsch (MIT,
# github.com/gillesgoetsch/omarchy-mac-mission-control), the files of the
# commit in ../PIN byte for byte (../SHA256SUMS; ../sync.sh). As root in the VM:
#   install.sh USER on           OmacVM's copy in place (lib/install-plugin.sh:
#                                staged under the lock, queued without a
#                                shell) and enabled; a copy of the owner's own
#                                (`omarchy plugin add`, a git clone) is only
#                                enabled, never written
#   install.sh USER off          off again, but only what OmacVM switched on
#                                (the marker ~/.local/state/omacvm/missioncontrol):
#                                windows shown, the plugin disabled, OmacVM's
#                                copy removed, Hyprland's hooks gone with one
#                                config reload; under the lock the folder and
#                                the reload wait for the next apply
#   install.sh USER --repair     hidden windows shown again; a shell that hangs
#                                with the overview on screen restarted
#   install.sh USER --status on|off
#                                one line for omacvm check: STATUS DETAIL,
#                                STATUS one of ok warn fail skip human
# Exit 3: the VM's Omarchy is below 4.5 (nothing done). Every call to the
# shell or Hyprland has a time limit: a shell that hangs never stops an apply.
# OmacVM never removes a bind or a gesture at run time (the plugin's rule:
# Hyprland 0.56's Keybind:remove() takes the user's binds on that key along);
# a config reload is the one way its hooks go.
# Tests: ../tests/run.sh (OMACVM_MC_HOME, OMACVM_MC_RUN and a PATH of
# stand-ins for omarchy, omarchy-shell, hyprctl, pacman and timeout).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$here/../.." && pwd)   # this copy of src/
U=${1:?usage: install.sh USER on|off|--repair|--status on|off}
ACTION=${2:?usage: install.sh USER on|off|--repair|--status on|off}
ID=mac.missioncontrol
SRC=$here/../plugin/$ID
H=${OMACVM_MC_HOME:-$(getent passwd "$U" | cut -d: -f6)}
RUN=${OMACVM_MC_RUN:-/run/user/$(id -u "$U")}
INSTALL_PLUGIN=${OMACVM_MC_INSTALL_PLUGIN:-$R/lib/install-plugin.sh}
# shellcheck source=../../guest/home-files.sh
source "$R/guest/home-files.sh"   # the home is written as the user
P=$H/.config/omarchy/plugins/$ID
ST=$H/.local/state/omacvm
MARK=$ST/missioncontrol
CONF=$H/.config/omarchy/shell.json
Q=$ST/pending-plugins
PIN_COMMIT=$(sed -n 's/^commit //p' "$here/../PIN" | head -n 1)
LAYER=mac-mission-control
HIDDEN_TAG=mac-mission-control-hidden

# As the desktop user, in the session: Omarchy's environment, Hyprland's
# instance, a locale (qs prints Qt's warning before every answer without
# one) and a short limit for every answer of the shell; in / (root's apply
# runs in /root, which Omarchy's commands cannot read as the user).
as_user() {
  local sig pre=()
  sig=$(ls -t "$RUN/hypr" 2>/dev/null | head -n 1)
  (( EUID == 0 )) && pre=(sudo -u "$U")
  ${pre[@]+"${pre[@]}"} env HOME="$H" XDG_RUNTIME_DIR="$RUN" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    LC_ALL=C.UTF-8 OMARCHY_SHELL_IPC_TIMEOUT=2s \
    bash -c 'cd / && source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}
hypr() { as_user timeout 5 hyprctl "$@" 2>/dev/null; }
# A Lua test in Hyprland: true when it raises no error.
hypr_lua() { hypr eval "$1" >/dev/null; }
hypr_up() { [[ -n $(ls "$RUN/hypr" 2>/dev/null) ]] && hypr monitors -j >/dev/null; }
# The overview's own answer (a JSON line), empty when it gives none.
mc_state() { as_user timeout 3 omarchy-shell shell call "$ID" debugState "" 2>/dev/null | grep '^{' | tail -n 1; }
# The overview's layer is on a screen.
layer_up() {
  hypr layers -j | jq -e --arg ns "$LAYER" '[.. | objects | select(.namespace? == $ns)] | length > 0' >/dev/null 2>&1
}
hidden_count() {
  hypr clients -j | jq --arg t "$HIDDEN_TAG" '[.[] | select((.tags // []) | any(. == $t or . == ($t + "*")))] | length' 2>/dev/null
}
binds_count() {
  hypr binds -j | jq '[.[] | select((.description // "") | startswith("Mission Control"))] | length' 2>/dev/null
}
hooks_set() { hypr_up && hypr_lua 'if mac_mission_control_hooks == nil then error("none") end'; }
live() { hypr_lua 'if not (mac_mission_control and mac_mission_control.live) then error("not live") end'; }
# The session (guest/session-lock.sh): down, busy, locked or open. Busy also
# when the shell takes longer than its limit to say.
session() {
  local s
  s=$(as_user timeout 10 bash "$R/guest/session-lock.sh" 2>/dev/null) || s=""
  case $s in down|busy|locked|open) echo "$s" ;; *) echo busy ;; esac
}
# Hyprland itself holds a session lock (Omarchy's own test; also with a shell that hangs).
hypr_locked() { as_user timeout 5 omarchy-hyprland-session-locked >/dev/null 2>&1; }

own_clone() { home_run test -e "$P/.git" < /dev/null; }
ours() { home_run test -f "$MARK" < /dev/null; }
in_config() {
  jq -e --arg id "$ID" '[.bar.layout[]?[]?.id, .plugins[]?.id] | index($id) != null' \
    < <(home_cat "$CONF") >/dev/null 2>&1
}
# shell.json without (or with) the plugin, for a shell that does not answer
# or does not run (it reads the file when it starts).
conf_edit() {
  local tmp f
  if [[ $1 == off ]]; then
    f='(.bar.layout[]?) |= map(select(.id != $id)) | (.plugins // empty) |= map(select(.id != $id))'
  else
    f='.plugins = ((.plugins // []) | map(select(.id != $id)) + [{id: $id}])'
  fi
  tmp=$(mktemp)
  if { home_cat "$CONF" || echo '{}'; } | jq --arg id "$ID" "$f" > "$tmp" 2>/dev/null && [[ -s $tmp ]]; then
    home_mkdir "$(dirname "$CONF")"
    home_write "$CONF" < "$tmp"
  fi
  rm -f "$tmp"
}
plugin_enable() {
  in_config && return 0
  as_user timeout 10 omarchy plugin enable "$ID" >/dev/null 2>&1 || conf_edit on
}
plugin_disable() {
  in_config || return 0
  as_user timeout 10 omarchy plugin disable "$ID" >/dev/null 2>&1 || conf_edit off
}
# The copy is the pinned one, byte for byte.
copy_ok() { ( cd "$SRC" && sha256sum -c --quiet "$here/../SHA256SUMS" ) >/dev/null 2>&1; }
same_as_ours() { [[ -d $P ]] && home_run diff -rq "$SRC" "$P" >/dev/null 2>&1 < /dev/null; }
omarchy_version() { pacman -Q omarchy 2>/dev/null | awk '{ print $2 }'; }
at45() {   # VERSION: 4.5 or later (guest/omarchy-move.sh's rule)
  [[ ${1:-} =~ ^([0-9]+)\.([0-9]+) ]] &&
    (( BASH_REMATCH[1] > 4 || (BASH_REMATCH[1] == 4 && BASH_REMATCH[2] >= 5) ))
}
# Four fingers sideways page while it is open only with the swipe the plugin
# takes over: ~/.config/hypr/input.lua's 4-finger workspace line, as
# gestures/guest/install.sh writes it (the plugin's own test), or its
# `sideways = true`.
paging() {
  home_grep "$H/.config/hypr/input.lua" -Eq \
    '^[[:space:]]*hl\.gesture\([[:space:]]*\{[[:space:]]*fingers[[:space:]]*=[[:space:]]*4[[:space:]]*,[[:space:]]*direction[[:space:]]*=[[:space:]]*"horizontal"[[:space:]]*,[[:space:]]*action[[:space:]]*=[[:space:]]*"workspace"[[:space:]]*\}[[:space:]]*\)' ||
    hypr_lua 'if not (type(mac_mission_control_config) == "table" and mac_mission_control_config.sideways == true) then error("no") end'
}

# A shell that hangs with the overview on screen: the overview covers the
# windows until the shell goes. Restarted (Omarchy's own restart, which
# locks again when Hyprland holds a lock without a live lock screen); if the
# old one still does not go, it is killed first. Never while Hyprland holds
# a lock (the lock screen lives in that shell). Status 1: still covered.
unhang() {
  layer_up || return 0
  [[ -n $(mc_state) ]] && return 0
  if hypr_locked; then
    echo "Mission Control: the shell does not answer and the session is locked: unlock, then omacvm apply --reinstall mission-control"
    return 1
  fi
  echo "Mission Control: the Omarchy shell does not answer and its overview covers the screen: restarting the shell"
  as_user timeout 100 omarchy-restart-shell >/dev/null 2>&1
  if layer_up && [[ -z $(mc_state) ]]; then
    pkill -KILL -u "$U" -x quickshell 2>/dev/null
    as_user timeout 100 omarchy-restart-shell >/dev/null 2>&1
  fi
  ! { layer_up && [[ -z $(mc_state) ]]; }
}

# Windows the plugin hid shown again (its own reset), and a hung shell gone.
repair() {
  local rc=0
  hypr_up || { echo "Mission Control: no Hyprland session: nothing to repair"; return 0; }
  hypr_lua 'if mac_mission_control then mac_mission_control.reset() end'
  unhang || rc=1
  # Enabled, but its Hyprland half is not loaded: a config reload loads it.
  if (( rc == 0 )) && in_config && ! live && [[ $(session) == open ]]; then
    hypr reload >/dev/null; sleep 1
  fi
  echo "Mission Control: $(hidden_count || echo ?) windows hidden, overview $(layer_up && echo "on screen" || echo closed)"
  return $rc
}

off() {
  local s gone=1
  # Neither a queued enable nor a copy staged under the lock comes.
  home_run rm -rf "$ST/plugins-staged/$ID" < /dev/null
  if home_grep "$Q" -qxF "$ID"; then { grep -vxF "$ID" < <(home_cat "$Q") || true; } | home_put "$Q"; fi
  ours || return 0   # OmacVM never switched it on: the owner's own copy stays as it is
  if hypr_up; then
    hypr_lua 'if mac_mission_control then mac_mission_control.reset() end'
    unhang || true
  fi
  plugin_disable
  s=$(session)
  # Hyprland keeps the plugin's gesture, keys and rules until a config
  # reload. Not under the lock (the next apply while off does it); first
  # the overlay goes, so that the reload does not load the Lua again.
  if hooks_set; then
    if [[ $s == open ]]; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -z $(mc_state) ]] && break; sleep 0.5; done
      hypr reload >/dev/null
      sleep 1
      hooks_set && { echo "Mission Control: its gesture and keys are still in Hyprland (hyprctl reload)"; gone=0; }
    else
      gone=0
    fi
  fi
  # OmacVM's copy goes; never under the lock (guest/session-lock.sh).
  if [[ -e $P ]] && ! own_clone; then
    if [[ $s == locked || $s == busy ]]; then gone=0; else home_run rm -rf "$P" < /dev/null; fi
  fi
  if (( gone )); then home_run rm -f "$MARK" < /dev/null
  else echo "Mission Control: off; the rest goes at the next apply after the unlock"; fi
  return 0
}

on() {
  local om s before after new settle=0 own=0
  om=$(omarchy_version)
  if ! at45 "$om"; then
    echo "OmacVM: Mission Control needs Omarchy 4.5 (this VM has ${om:-no omarchy package}): Move to Omarchy 4.5 in OmacVM.app"
    return 3
  fi
  copy_ok || { echo "OmacVM: Mission Control: OmacVM's copy of the plugin is not the pinned one (SHA256SUMS)"; return 1; }
  own_clone && own=1
  before=$(hypr configerrors)
  # Written first: an off from here on knows that OmacVM switched it on.
  home_mkdir "$ST"
  printf '%s\n' "$PIN_COMMIT" | home_put "$MARK"
  if (( own )); then
    plugin_enable
  else
    s=$(session)
    [[ $s == open && -d $P ]] && ! same_as_ours && settle=1
    "$INSTALL_PLUGIN" "$U" "$SRC" || { echo "OmacVM: Mission Control: the plugin did not install"; return 1; }
    # A changed copy starts a hot reload in the running shell; the apply's
    # one shell restart on top of one has crashed Quickshell (the plugin's
    # own scripts/dev-install.sh waits as long).
    (( settle )) && sleep 3
  fi
  [[ $(session) == open ]] || return 0   # loads with the next shell; checked then (omacvm check)
  # A new folder: the shell reads it in the background after
  # lib/install-plugin.sh's rescan, so its enable can come too early (then
  # the end of the apply enables it). Enabled here once the shell knows it,
  # so that it is on, and checked, within this step.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    in_config && break
    sleep 1
    as_user timeout 10 omarchy plugin enable "$ID" >/dev/null 2>&1 || continue
    if home_grep "$Q" -qxF "$ID"; then { grep -vxF "$ID" < <(home_cat "$Q") || true; } | home_put "$Q"; fi
  done
  # The shell loads the Hyprland half 150 ms after the plugin; then its
  # gesture is in. A new config error then (a four-finger up or down swipe
  # of the user's own takes the same swipe): off again, with the reason.
  for _ in $(seq 1 30); do live && break; sleep 0.5; done
  after=$(hypr configerrors)
  new=$(grep -vxF -f <(printf '%s\n' "$before") <<<"$after" | grep . | head -n 1)
  if [[ -n $new ]]; then
    off >/dev/null
    echo "OmacVM: Mission Control: Hyprland reported \"$(cut -c1-160 <<<"$new")\" once it was on; a four-finger up or down gesture of your own (~/.config/hypr) takes the same swipe: switched off again"
    return 1
  fi
  live || echo "Mission Control: on; its Hyprland half loads with the shell (omacvm check)"
  return 0
}

status() {   # on|off: the switch
  local om c n ph h own="" lay
  om=$(omarchy_version)
  own_clone && own=" (your own copy, omarchy plugin update)"
  if [[ $1 != on ]]; then
    if ours && in_config; then echo "fail off, but still on in the Omarchy shell: omacvm apply"
    elif ours; then echo "human off; the rest goes at the next apply while the session is open"
    elif [[ -n $own ]]; then echo "skip off in OmacVM; your own copy (omarchy plugin) is $(in_config && echo on || echo off)"
    elif ! at45 "$om"; then echo "skip off (needs Omarchy 4.5)"
    else echo "skip off (experimental: omacvm enable mission-control)"; fi
    return 0
  fi
  if ! at45 "$om"; then echo "fail needs Omarchy 4.5 (this VM has ${om:-none}): Move to Omarchy 4.5 in OmacVM.app"; return 0; fi
  if [[ ! -d $P ]]; then
    if home_run test -d "$ST/plugins-staged/$ID" < /dev/null; then echo "human in place right after the next unlock"
    else echo "fail not installed: omacvm apply --reinstall mission-control"; fi
    return 0
  fi
  if [[ -z $own ]] && ! same_as_ours; then echo "fail the plugin's files are not OmacVM's pinned copy: omacvm apply --reinstall mission-control"; return 0; fi
  if ! in_config; then
    if home_grep "$Q" -qxF "$ID"; then echo "human enabled at the next login"
    else echo "fail not enabled in the Omarchy shell: omacvm apply --reinstall mission-control"; fi
    return 0
  fi
  hypr_up || { echo "human log in (it loads with the desktop)"; return 0; }
  h=$(hidden_count); lay=0; layer_up && lay=1
  c=$(mc_state)
  if [[ -z $c ]]; then
    if (( lay )) || [[ ${h:-0} -gt 0 ]]; then echo "fail the Omarchy shell does not answer and ${h:-?} windows are hidden: omacvm apply --reinstall mission-control"
    else echo "warn the overview does not answer (the Omarchy shell restarting?)"; fi
    return 0
  fi
  ph=$(jq -r '.phase // "?"' <<<"$c" 2>/dev/null)
  if [[ $ph == closed ]] && { [[ ${h:-0} -gt 0 ]] || (( lay )); }; then
    echo "fail ${h:-?} windows left hidden while the overview is closed: omacvm apply --reinstall mission-control"; return 0
  fi
  live || { echo "fail its Hyprland half is not loaded: omacvm apply --reinstall mission-control"; return 0; }
  n=$(binds_count)
  [[ ${n:-0} -ge 1 ]] || { echo "fail no Mission Control keys in Hyprland: omacvm apply --reinstall mission-control"; return 0; }
  if ! paging; then
    echo "warn four fingers up open it; sideways paging is off: ~/.config/hypr/input.lua has no 4-finger workspace swipe$own"
  else
    echo "ok four fingers up open it, sideways page while it is open$own"
  fi
}

case $ACTION in
  --status) status "${3:-off}"; exit 0 ;;
  --repair) repair; exit $? ;;
  on) on; exit $? ;;
  off) off; exit $? ;;
  *) echo "usage: install.sh USER on|off|--repair|--status on|off" >&2; exit 2 ;;
esac
