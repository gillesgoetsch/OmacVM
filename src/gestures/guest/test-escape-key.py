#!/usr/bin/env python3
"""Offline test of a key of Omarchy's out to macOS in the guest daemon
(src/gestures/mac/test.sh): the daemon's own EscapeKey with evdev stubbed,
against a made-up Hyprland event socket. No VM, no uinput.
  Hyprland's custom event omacvm-escape -> "L" to the Mac, once per event,
  also when the event comes in pieces; other events and other custom events
  -> nothing; not connected to the Mac yet -> nothing; Hyprland's folder
  gone while the daemon looks for it, or its event socket gone and back ->
  connected again, "L" again.
"""
import importlib.machinery
import importlib.util
import os
import socket
import sys
import tempfile
import threading
import time
import types


class _Codes:
    def __getattr__(self, name):
        return 0


evdev = types.ModuleType("evdev")
evdev.AbsInfo = object
evdev.UInput = object
evdev.ecodes = _Codes()
sys.modules["evdev"] = evdev
DAEMON = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "omacvm-gestures")
loader = importlib.machinery.SourceFileLoader("omacvm_gestures_daemon", DAEMON)
spec = importlib.util.spec_from_loader(loader.name, loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)

fails = 0


def check(ok, what):
    global fails
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    fails += 0 if ok else 1


# ---- the made-up Hyprland: only its event socket ----
tmp = tempfile.mkdtemp()
looks = []


def hypr_socket():
    """The first look finds Hyprland's folder gone between its look and its stat (a logout)."""
    looks.append(1)
    if len(looks) == 1:
        raise FileNotFoundError("/run/user/1000/hypr/gone")
    return os.path.join(tmp, ".socket.sock")


g.hypr_socket = hypr_socket
evsrv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
evsrv.bind(os.path.join(tmp, ".socket2.sock"))
evsrv.listen(4)
evconns = []


def evserve():
    while True:
        c, _ = evsrv.accept()
        evconns.append(c)


threading.Thread(target=evserve, daemon=True).start()


def connected(n=1, wait=3.0):
    end = time.monotonic() + wait
    while time.monotonic() < end and len(evconns) < n:
        time.sleep(0.01)
    return len(evconns) >= n


def event(data):
    for c in list(evconns):
        c.sendall(data)


def got(n, wait=1.0):
    """The lines the Mac got, once there are n (or after wait s)."""
    end = time.monotonic() + wait
    while time.monotonic() < end and len(sent) < n:
        time.sleep(0.01)
    time.sleep(0.1)
    return list(sent)


sent = []
threading.Thread(target=g.ESCAPE.watch, daemon=True).start()
check(connected(), "Hyprland's folder gone at the first look: the daemon looks again and listens to its event socket")

event(b"custom>>omacvm-escape\n")
check(got(1, wait=0.3) == [], "not connected to the Mac yet: nothing sent")

g.ESCAPE.send = lambda b: sent.append(b.decode())
event(b"custom>>omacvm-escape\n")
check(got(1) == ["L\n"], "custom>>omacvm-escape: L to the Mac")

sent.clear()
event(b"workspace>>2\nworkspacev2>>2,2\ncustom>>something-else\ncustom>>omacvm-escape-not\nactivewindow>>foot,omacvm-escape\n")
check(got(1, wait=0.3) == [], "other events, other custom events: nothing")

sent.clear()
event(b"workspace>>3\ncustom>>omacvm-")
time.sleep(0.05)
event(b"escape\ncustom>>omacvm-escape\n")
check(got(2) == ["L\n", "L\n"], "two events, the first in two pieces: L twice")


def gone(b):
    raise OSError("the connection is going")


sent.clear()
g.ESCAPE.send = gone
event(b"custom>>omacvm-escape\n")
time.sleep(0.2)
g.ESCAPE.send = lambda b: sent.append(b.decode())
event(b"custom>>omacvm-escape\n")
check(got(1) == ["L\n"], "a connection to the Mac that is going: skipped, the next event goes out")

sent.clear()
for c in list(evconns):
    c.close()
evconns.clear()
check(connected(wait=4), "Hyprland's event socket gone and back: connected again")
event(b"custom>>omacvm-escape\n")
check(got(1) == ["L\n"], "... and L again")

sys.exit(1 if fails else 0)
