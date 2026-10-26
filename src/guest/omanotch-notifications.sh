#!/bin/bash
# Omanotch parks Omarchy's bar on the built-in display while the bar shows in
# the notch strip, but Omarchy's notifications still keep a bar's height of
# room above them there: a gap under the strip. On that display they now keep
# only the normal gap; other displays keep their bar's room. This patches
# Omarchy's notification service itself (a cloned plugin runs sandboxed and
# can't show popups); a pacman hook does it again after Omarchy updates.
# Omarchy from about October 2026 asks the bar for its room on each display
# (barClearanceFor -> the bar's barSizeFor), which Omanotch's bar patch
# answers for the parked display: then there is nothing to patch here.
# Omarchy 4.5 asks it through Delivery.barThickness (bar.barSizeFor).
# Run as root:  omanotch-notifications.sh on|off [FILE]   (prints "changed" if it did)
set -euo pipefail
F=${2:-/usr/share/omarchy/shell/plugins/notifications/Service.qml}
[[ -f $F ]] || exit 0
python3 - "$F" "${1:?on or off}" <<'PY'
import sys
path, mode = sys.argv[1], sys.argv[2]
s = open(path).read()
old = "NotificationLogic.popupPlacement(\n        service.barPosition, service.barClearance, Style.gapsOut)"
new = ("NotificationLogic.popupPlacement(\n        service.barPosition,\n"
       "        // omacvm-omanotch: the bar is parked in the notch strip on this display\n"
       "        service.shell && service.shell.bar && service.shell.bar.notchParked\n"
       "          && String(modelData && modelData.name) === String(service.shell.bar.notchParkedScreen)\n"
       "          ? Style.gapsOut : service.barClearance,\n"
       "        Style.gapsOut)")
if mode == "on":
    if new in s: sys.exit(0)
    asks = "service.barClearanceFor(" in s or "Delivery.barThickness(" in s
    if s.count(old) != 1 and asks: sys.exit(0)  # the bar answers (see above)
    if s.count(old) != 1: sys.exit("omanotch-notifications: Omarchy's notification service changed, not patched")
    s = s.replace(old, new)
elif mode == "off":
    if new not in s: sys.exit(0)
    s = s.replace(new, old)
else:
    sys.exit("omanotch-notifications.sh on|off [FILE]")
tmp = path + ".omacvm"
open(tmp, "w").write(s)
import os; os.chmod(tmp, 0o644); os.replace(tmp, path)
print("changed")
PY
