#!/bin/bash
# The Mac's battery in Omarchy's bar (OmacVM.app passes it on its own port).
# Run as root inside the VM: ./install.sh on|off
#   on:  the omacvm-battery kernel module through DKMS (rebuilt by pacman's
#        DKMS hook for every new kernel that comes with its headers),
#        loaded at boot; the agent omacvm-battery.service that feeds it the
#        Mac's snapshots; UPower never suspends the VM for a low battery
#   off: all of it goes again (dkms and the kernel headers stay installed)
# Idempotent. The module, agent and DKMS steps come from try-omarchy (MIT).
set -euo pipefail
cd "$(dirname "$0")"
NAME=omacvm-battery
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' module/dkms.conf)
SRC=/usr/src/$NAME-$VER
STAMP=/var/lib/omacvm/battery-module
LOG=/var/lib/omacvm/battery-build.log
UPOWER=/etc/UPower/UPower.conf.d/90-omacvm-battery.conf
say() { echo "  battery: $*"; }
source ../../guest/dkms.sh

if [[ ${1:-} == off ]]; then
  [[ -f /etc/systemd/system/$NAME.service || -d $SRC ]] || exit 0
  systemctl disable --now $NAME.service >/dev/null 2>&1 || true
  modprobe -r omacvm_battery 2>/dev/null || true
  dkms_remove $NAME
  rm -f /etc/systemd/system/$NAME.service /usr/local/bin/$NAME /etc/udev/rules.d/70-omacvm-battery.rules \
    /etc/modules-load.d/omacvm-battery.conf "$UPOWER" "$STAMP"
  systemctl daemon-reload
  systemctl try-restart upower >/dev/null 2>&1 || true
  say "off"
  exit 0
fi
[[ ${1:-} == on ]] || { echo "usage: install.sh on|off" >&2; exit 2; }

# DKMS and the headers of every installed kernel (guest/dkms.sh).
dkms_tools || exit 1
kernel_headers linux-aarch64
# The module's source for DKMS: again when it changed. Built for every
# kernel that has its headers (the running one and any newer).
dkms_source $NAME "$VER" "$STAMP" module/*
dkms_build $NAME "$VER" "$LOG"

install -m755 omacvm-battery /usr/local/bin/
install -m644 omacvm-battery.service /etc/systemd/system/
install -m644 70-omacvm-battery.rules /etc/udev/rules.d/
echo omacvm_battery | install -Dm644 /dev/stdin /etc/modules-load.d/omacvm-battery.conf
if ! cmp -s 90-omacvm-battery.conf "$UPOWER"; then
  install -Dm644 90-omacvm-battery.conf "$UPOWER"
  systemctl try-restart upower >/dev/null 2>&1 || true
fi
udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
systemctl daemon-reload

# Loaded now when this kernel has it (a changed one replaces the old).
systemctl stop $NAME.service 2>/dev/null || true
(( CHANGED )) && modprobe -r omacvm_battery 2>/dev/null || true
if modprobe omacvm_battery 2>/dev/null; then
  systemctl enable $NAME.service >/dev/null 2>&1
  systemctl restart $NAME.service
  say "on"
else
  systemctl enable $NAME.service >/dev/null 2>&1
  say "on after a reboot (no module for the running kernel $(uname -r) yet)"
fi
