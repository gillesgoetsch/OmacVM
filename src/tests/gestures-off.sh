#!/bin/bash
# gestures=off turns the VM's Gestures daemon off on every route, so the VM
# never connects to the Mac's Gestures (it used to stay on UTM, VMware Fusion
# and OmacVM.app for Cmd as Super). No VM needed: the gestures lines of
# src/guest/install.sh and src/cmd/apply.sh run with systemctl and the
# installers replaced.
#   src/tests/gestures-off.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The guest side: from the comment above the gestures block to its closing fi.
block=$(awk '/^# Gestures off means the daemon is off/ {on = 1} on {print} on && /^fi$/ {exit}' "$R/src/guest/install.sh")
[[ $block == *'gestures/guest/install.sh'* && $block == *'${F[gestures]}'* ]] ||
  { echo "FAIL gestures block not found in src/guest/install.sh"; exit 1; }
# macOS's bash 3.2 has no associative arrays: the feature as a plain variable.
block=${block//'${F[gestures]}'/'$FG'}

guest() {   # TYPE GESTURES SERVICE(enabled|active|none) -> what the block did
  ( TYPE=$1 FG=$2 U=me R=/repo SERVICE=$3 CALLS=""
    log() { :; }
    systemctl() {
      case "$1 $2" in
        "is-enabled -q") [[ $SERVICE == enabled ]] ;;
        "is-active -q") [[ $SERVICE == enabled || $SERVICE == active ]] ;;
        *) CALLS+="systemctl $* " ;;
      esac
    }
    /repo/gestures/guest/install.sh() { CALLS+="install "; }
    eval "$block"
    echo "${CALLS% }" )
}
for t in parallels utm fusion app; do
  expect "$t, gestures on: daemon installed" install "$(guest $t on none)"
  expect "$t, gestures off: enabled daemon disabled and stopped" "systemctl disable --now omacvm-gestures" "$(guest $t off enabled)"
  expect "$t, gestures off: running daemon (not enabled) stopped" "systemctl disable --now omacvm-gestures" "$(guest $t off active)"
  expect "$t, gestures off, no daemon: nothing" "" "$(guest $t off none)"
done

# The Mac side of omacvm apply: Gestures and the token only for gestures on.
mac=$(grep -E 'skip-gestures\)|bridge_token_ensure; fi' "$R/src/cmd/apply.sh")
[[ $(wc -l <<<"$mac") == *2 ]] || { echo "FAIL apply.sh gestures lines not found"; exit 1; }
apply() {   # TYPE GESTURES -> the installer's gestures argument and whether the token goes in
  ( TYPE=$1 G=$2 TOKEN=1 args=() tok=no
    on() { [[ $1 == gestures && $G == on ]]; }
    bridge_token_ensure() { tok=yes; }
    eval "$mac"
    echo "${args[*]:-none} token=$tok" )
}
for t in utm fusion app; do
  expect "$t, gestures off: Mac side skips Gestures" "--skip-gestures token=no" "$(apply $t off)"
  expect "$t, gestures on: Mac side installs Gestures" "none token=yes" "$(apply $t on)"
done

exit $fail
