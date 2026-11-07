#!/bin/bash
# Omarchy's notifications keep the bar's size and a gap of room above them.
# Omanotch's bar is not that size on the built-in display: parked while the
# bar shows in the notch strip (no room: they keep only the normal gap), and
# with OmacVM.app's FullPanel as tall as the strip (they keep its height and
# the gap, not the bar's size, which put them into the bar). Omanotch's bar
# patch answers the room per display (barSizeFor); this makes Omarchy's
# notification service ask it. It patches the service itself (a cloned
# plugin runs sandboxed and can't show popups); a pacman hook does it again
# after Omarchy updates. Omarchy from about October 2026 asks the bar itself
# (barClearanceFor -> barSizeFor): then there is nothing to patch here.
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
# 3.0.x-3.2.4: only the parked bar (FullPanel's toasts went into its bar).
v1 = ("NotificationLogic.popupPlacement(\n        service.barPosition,\n"
      "        // omacvm-omanotch: the bar is parked in the notch strip on this display\n"
      "        service.shell && service.shell.bar && service.shell.bar.notchParked\n"
      "          && String(modelData && modelData.name) === String(service.shell.bar.notchParkedScreen)\n"
      "          ? Style.gapsOut : service.barClearance,\n"
      "        Style.gapsOut)")
new = ("NotificationLogic.popupPlacement(\n        service.barPosition,\n"
       "        // omacvm-omanotch: the bar's room on this display (parked in the notch strip: none;\n"
       "        // OmacVM.app's FullPanel: the strip's height), from Omanotch's bar\n"
       "        service.shell && service.shell.bar && service.shell.bar.notchParked\n"
       "          && String(modelData && modelData.name) === String(service.shell.bar.notchParkedScreen)\n"
       "          ? Style.gapsOut\n"
       "          : service.shell && service.shell.bar && !service.shell.bar.barHidden\n"
       "            && typeof service.shell.bar.barSizeFor === \"function\"\n"
       "          ? Math.max(0, Number(service.shell.bar.barSizeFor(String(modelData && modelData.name)))) + Style.gapsOut\n"
       "          : service.barClearance,\n"
       "        Style.gapsOut)")
if mode == "on":
    if new in s: sys.exit(0)
    if s.count(v1) == 1: s = s.replace(v1, new)
    elif s.count(old) != 1 and ("service.barClearanceFor(" in s or "Delivery.barThickness(" in s):
        sys.exit(0)  # the bar answers (see above)
    elif s.count(old) != 1: sys.exit("omanotch-notifications: Omarchy's notification service changed, not patched")
    else: s = s.replace(old, new)
elif mode == "off":
    if new in s: s = s.replace(new, old)
    elif v1 in s: s = s.replace(v1, old)
    else: sys.exit(0)
else:
    sys.exit("omanotch-notifications.sh on|off [FILE]")
tmp = path + ".omacvm"
open(tmp, "w").write(s)
import os; os.chmod(tmp, 0o644); os.replace(tmp, path)
print("changed")
PY
