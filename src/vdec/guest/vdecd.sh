#!/bin/bash
# omacvm-vdecd, Chromium's decoder service. Root, in the VM:
#   vdecd.sh build OUT  the daemon, built against the VM's FFmpeg, libva and
#                       Mesa (build log: LOG)
#   vdecd.sh hook       after a pacman update of a library (95-omacvm-vdecd.hook):
#                       built again when a library it links to is gone (a new
#                       FFmpeg: libavcodec.so.N), started again when it is down
#                       or waits for the GPU (a fixed Mesa: the GPU may work
#                       now). A daemon that is ready is left alone: it may have
#                       a video open.
#   vdecd.sh why        one line: why it is not running
#   vdecd.sh vafail     vainfo's output on stdin: the line that says why
#                       VA-API did not start, nothing when it started
# Tests: src/tests/vdecd-down.sh (OMACVM_VDECD_BIN, OMACVM_VDECD_UNIT,
# OMACVM_VDECD_LOG and OMACVM_VDECD_STATUS point elsewhere there).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
BIN=${OMACVM_VDECD_BIN:-/usr/local/bin/omacvm-vdecd}
UNIT=${OMACVM_VDECD_UNIT:-/etc/systemd/system/omacvm-vdecd.service}
LOG=${OMACVM_VDECD_LOG:-/var/lib/omacvm/vdec-build.log}
# Written once the daemon is ready (the unit's runtime folder).
STATUS=${OMACVM_VDECD_STATUS:-/run/omacvm-vdec/status}

build() {   # OUT
  local pkgs="libva libva-drm egl glesv2 gbm libdrm libavcodec libavutil libsystemd"
  # shellcheck disable=SC2046,SC2086
  cc -O2 -Wall -Imodule -o "$1" omacvm-vdecd.c $(pkg-config --cflags --libs $pkgs) >> "$LOG" 2>&1
}

# The first library the daemon needs that is gone. "own": only the ones it
# links to itself (a new FFmpeg soname: building again fixes that); else
# also the ones under them (a partial update: building again does not help).
missing() {   # [own]
  local gone own l
  gone=$(ldd "$BIN" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p')
  # (No readelf without binutils: then any.)
  if [[ ${1:-} != own ]] || ! command -v readelf >/dev/null; then head -1 <<<"$gone"; return; fi
  own=$(readelf -d "$BIN" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p')
  for l in $gone; do
    if grep -qFx -- "$l" <<<"$own"; then echo "$l"; return; fi
  done
}

case ${1:-} in
build)
  build "${2:?usage: vdecd.sh build OUT}" ;;
hook)
  [[ -f $UNIT && -e $BIN ]] || exit 0
  m=$(missing own)
  if [[ -n $m ]]; then
    T=$(mktemp -d) || exit 0
    if build "$T/omacvm-vdecd"; then
      install -m755 "$T/omacvm-vdecd" "$BIN"
      echo "omacvm-vdecd: built again ($m is gone)"
    else
      echo "omacvm-vdecd: does not build against the new libraries (log: $LOG): omacvm apply"
    fi
    rm -rf "$T"
  fi
  # Ready = running with its status written. (No systemd in a chroot.)
  if ! systemctl is-active -q omacvm-vdecd 2>/dev/null || [[ ! -s $STATUS ]]; then
    systemctl restart --no-block omacvm-vdecd.service 2>/dev/null
  fi
  exit 0 ;;
why)
  m=$(missing own)
  if [[ -n $m ]]; then echo "built against a library that is gone ($m missing): omacvm apply"; exit 0; fi
  m=$(missing)
  if [[ -n $m ]]; then echo "a library under FFmpeg or Mesa is gone ($m missing; a partial update?): pacman -Syu"; exit 0; fi
  show() { systemctl show -p "$1" --value omacvm-vdecd 2>/dev/null; }
  sub=$(show SubState); res=$(show Result); inv=$(show InvocationID)
  # Its own last word in its last run ("ready" is not a reason).
  last=""
  [[ -n $inv ]] && last=$(journalctl -b "_SYSTEMD_INVOCATION_ID=$inv" -o cat --no-pager -n 50 2>/dev/null |
    sed -n 's/^vdecd: //p' | grep -v '^ready' | tail -1)
  case $res in
    watchdog) why="it stopped answering (killed by the watchdog)" ;;
    signal|core-dump) why="it crashed (journalctl -u omacvm-vdecd)" ;;
    oom-kill) why="it ran out of memory (killed)" ;;
    start-limit-hit) why="it failed too often: systemctl restart omacvm-vdecd" ;;
    exit-code) why=${last:-"it exited with status $(show ExecMainStatus) (journalctl -u omacvm-vdecd)"} ;;
    *) why=${last:-"not running (journalctl -u omacvm-vdecd)"} ;;
  esac
  [[ $sub == auto-restart && $why != *"trying again"* ]] && why="$why; starts again by itself"
  echo "$why" ;;
vafail)
  va=$(cat)
  grep -q 'vaInitialize failed' <<<"$va" || exit 0
  # The cause: a library, Mesa's loader, else libva's own line.
  grep -m1 -E 'cannot open shared object|MESA-LOADER' <<<"$va" ||
    grep -m1 -E 'libva error|vaInitialize failed' <<<"$va"
  exit 0 ;;
*)
  echo "usage: vdecd.sh build OUT | hook | why | vafail" >&2; exit 2 ;;
esac
