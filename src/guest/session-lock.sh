#!/bin/bash
# session-lock.sh: is the desktop session locked? Run as the desktop user, it
# prints one word; sourced, lock_state prints it:
#   down    no Omarchy shell (quickshell) of this user runs
#   busy    one runs but does not answer (starting, reloading, restarting)
#   locked  Omarchy's lock status says requested, sessionLocked or secure
#   open    it answers and is not locked
# Callers take busy as locked.
#
# While the session is locked nothing of OmacVM's writes under
# ~/.config/omarchy/plugins or asks the shell to rescan its plugins: the shell
# of omarchy-mac 4.0.3 then reloads every plugin, its own lock screen too, and
# the new lock screen has no password field until the shell restarts
# (Omarchy fixed it in omacom/omarchy#9485, omarchy-mac does not have it yet).
# Nor is the shell restarted then: Hyprland would show its "lockscreen app
# died" screen.
#
# Locked is Omarchy's lock status, read at the call. Not `omarchy-shell lock
# isLocked`: with Quickshell 0.3.2 and older it answers true after the first
# unlock until the shell restarts (omarchy-mac#738; Quickshell 18c95fae,
# Omarchy's own fix omacom/omarchy#14978). Omarchy's commands get
# LC_ALL=C.UTF-8: without a locale (root's sudo -u in an apply) qs prints Qt's
# locale warning before every answer.

# The last line of an answer (in case the warning comes anyway).
session_ask() { LC_ALL=C.UTF-8 omarchy-shell "$@" 2>/dev/null | tail -n 1; }

lock_state() {
  local s
  if ! LC_ALL=C.UTF-8 omarchy-shell shell ping >/dev/null 2>&1; then
    if pgrep -u "$(id -u)" -x quickshell >/dev/null 2>&1; then echo busy; else echo down; fi
    return 0
  fi
  s=$(session_ask lock status)
  if [[ $s == "{"* ]]; then
    if [[ $s == *'"requested":true'* || $s == *'"sessionLocked":true'* || $s == *'"secure":true'* ]]; then
      echo locked
    else
      echo open
    fi
  elif [[ $(session_ask lock isLocked) == true ]]; then
    echo locked   # an Omarchy without the status call
  else
    echo open
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ -n ${OMARCHY_PATH:-} ]] || source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null
  lock_state
fi
