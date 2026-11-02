#!/bin/bash
# Drag and drop of files from the Mac (feature drag-drop, OmacVM.app only,
# experimental; docs/drag-and-drop.md), as root in the VM:
#   install.sh USER on        build the drop helper (omacvm-drop-at, C, against
#                             the VM's own Wayland) when it is missing or older,
#                             install the service, the share's mount and the
#                             port's rule; the port and the share come with
#                             the VM's next start in OmacVM.app
#   install.sh USER off       remove all of that again (silent when nothing is there)
#   install.sh USER --status  one line: STATE DETAIL, STATE one of ok | off | needed
# Tests: src/drop/tests/run.sh (OMACVM_DROP_ROOT puts every path under a
# scratch folder; systemctl and udevadm are stand-ins there).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh USER on|off|--status}; ACTION=${2:?usage: install.sh USER on|off|--status}
ROOT=${OMACVM_DROP_ROOT:-}
BIN=$ROOT/usr/local/bin
LIB=$ROOT/usr/local/lib/omacvm
HELPER=$LIB/omacvm-drop-at
INFO=$LIB/omacvm-drop-at.build
RULE=$ROOT/etc/udev/rules.d/70-omacvm-drop.rules
UNIT=$ROOT/etc/systemd/user/omacvm-drop.service
SHARE_UNIT=$ROOT/etc/systemd/system/omacvm-drop-share.service
SOURCES=(omacvm-drop-at.c proto/wlr-layer-shell-unstable-v1.xml proto/wlr-virtual-pointer-unstable-v1.xml)

source_digest() { cat "${SOURCES[@]}" | sha256sum | cut -c1-16; }
wayland_version() { pkg-config --modversion wayland-client 2>/dev/null || echo unknown; }

status() {
  if [[ ! -f $UNIT && ! -x $HELPER ]]; then echo "off drag and drop is not set up"
  elif [[ ! -x $HELPER ]]; then echo "needed the drop helper is not built: omacvm apply"
  elif [[ $(sed -n 's/^source //p' "$INFO" 2>/dev/null) != "$(source_digest)" ]]; then echo "needed the drop helper is older than this OmacVM: omacvm apply"
  elif [[ ! -f $UNIT || ! -f $SHARE_UNIT || ! -f $RULE || ! -x $BIN/omacvm-drop ]]; then echo "needed the drop service is not installed: omacvm apply"
  else echo "ok helper, service and share mount"; fi
}

build() {
  local t; t=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$t'" RETURN
  command -v wayland-scanner >/dev/null && command -v cc >/dev/null || {
    echo "drag and drop: the VM lacks a C compiler or wayland-scanner (pacman -S gcc wayland)" >&2; return 1; }
  local p
  for p in wlr-layer-shell-unstable-v1 wlr-virtual-pointer-unstable-v1; do
    wayland-scanner client-header "proto/$p.xml" "$t/$p-client-protocol.h"
    wayland-scanner private-code "proto/$p.xml" "$t/$p-protocol.c"
  done
  cc -O2 -Wall -Wextra -I"$t" -o "$t/omacvm-drop-at" omacvm-drop-at.c "$t"/*-protocol.c \
     $(pkg-config --cflags --libs wayland-client) || { echo "drag and drop: the drop helper did not build" >&2; return 1; }
  install -Dm755 "$t/omacvm-drop-at" "$HELPER"
  printf 'source %s\nwayland %s\n' "$(source_digest)" "$(wayland_version)" | install -Dm644 /dev/stdin "$INFO"
}

case $ACTION in
  --status) status; exit 0 ;;
  on|off) ;;
  *) echo "usage: install.sh USER on|off|--status" >&2; exit 2 ;;
esac
(( EUID == 0 )) || [[ -n $ROOT ]] || { echo "drag and drop: run as root" >&2; exit 1; }

if [[ $ACTION == off ]]; then
  systemctl --user -M "$U@" stop omacvm-drop.service >/dev/null 2>&1 || true
  systemctl --global disable omacvm-drop.service >/dev/null 2>&1 || true
  if [[ -f $SHARE_UNIT ]]; then
    systemctl disable --now omacvm-drop-share.service >/dev/null 2>&1 || true
  fi
  "$BIN/omacvm-drop-share" --stop >/dev/null 2>&1 || true
  rm -f "$UNIT" "$SHARE_UNIT" "$BIN/omacvm-drop" "$BIN/omacvm-drop-share" "$HELPER" "$INFO"
  if [[ -f $RULE ]]; then rm -f "$RULE"; udevadm control --reload >/dev/null 2>&1 || true; fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  exit 0
fi

if [[ ! -x $HELPER || $(sed -n 's/^source //p' "$INFO" 2>/dev/null) != "$(source_digest)" ]]; then
  echo "drag and drop: building the drop helper"
  build
fi
install -Dm755 omacvm-drop "$BIN/omacvm-drop"
install -Dm755 omacvm-drop-share "$BIN/omacvm-drop-share"
install -Dm644 omacvm-drop.service "$UNIT"
install -Dm644 omacvm-drop-share.service "$SHARE_UNIT"
if ! cmp -s 70-omacvm-drop.rules "$RULE" 2>/dev/null; then
  install -Dm644 70-omacvm-drop.rules "$RULE"
  udevadm control --reload >/dev/null 2>&1 || true
  udevadm trigger --subsystem-match=virtio-ports >/dev/null 2>&1 || true
fi
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable omacvm-drop-share.service >/dev/null 2>&1 || true
# Mounted now when this start already has the share (switched on while stopped).
systemctl start omacvm-drop-share.service >/dev/null 2>&1 || true
systemctl --global enable omacvm-drop.service >/dev/null 2>&1 || true
systemctl --user -M "$U@" daemon-reload >/dev/null 2>&1 && systemctl --user -M "$U@" restart omacvm-drop.service >/dev/null 2>&1 || true
