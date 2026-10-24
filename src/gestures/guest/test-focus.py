#!/usr/bin/env python3
"""Offline test of the escape combo's question in the guest daemon (src/gestures/mac/test.sh):
"Q" from the Mac -> "D x y w h", where Hyprland's focused output sits on the Mac
(OmacVM.app's arrangement from the display agent's displays.json), or "D -" when
that is not known: one output only, no file, a link in its place, another owner,
junk, Hyprland not answering. Evdev stubbed, a made-up Hyprland on a Unix socket,
the file in a temporary runtime folder. No VM, no uinput.
"""
import getpass
import importlib.machinery
import importlib.util
import json
import os
import shutil
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
loader = importlib.machinery.SourceFileLoader("omacvm_gestures_focus", DAEMON)
spec = importlib.util.spec_from_loader(loader.name, loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)

fails = 0


def check(ok, what):
    global fails
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    fails += 0 if ok else 1


monitors = []
tmp = tempfile.mkdtemp()
SOCK = os.path.join(tmp, ".socket.sock")
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
srv.listen(8)
answering = True


def serve():
    while True:
        c, _ = srv.accept()
        with c:
            req = c.recv(4096).decode()
            if answering:
                c.sendall((json.dumps(monitors) if req == "j/monitors" else "unknown request").encode())


threading.Thread(target=serve, daemon=True).start()
g.hypr_socket = lambda: SOCK
g.USER = getpass.getuser()
g.RUN_DIR = os.path.join(tmp, "run")
folder = os.path.join(g.RUN_DIR, str(os.getuid()), "omacvm")
os.makedirs(folder)
LAYOUT = os.path.join(folder, "displays.json")


def layout(outputs, extra=None):
    msg = {"layout": [{"output": n, "x": x, "y": y, "width": w, "height": h, "scale": 1} for n, x, y, w, h in outputs],
           "external": True, "fullscreen": True, "builtin": "Virtual-1"}
    if extra:
        msg.update(extra)
    with open(LAYOUT, "w") as f:
        f.write(json.dumps(msg) + "\n")


def focused(name):
    global monitors
    monitors = [{"name": n, "focused": n == name} for n in ("Virtual-1", "Virtual-2")]


TWO = [("Virtual-1", 0, 32, 1512, 950), ("Virtual-2", 1512, 0, 1920, 1080)]
layout(TWO)
focused("Virtual-2")
check(g.focus_line() == "D 1512 0 1920 1080\n", "focus on the external's output: its place on the Mac")
focused("Virtual-1")
check(g.focus_line() == "D 0 32 1512 950\n", "focus on the main output: the main display's place")
layout(TWO[:1])
check(g.focus_line() == "D -\n", "one output only: not known (the Mac's pointer says it)")
layout(TWO)
focused("HDMI-A-1")
check(g.focus_line() == "D -\n", "a focused output the Mac does not know: not known")
focused("Virtual-2")
os.remove(LAYOUT)
check(g.focus_line() == "D -\n", "no displays.json (another route, not full screen): not known")
other = os.path.join(tmp, "other.json")
with open(other, "w") as f:
    f.write(json.dumps({"layout": [{"output": "Virtual-2", "x": 9, "y": 9, "width": 9, "height": 9}]}))
os.symlink(other, LAYOUT)
check(g.focus_line() == "D -\n", "a link in its place: not followed")
os.remove(LAYOUT)
with open(LAYOUT, "w") as f:
    f.write("{not json")
check(g.focus_line() == "D -\n", "junk in the file: not known")
layout([("Virtual-1", 0, 0, 1512, 950), ("Virtual-2", "x", 0, 1920, 1080)])
check(g.focus_line() == "D -\n", "an output without numbers is left out")
layout([("Virtual-1", 0, 0, 1512, 950), ("Virtual-2", 1512, 0, 0, 1080)])
check(g.focus_line() == "D -\n", "an output of no size is left out")
layout([("Virtual-1", 0, 0, 1512, 950), ("Virtual-2", float("inf"), 0, 1920, 1080)])
check(g.focus_line() == "D -\n", "an endless number is left out")
with open(LAYOUT, "w") as f:
    f.write(" " * (g.LAYOUT_MAX + 1))
check(g.focus_line() == "D -\n", "a file too big for a layout: not read")
layout(TWO)
answering = False
check(g.focus_line() == "D -\n", "Hyprland not answering: not known")
answering = True
g.USER = "omacvm-nobody-here"
check(g.focus_line() == "D -\n", "no such desktop user: not known")
g.USER = getpass.getuser()

# "Q" through the daemon's own handle(): the answer comes on the connection, off its thread.
sent = []
g.SWIPE.send = lambda b: sent.append(b.decode())
g.handle([b"Q"], None, None, None)
for _ in range(100):
    if sent:
        break
    time.sleep(0.01)
check(sent == ["D 1512 0 1920 1080\n"], "\"Q\" from the Mac: answered with the focused output's place")
g.SWIPE.send = None
g.handle([b"Q"], None, None, None)
time.sleep(0.1)
check(True, "\"Q\" with no connection: nothing sent, no error")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fails else 0)
