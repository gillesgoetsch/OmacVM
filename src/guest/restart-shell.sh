#!/bin/bash
# restart-shell.sh [--after-unlock]: the Omarchy shell again, so the bar
# widgets an update changed load (guest/install.sh runs it as the desktop
# user, at the end of an apply). Never while the session is locked: Omarchy's
# lock screen lives in the shell, and a restart leaves Hyprland's "lockscreen
# app died" screen behind. Locked: a user unit (omacvm-restart-shell) runs
# this again with --after-unlock, which restarts the shell right after the
# unlock. It ends without one when the shell stops answering (the session
# ended, or the shell restarted anyway: either way the next shell loads the
# new widgets).
#
# Locked = Omarchy's lock status (requested, sessionLocked or secure, read at
# the call). Not `omarchy-shell lock isLocked`: with Quickshell 0.3.2 and
# older it answers true after the first unlock until the shell restarts
# (omarchy-mac#738; Quickshell 18c95fae, Omarchy's own fix omacom/omarchy#14978).
source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null

# The last line of an answer: in a C locale qs prints Qt's locale warning first.
ask() { omarchy-shell lock "$1" 2>/dev/null | tail -n 1; }
up() { omarchy-shell shell ping >/dev/null 2>&1; }
locked() {
  local s
  s=$(ask status)
  if [[ $s == "{"* ]]; then
    [[ $s == *'"requested":true'* || $s == *'"sessionLocked":true'* || $s == *'"secure":true'* ]]
  else
    [[ $(ask isLocked) == true ]]   # an Omarchy without the status call
  fi
}

if [[ ${1:-} == --after-unlock ]]; then
  while up && locked; do sleep 5; done
  up || exit 0
  sleep 2
  exec omarchy-restart-shell
fi

up || exit 0
if ! locked; then
  omarchy-restart-shell >/dev/null 2>&1
  exit 0
fi
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
systemd-run --user --quiet --collect --unit=omacvm-restart-shell bash "$self" --after-unlock 2>/dev/null || true
echo "the Omarchy shell restarts after the next unlock (new bar widgets)"
