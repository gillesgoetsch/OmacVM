#!/bin/bash
# restart-shell.sh [--after-unlock | --retire]: what an apply owes the running
# Omarchy shell, done while the session is open: copies of bar widgets staged
# under the lock go in place and queued ones are enabled (omacvm-plugins),
# the colour fix reaches the user's clones of Omarchy's plugins
# (shell-colors.py), then the shell restarts once if a widget it had loaded
# changed (the flag ~/.local/state/omacvm/restart-shell). Run as the desktop
# user, at the end of an apply (guest/install.sh) and at login
# (omacvm-plugins.service).
#
# Never while the session is locked (session-lock.sh; busy counts as locked):
# Omarchy's lock screen lives in the shell. A restart leaves Hyprland's
# "lockscreen app died" screen behind, and a plugin write or rescan brings
# the lock screen back without its password field. Locked: a user unit
# (omacvm-restart-shell) runs this again with --after-unlock, which does it
# right after the unlock. It ends without doing anything when the shell is
# gone (logout, shutdown): the files stay, and the next login does it.
#
# --retire (guest/install.sh, at its start): such a unit of an earlier apply
# stops, so that it never works beside this apply: at once while the session
# answers "locked" (it only waits then), else once it is done (90 s at most:
# it may be restarting the shell, and stopped then, there would be no shell
# and no lock screen). What it owed is in files; the end of the apply starts
# one again, with the newest code.
source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
# Update VM runs this without a locale. qs then prints Qt's locale warning
# before each answer, which also broke omarchy-restart-shell's own lock check
# (it took a live lock for a dead one: killed the lock screen and locked again).
export LC_ALL=C.UTF-8
here=$(cd "$(dirname "$0")" && pwd)
self=$here/$(basename "$0")
# shellcheck source=session-lock.sh
source "$here/session-lock.sh"
ST=${XDG_STATE_HOME:-$HOME/.local/state}/omacvm
FLAG=$ST/restart-shell
UNIT=omacvm-restart-shell.service
PLUGINS=/usr/local/bin/omacvm-plugins
COLORS=/usr/local/lib/omacvm/shell-colors.py

owed() {
  local d
  [[ -e $FLAG || -s $ST/pending-plugins || -s $ST/pending-plugins-off || -s $ST/pending-clock ]] && return 0
  for d in "$ST"/plugins-staged/*/; do [[ -d $d ]] && return 0; done
  return 1
}
shell_pid() { pgrep -u "$(id -u)" -x quickshell 2>/dev/null | head -n 1; }

# Everything owed, the session open. False when Omarchy refused the restart
# (the session locked again meanwhile): the flag stays.
run_owed() {
  local r before
  if [[ -x $PLUGINS ]]; then "$PLUGINS"; fi
  if [[ -x $COLORS && -d $HOME/.config/omarchy/plugins ]]; then
    r=$("$COLORS" "$HOME/.config/omarchy/plugins" 2>&1)
    case $r in patched*|restored*) echo "Omarchy shell colours: $r"; : > "$FLAG" ;; esac
  fi
  [[ -e $FLAG ]] || return 0
  before=$(shell_pid)
  if ! omarchy-restart-shell >/dev/null 2>&1 && [[ $(shell_pid) == "$before" ]]; then
    return 1
  fi
  rm -f "$FLAG"
  # An enable that came before the shell's rescan had read the new folder
  # (it reads in the background): the new shell has it.
  if [[ -s $ST/pending-plugins && -x $PLUGINS ]]; then "$PLUGINS"; fi
  return 0
}

case ${1:-} in
  --retire)
    end=$((SECONDS + 90)) n=0
    while (( SECONDS < end && n < 90 )); do
      systemctl --user is-active --quiet "$UNIT" 2>/dev/null || exit 0
      [[ $(lock_state) == locked ]] && break
      n=$((n + 1))
      sleep 1
    done
    systemctl --user stop "$UNIT" 2>/dev/null
    exit 0 ;;
  --after-unlock)
    down=0 tries=0
    while owed; do
      case $(lock_state) in
        open)
          down=0
          sleep 2
          if [[ $(lock_state) == open ]]; then
            run_owed && exit 0
            tries=$((tries + 1))
            (( tries < 3 )) || exit 0
          fi ;;
        down) down=$((down + 1)); (( down < 2 )) || exit 0 ;;   # twice: not a restart in between
        *) down=0 ;;
      esac
      sleep 5
    done
    exit 0 ;;
esac

owed || exit 0
case $(lock_state) in
  down) rm -f "$FLAG"; exit 0 ;;   # the next shell loads what is in place, the next login the rest
  open) run_owed && exit 0 ;;
esac
if systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
  # It reads the files when the session opens: this apply's are there.
  echo "the Omarchy shell gets the new bar widgets right after the next unlock (already waiting)"
  exit 0
fi
systemd-run --user --quiet --collect --unit="${UNIT%.service}" bash "$self" --after-unlock 2>/dev/null || true
echo "the Omarchy shell gets the new bar widgets right after the next unlock"
