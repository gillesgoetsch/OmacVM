#!/bin/bash
# Chromium's video decoding on the Mac's media engine (OmacVM.app). Run as root
# inside the VM: ./install.sh <desktop-user> on|off
#   on:  the omacvm-vdec kernel module (a V4L2 video decoder) through DKMS,
#        rebuilt by pacman's DKMS hook for every new kernel with its headers;
#        omacvm-vdecd, which decodes for it with VA-API (the app's VideoToolbox
#        backend); Chromium's switch for its V4L2 decoder in the user's flags,
#        and an extension that has YouTube send VP9 instead of AV1 (this
#        Chromium decodes AV1 only on the CPU)
#        A pacman hook builds the daemon again when FFmpeg's soname changes
#        and starts it when it was down (vdecd.sh).
#   off: all of it goes again (dkms and the kernel headers stay installed)
# Arch Linux ARM's Chromium has no VA-API, only V4L2: see docs/adr/0025.
# Google Chrome and Brave use VA-API directly and need none of this.
#   An update while an app has the decoder open: the new module loads at the
#   next VM start (omacvm check says so); the running daemon is restarted
#   only when it or the module changed.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> on|off}; ON=${2:?on|off}
NAME=omacvm-vdec
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' module/dkms.conf)
SRC=/usr/src/$NAME-$VER
STAMP=/var/lib/omacvm/vdec-module
LOG=/var/lib/omacvm/vdec-build.log
LIB=/usr/local/lib/omacvm
BIN=/usr/local/bin/omacvm-vdecd
say() { echo "  Chromium video: $*"; }
as_user() { runuser -u "$U" -- env -i PATH=/usr/bin:/bin "$@"; }
source ../../guest/dkms.sh

if [[ $ON == off ]]; then
  [[ -f /etc/systemd/system/omacvm-vdecd.service || -d $SRC ]] || exit 0
  [[ -x $LIB/chromium-flags.py ]] && as_user "$LIB/chromium-flags.py" off || true
  systemctl disable --now omacvm-vdecd.service >/dev/null 2>&1 || true
  modprobe -r omacvm_vdec 2>/dev/null || true
  dkms_remove $NAME
  rm -rf /usr/local/share/omacvm/chromium-no-av1
  rm -f /etc/systemd/system/omacvm-vdecd.service "$BIN" "$LIB/chromium-flags.py" \
    /etc/udev/rules.d/70-omacvm-vdec.rules /etc/modules-load.d/omacvm-vdec.conf \
    /etc/sysusers.d/omacvm-vdec.conf /etc/pacman.d/hooks/95-omacvm-vdecd.hook "$STAMP"
  systemctl daemon-reload
  if [[ -e /sys/module/omacvm_vdec ]]; then say "off (the module goes at the next VM start: an app has it open)"
  else say "off"; fi
  exit 0
fi
[[ $ON == on ]] || { echo "usage: install.sh <desktop-user> on|off" >&2; exit 2; }
command -v chromium >/dev/null || { say "no Chromium, nothing to do"; exit 0; }

dkms_tools ffmpeg libva mesa || exit 1
kernel_headers linux-aarch64
dkms_source $NAME "$VER" "$STAMP" module/*
dkms_build $NAME "$VER" "$LOG"

# The daemon, built here against the VM's FFmpeg, libva and Mesa.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if ! ./vdecd.sh build "$T/omacvm-vdecd"; then
  say "the daemon did not build (log: $LOG)"
  exit 1
fi
daemon_new=0; cmp -s "$T/omacvm-vdecd" "$BIN" || daemon_new=1
unit_new=0; cmp -s omacvm-vdecd.service /etc/systemd/system/omacvm-vdecd.service || unit_new=1
install -m755 "$T/omacvm-vdecd" "$BIN"   # a new file: a running daemon keeps its own
install -Dm755 chromium-flags.py "$LIB/chromium-flags.py"
install -Dm644 -t /usr/local/share/omacvm/chromium-no-av1 no-av1/manifest.json no-av1/no-av1.js
install -Dm644 omacvm-vdec.sysusers /etc/sysusers.d/omacvm-vdec.conf
systemd-sysusers /etc/sysusers.d/omacvm-vdec.conf
install -m644 70-omacvm-vdec.rules /etc/udev/rules.d/
install -m644 omacvm-vdecd.service /etc/systemd/system/
install -Dm644 95-omacvm-vdecd.hook /etc/pacman.d/hooks/95-omacvm-vdecd.hook
echo omacvm_vdec | install -Dm644 /dev/stdin /etc/modules-load.d/omacvm-vdec.conf
udevadm control --reload 2>/dev/null || true
systemctl daemon-reload
systemctl enable omacvm-vdecd.service >/dev/null 2>&1

as_user "$LIB/chromium-flags.py" on || say "Chromium's flags file not changed (see above)"

# The module for the running kernel: loaded, or swapped when it changed.
# The daemon holds one reference; more = an app has a video open, and
# pulling the module from under it is not possible: the next VM start
# loads the new one (the old daemon keeps serving the old one until then).
built=$(modinfo -k "$(uname -r)" -F srcversion omacvm_vdec 2>/dev/null || true)
if [[ -z $built ]]; then
  say "on after a reboot (no module for the running kernel $(uname -r) yet)"
  exit 0
fi
restart=$(( daemon_new || unit_new ))
if [[ -e /sys/module/omacvm_vdec && $(cat /sys/module/omacvm_vdec/srcversion 2>/dev/null) != "$built" ]]; then
  refs=$(cat /sys/module/omacvm_vdec/refcnt)
  systemctl is-active -q omacvm-vdecd && refs=$((refs - 1))
  if (( refs > 0 )); then
    systemctl is-active -q omacvm-vdecd || systemctl start omacvm-vdecd.service || true
    say "on; the new decoder takes over at the next VM start (an app has a video open)"
    exit 0
  fi
  systemctl stop omacvm-vdecd.service
  if ! modprobe -r omacvm_vdec 2>/dev/null; then   # opened just now
    systemctl start omacvm-vdecd.service || true
    say "on; the new decoder takes over at the next VM start (an app has a video open)"
    exit 0
  fi
  restart=1
fi
if [[ ! -e /sys/module/omacvm_vdec ]]; then
  modprobe omacvm_vdec 2>/dev/null || { say "on after a reboot (the module did not load: dmesg)"; exit 0; }
  udevadm trigger --subsystem-match=misc --sysname-match=omacvm-vdec 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  restart=1
fi
if (( restart )) || ! systemctl is-active -q omacvm-vdecd; then
  systemctl restart omacvm-vdecd.service || true
  say "on (restart Chromium once)"
else
  say "on"
fi
