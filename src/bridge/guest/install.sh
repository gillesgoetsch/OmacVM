#!/bin/bash
# Install the guest side of omacvm-bridge. Run as root inside the VM, from this
# directory (the top-level guest/install.sh calls it):
#   ./install.sh <desktop-user>
# Idempotent. Installs:
#   /usr/local/bin/omacvm-bridge, /usr/local/bin/omacvm-bridge-osd, /usr/local/bin/omacvm-bridge-events
#   /usr/local/bin/omarchy-toggle-nightlight (Super+Ctrl+N drives the Mac's Night Shift)
#   /usr/local/bin/omarchy-network-{qr,password} (Omarchy's Wi-Fi QR card shares the Mac's network)
#   user service omacvm-bridge-osd (Omarchy OSD for the Mac's media keys)
#   user socket omacvm-bridge-events (one event stream from the Mac per
#   session, shared by the widgets and the OSD)
#   the VM's own volume pinned at 100 %
#   the bar widgets in ../plugins (omacvm.bluetooth, omacvm.wifi, omacvm.audio,
#   omacvm.nightshift)
#   Omarchy's own night light out of the way (indicator hidden, hyprsunset
#   stopped): the Mac's Night Shift tints the whole screen, never both
#   system service omacvm-timezone (the VM's time zone follows the Mac's)
# The token (~/.config/omacvm-bridge/token) comes from the Mac, see push-guest.sh.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
as_user() { sudo -u "$U" env XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }

# python: omacvm-bridge checks the Bridge's proof with it (no key on a command line).
../../guest/pkg-add python || true
install -m755 omacvm-bridge omacvm-bridge-osd omacvm-bridge-events omarchy-toggle-nightlight \
  omarchy-network-qr omarchy-network-password /usr/local/bin/
install -m644 omacvm-bridge-osd.service omacvm-bridge-events.socket omacvm-bridge-events.service /etc/systemd/user/
systemctl --user -M "$U@" daemon-reload
systemctl --user -M "$U@" enable --now omacvm-bridge-events.socket >/dev/null 2>&1 || true
# A new copy takes over at once (its clients reconnect within 3 s).
systemctl --user -M "$U@" try-restart omacvm-bridge-events.service 2>/dev/null || true
# Widgets still streaming straight from the Mac (from before the shared
# stream) switch over: their stream ends and they reconnect through it.
pkill -u "$U" -f -- "-N http://[^ ]*:47831/events" 2>/dev/null || true
systemctl --user -M "$U@" enable omacvm-bridge-osd.service >/dev/null 2>&1
systemctl --user -M "$U@" restart omacvm-bridge-osd.service

# The time zone follows the Mac's (a zone set by hand in the VM is kept).
install -m755 omacvm-timezone /usr/local/bin/
install -m644 omacvm-timezone.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable omacvm-timezone.service >/dev/null 2>&1
systemctl restart omacvm-timezone.service || true

# Audio (PipeWire's parts come from ../../guest/install.sh): the Mac owns
# loudness (the bridge sets the Mac's volume), so the VM's own levels stay at full.
# Microphone likewise: Parallels hands the Mac's input over at the Mac's level,
# so the VM's source stays at 100 % (it starts out far lower).
amixer -q -c0 sset Master 0dB unmute 2>/dev/null || true
amixer -q -c0 sset Capture 0dB cap 2>/dev/null || true
for dev in @DEFAULT_AUDIO_SINK@ @DEFAULT_AUDIO_SOURCE@; do
  as_user wpctl set-volume "$dev" 1.0 2>/dev/null || true
  as_user wpctl set-mute "$dev" 0 2>/dev/null || true
done

# Bar widgets: the Mac's Wi-Fi and audio, in the slots of Omarchy's own, and
# the Mac's Night Shift.
for p in ../plugins/*/; do [[ -f $p/manifest.json ]] && ../../lib/install-plugin.sh "$U" "$p"; done

# Night light: the Mac's Night Shift replaces Omarchy's (hyprsunset in the VM),
# so the screen is never tinted twice. Omarchy's night light indicator leaves
# the indicators widget (it would switch hyprsunset); the marker keeps what it
# had, so turning the Bridge off puts it back (../../guest/off.sh).
pkill -x hyprsunset 2>/dev/null || true
MARK=$H/.local/state/omacvm/nightlight-indicator
home_mkdir "$(dirname "$MARK")"
# All of it in the home: run as the user. Marker files root left there go first
# (the user could not write them: up to 3.1.24 this ran as root).
for f in "$MARK" "$MARK.set"; do [[ ! -f $f ]] || home_run test -w "$f" || home_put "$f" < <(home_cat "$f"); done
home_run "$PWD/nightlight-indicator.sh" "$H/.config/omarchy/shell.json" "$MARK" >/dev/null < /dev/null ||
  echo "night light indicator: shell.json left as it is"

echo "omacvm-bridge guest side installed for $U"
