#!/usr/bin/env python3
"""Offline test of Swipe out to macOS in the guest daemon (src/gestures/mac/test.sh):
the daemon's own handle() with evdev stubbed, against a made-up Hyprland on a
Unix socket (j/monitors, j/workspaces, j/getoption, dispatch). No VM, no uinput.
  off until the Mac says "X on"; "X off" turns it off again;
  past the lowest workspace of the focused display -> "X left";
  past the last one: the first swipe from a workspace with windows is
  Hyprland's (a new empty one), from the empty last one -> "X right";
  workspace_swipe_invert and _create_new followed; a Magic Mouse's swipe
  (four fingers, at most 0.35 of the width) counts; short, up-and-down and
  two-finger touches, a special workspace or no Hyprland: nothing;
  after "X right" Hyprland's new empty workspace goes back to the one the
  swipe began on; no notices on "S esc" or "N".
  "X on 2" (the Mac follows the fingers itself): "E <l> <r>" at once and after
  each burst of Hyprland's workspace events (a made-up event socket), only
  when it changed, nothing at the lift; again on a new connection and when
  the event socket comes back; nothing after "X off"; "X on" as before.
"""
import importlib.machinery
import importlib.util
import json
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


# ---- the made-up Hyprland ----
class Hypr:
    def __init__(self):
        self.monitors = []
        self.workspaces = []
        self.options = {"gestures:workspace_swipe_invert": 1, "gestures:workspace_swipe_create_new": 1}
        self.requests = []
        self.after_swipe = None   # (monitors, workspaces) Hyprland shows once a request came after the lift
        self.lifted = False
        self.old_options = False  # answer options as Hyprland before 0.56 did ({"int": 1})
        self.v57 = False          # workspaces as Hyprland 0.57 says them: no id for a special or named one

    def ws(self, key):
        """A workspace reference (activeWorkspace): a number, or a name (a named workspace)."""
        if not self.v57:
            return {"id": key if isinstance(key, int) else -1337, "name": str(key)}
        w = {"address": str(key), "type": "normal", "name": str(key)}
        if isinstance(key, int):
            w["id"] = key
        return w

    def special(self, sid):
        """specialWorkspace: none (0), or the scratchpad (its 0.56 id, e.g. -98)."""
        if not self.v57:
            return {"id": sid, "name": "special:magic" if sid else ""}
        return {"address": "special:magic", "type": "special", "name": "special:magic"} if sid else \
            {"address": "", "type": "", "name": ""}

    def world(self, active, ids, windows=None, monitor="Virtual-1", others=(), special=0):
        windows = windows or {}
        self.monitors = [{"name": monitor, "focused": True, "activeWorkspace": self.ws(active),
                          "specialWorkspace": self.special(special)}]
        for name, act in others:
            self.monitors.append({"name": name, "focused": False, "activeWorkspace": self.ws(act),
                                  "specialWorkspace": self.special(0)})
        self.workspaces = [dict(self.ws(i), monitor=monitor, windows=windows.get(i, 0)) for i in ids]
        for name, act in others:
            self.workspaces.append(dict(self.ws(act), monitor=name, windows=1))
        self.after_swipe = None
        self.lifted = False

    def answer(self, req):
        self.requests.append(req)
        if self.lifted and self.after_swipe and req.startswith("j/"):
            self.monitors, self.workspaces = self.after_swipe
            self.after_swipe = None
        if req == "j/monitors":
            return json.dumps(self.monitors)
        if req == "j/workspaces":
            return json.dumps(self.workspaces)
        if req.startswith("j/getoption "):
            name = req.split(" ", 1)[1]
            if name not in self.options:
                return "no such option"
            # Hyprland 0.56 answers a bool option with "bool"; older ones with "int".
            key = "int" if self.old_options else "bool"
            return json.dumps({"option": name, key: self.options[name] if key == "int" else bool(self.options[name]), "set": False})
        if req.startswith("dispatch "):
            return "ok"
        return "unknown request"


H = Hypr()
tmp = tempfile.mkdtemp()
SOCK = os.path.join(tmp, ".socket.sock")
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK)
srv.listen(8)


def serve():
    while True:
        c, _ = srv.accept()
        with c:
            req = c.recv(4096).decode()
            c.sendall(H.answer(req).encode())


threading.Thread(target=serve, daemon=True).start()
g.hypr_socket = lambda: SOCK

sent = []
g.SWIPE.send = lambda b: sent.append(b.decode().strip())
shown = []
g.notify = lambda text, ms=2500: shown.append(text) or True
g.ESC_HINT_FILE = os.path.join(tmp, "escape-hint-shown")


class Held:
    def release(self):
        pass

    def frame(self, contacts):
        pass


def line(text):
    g.handle(text.encode().split(), Held(), Held(), Held())


g.set_mac(1, 15600, 9600)   # the 16" MacBook Pro's trackpad (1/100 mm)


def swipe(dx, dy=0.0, fingers=4, steps=8, x0=0.5):
    """Fingers from x0 sideways by dx (a share of the trackpad), dy up or down; then lifted."""
    sent.clear()
    for k in range(steps + 1):
        f = k / steps
        parts = [str(fingers)]
        for i in range(fingers):
            parts += [str(10 + i), f"{x0 - 0.1 + 0.05 * i + dx * f:.5f}", f"{0.5 + dy * f:.5f}", "0.5"]
        line("F " + " ".join(parts))
        time.sleep(0.004)
    H.lifted = True
    line("F 0")
    return list(sent)


# ---- off until the Mac says so ----
H.world(1, [1, 2, 3], {1: 2, 2: 1, 3: 1})
H.requests.clear()
check(swipe(0.3) == [] and H.requests == [], "off (no X on yet): a swipe past the first workspace sends nothing, asks Hyprland nothing")
line("X on")
check(g.SWIPE.on, "X on: on")

# ---- left: past the lowest workspace (invert on: fingers to the right = the previous workspace) ----
H.world(1, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(0.3) == ["X left"], "workspace 1 of 1..3, swipe toward the previous: X left")
H.world(2, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(0.3) == [], "workspace 2 of 1..3, the same swipe: Hyprland's (to 1), nothing sent")
H.world(3, [3, 5], {3: 1, 5: 1})
check(swipe(0.3) == ["X left"], "workspace 3, the lowest that exists (1 and 2 do not): X left")

# ---- right: Hyprland makes a new empty workspace first ----
H.world(3, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(-0.3) == [], "last workspace (3) with windows, toward the next: Hyprland makes a new one, nothing sent")
H.world(4, [1, 2, 3, 4], {1: 2, 2: 1, 3: 1, 4: 0})
H.requests.clear()
H.after_swipe = ([{"name": "Virtual-1", "focused": True, "activeWorkspace": {"id": 5, "name": "5"},
                   "specialWorkspace": {"id": 0, "name": ""}}],
                 [{"id": i, "name": str(i), "monitor": "Virtual-1", "windows": w} for i, w in ((1, 2), (2, 1), (3, 1), (5, 0))])
check(swipe(-0.3) == ["X right"], "the empty last workspace (4), toward the next: X right")
time.sleep(0.8)
check('dispatch hl.dsp.focus({ workspace = "4" })' in H.requests,
      "... Hyprland's swipe had gone on to a new empty 5: back to 4 (as it was when the person comes back)")
H.world(2, [1, 2, 3], {1: 1, 2: 0, 3: 1})
check(swipe(-0.3) == [], "an empty workspace in the middle, toward the next: Hyprland's")
H.options["gestures:workspace_swipe_create_new"] = 0
H.world(3, [1, 2, 3], {1: 2, 2: 1, 3: 1})
check(swipe(-0.3) == ["X right"], "workspace_swipe_create_new off: the last workspace with windows: X right at once")
H.options["gestures:workspace_swipe_create_new"] = 1

# ---- invert off: fingers to the right = the next workspace ----
H.options["gestures:workspace_swipe_invert"] = 0
H.world(1, [1, 2], {1: 1, 2: 0})
check(swipe(-0.3) == ["X left"], "invert off: fingers to the left from the first: X left")
H.world(2, [1, 2], {1: 1, 2: 0})
check(swipe(0.3) == ["X right"], "invert off: fingers to the right from the empty last: X right")
H.old_options = True
H.world(1, [1, 2], {1: 1, 2: 0})
check(swipe(-0.3) == ["X left"], "invert off, said as before Hyprland 0.56 ({\"int\": 0}): the same")
H.options["gestures:workspace_swipe_invert"] = 1
check(swipe(0.3) == ["X left"] and swipe(-0.3) == [], "invert on, said as {\"int\": 1}: fingers to the right from the first: X left")
H.old_options = False

# ---- not a swipe out ----
H.world(1, [1, 2, 3], {1: 2})
check(swipe(0.08) == [], "a short swipe (8 % of the width): nothing")
check(swipe(0.25, dy=0.3) == [], "mostly up or down: nothing")
check(swipe(0.3, fingers=2) == [], "two fingers (scrolling): nothing")
check(swipe(0.3, fingers=3) == ["X left"], "three fingers: counts (Hyprland swipes workspaces with 3 and 4)")
H.world(1, [1, 2, 3], {1: 2}, special=-98)
check(swipe(0.3) == [], "a special workspace open (the scratchpad): nothing")

# ---- Hyprland 0.57's JSON (as hyprctl printed it on 0.57.0-2): a special or named workspace has no id ----
H.v57 = True
H.world(1, [1, 2, 3], {1: 2})
check(swipe(0.3) == ["X left"], "Hyprland 0.57: workspace 1 of 1..3, toward the previous: X left")
H.world(1, [1, 2, 3], {1: 2}, special=-98)
check(g.workspaces_now(SOCK)["special"] is True, "Hyprland 0.57: the scratchpad open (its name, no id): seen")
check(swipe(0.3) == [], "Hyprland 0.57: the scratchpad open: nothing")
H.world("notes", [1, 2], {1: 1, "notes": 0})
st = g.workspaces_now(SOCK)
check(st["active"] is None and st["empty"] is True and swipe(0.3) == [],
      "Hyprland 0.57: a named workspace (no number): found by its name, no swipe out")
H.v57 = False

# ---- a Magic Mouse: four virtual fingers, at most 0.35 of the width, from the middle ----
H.world(1, [1, 2], {1: 1})
check(swipe(0.35, fingers=4) == ["X left"], "Magic Mouse swipe (4 virtual fingers, 0.35 of the width): X left")
H.world(2, [1, 2], {1: 1, 2: 0})
check(swipe(-0.2, fingers=3) == ["X right"], "Magic Mouse swipe with MouseSwipeFingers 3, toward the next from the empty last: X right")

# ---- another display: its own workspaces ----
H.world(11, [11, 12], {11: 1, 12: 1}, monitor="Virtual-2", others=[("Virtual-1", 1)])
check(swipe(0.3) == ["X left"], "the focused display Virtual-2, its lowest (11): X left (Virtual-1's 1 does not count)")
H.world(12, [11, 12], {11: 1, 12: 1}, monitor="Virtual-2", others=[("Virtual-1", 1)])
check(swipe(0.3) == [], "... from its 12: Hyprland's")

# ---- the workspaces as they were at the swipe's start ----
H.world(1, [1, 2], {1: 1, 2: 1})
H.after_swipe = None
sent.clear()
for k in range(9):
    f = k / 8
    line("F 4 " + " ".join(f"{10 + i} {0.4 + 0.05 * i + 0.3 * f:.5f} 0.5 0.5" for i in range(4)))
    if k == 0:
        time.sleep(0.05)   # the start was read: now Hyprland moves on (as its swipe would)
        H.world(2, [1, 2], {1: 1, 2: 1})
line("F 0")
check(sent == ["X left"], "Hyprland changed during the swipe: the start counts (it began on 1): X left")

# ---- no Hyprland ----
real = g.hypr_socket
g.hypr_socket = lambda: None
check(swipe(0.3) == [], "Hyprland does not answer: nothing")
g.hypr_socket = os.path.join(tmp, "gone.sock").__str__
check(swipe(0.3) == [], "Hyprland's socket gone: nothing")
g.hypr_socket = real

# ---- the capture ends mid-swipe; off again ----
H.world(1, [1, 2, 3], {1: 2})
sent.clear()
line("F 4 10 0.4 0.5 0.5 11 0.45 0.5 0.5 12 0.5 0.5 0.5 13 0.55 0.5 0.5")
line("S esc ctrl-opt")
line("F 4 10 0.7 0.5 0.5 11 0.75 0.5 0.5 12 0.8 0.5 0.5 13 0.85 0.5 0.5")
line("F 0")
check(sent == [], "S esc during a swipe: that swipe is dropped")
line("X off")
check(not g.SWIPE.on and swipe(0.3) == [], "X off: nothing")
line("X on")

# ---- no notices any more (user, 2026-10-12) ----
shown.clear()
for text in ("S esc", "S esc ctrl-opt", "N space-shortcut-off", "N space-unchanged", "N no-spaces", "N some-new-word"):
    line(text)
check(shown == [], "no notice on S esc, S esc ctrl-opt or N <why>")
line("S esc ctrl-opt-cmd")
check(len(shown) == 1 and "New shortcut" in shown[0], "the old ⌃⌥⌘ Esc: the new one is named, once per VM")
line("S esc ctrl-opt-cmd")
check(len(shown) == 1, "... not again")

# ---- the Mac follows the fingers itself ("X on 2"): where swipes go, at once and on every change ----
EV = os.path.join(tmp, ".socket2.sock")
evsrv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
evsrv.bind(EV)
evsrv.listen(4)
evconns = []


def evserve():
    while True:
        c, _ = evsrv.accept()
        evconns.append(c)


threading.Thread(target=evserve, daemon=True).start()


def event(*texts):
    """Hyprland's event socket says these (one burst)."""
    for c in list(evconns):
        try:
            c.sendall("".join(t + "\n" for t in texts).encode())
        except OSError:
            evconns.remove(c)


def told(n, wait=1.5):
    """The E lines the Mac got, once there are n (or after wait s)."""
    end = time.monotonic() + wait
    while time.monotonic() < end and len([s for s in sent if s.startswith("E ")]) < n:
        time.sleep(0.01)
    time.sleep(0.1)
    return [s for s in sent if s.startswith("E ")]


H.world(1, [1, 2, 3], {1: 2, 2: 1, 3: 1})
sent.clear()
line("X on 2")
check(g.SWIPE.on and g.SWIPE.version == 2 and told(1) == ["E - left"],
      "X on 2: where swipes go, at once: workspace 1 of 1..3, invert on: fingers left Hyprland's, right out to the left")
check(swipe(0.3) == [], "... a swipe past the first workspace: nothing at the lift (the Mac took it)")
sent.clear()
H.world(2, [1, 2, 3], {1: 2, 2: 1, 3: 1})
event("workspace>>2", "workspacev2>>2,2")
check(told(1) == ["E - -"], "Hyprland's workspace>>2 (a burst of two): one line, E - - (both ways Hyprland's)")
sent.clear()
H.world(3, [1, 2, 3], {1: 2, 2: 1, 3: 1})
event("workspace>>3")
check(told(1, wait=0.5) == [], "to the last workspace with windows: still E - - (the first swipe makes a new one): nothing sent")
H.world(4, [1, 2, 3, 4], {1: 2, 2: 1, 3: 1, 4: 0})
event("createworkspace>>4", "createworkspacev2>>4,4", "workspace>>4", "workspacev2>>4,4")
check(told(1) == ["E right -"], "Hyprland's new empty 4 (the right-edge rule): fingers left out to the right")
sent.clear()
H.world(4, [1, 2, 3, 4], {1: 2, 2: 1, 3: 1, 4: 1})
event("openwindow>>5a1b,4,foot,foot")
check(told(1) == ["E - -"], "a window opens on 4: E - - again (the next swipe makes a new one)")
sent.clear()
event("activewindow>>foot,foot", "windowtitle>>5a1b")
check(told(1, wait=0.5) == [], "other events (focus, titles): nothing asked, nothing sent")
H.options["gestures:workspace_swipe_invert"] = 0
H.world(1, [1], {1: 0})
event("configreloaded>>")
check(told(1) == ["E left right"], "invert off, one empty workspace: fingers left out to the left, right out to the right")
H.options["gestures:workspace_swipe_invert"] = 1
sent.clear()
H.world(1, [1], {1: 0}, special=-98)
event("activespecial>>special:magic,Virtual-1")
check(told(1) == ["E - -"], "the scratchpad open: E - -")
sent.clear()
H.v57 = True
H.world(1, [1], {1: 0})
event("activespecial>>,Virtual-1")
check(told(1) == ["E right left"], "Hyprland 0.57: the scratchpad closed again: E right left")
sent.clear()
H.world(1, [1], {1: 0}, special=-98)
event("activespecialv2>>special:magic,special:magic,Virtual-1")
check(told(1) == ["E - -"], "Hyprland 0.57: the scratchpad open (no id): E - -")
sent.clear()
H.world(1, [1, 2], {1: 1, 2: 1})
event("changeworkspaceid>>3,2")
check(told(1) == ["E - left"], "Hyprland 0.57: a workspace's id changed (changeworkspaceid): said again")
H.v57 = False
sent.clear()
H.world(1, [1, 2], {1: 1, 2: 1})
g.SWIPE.set(False)
line("X on 2")
check(told(1) == ["E - left"], "connected again (X on 2 again): said again at once")
sent.clear()
for c in list(evconns):
    c.close()
evconns.clear()
H.world(2, [1, 2], {1: 1, 2: 0})
check(told(1, wait=3) == ["E right -"], "Hyprland's event socket gone and back: connected again, said again")
sent.clear()
line("X off")
H.world(1, [1, 2], {1: 1, 2: 1})
event("workspace>>1")
check(told(1, wait=0.5) == [] and not g.SWIPE.on, "X off: nothing sent on changes")
line("X on")
H.world(1, [1, 2], {1: 1, 2: 1})
check(swipe(0.3) == ["X left"] and told(1, wait=0.3) == [], "X on (a Mac helper from 3.1.0-3.1.5): X left at the lift as before, no E")
check(g.edge_sides({"active": 2, "ids": [1, 2], "empty": True, "invert": True, "create_new": True}) == ("right", "-") and
      g.edge_sides({"active": 2, "ids": [1, 2, 3], "empty": True, "invert": True, "create_new": True}) == ("-", "-") and
      g.edge_sides(None) == ("-", "-") and
      g.edge_sides({"active": 1, "ids": [1, 2], "empty": False, "invert": True, "create_new": False}) == ("-", "left"),
      "edges on their own: the empty last; in the middle; nothing known; the first")

# ---- which swipes switch workspaces: Hyprland's hl.gesture lines (user, 2026-10-14: 3 fingers tile, 4 switch) ----
cfg = tempfile.mkdtemp()
HOME, OMA = os.path.join(cfg, "home"), os.path.join(cfg, "omarchy")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


ENTRY = """-- Learn how to configure Hyprland
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
"""
write(f"{OMA}/default/hypr/bootstrap.lua", "package.path = 'x'\n")
write(f"{OMA}/default/hypr/omarchy.lua", 'require("default.hypr.input")\n')
write(f"{OMA}/default/hypr/input.lua", "hl.config({ input = { touchpad = { natural_scroll = true } } })\n")
write(f"{HOME}/.config/hypr/monitors.lua", "")
write(f"{HOME}/.config/hypr/bindings.lua", "")
OMACVM_LINES = """
-- OmacVM trackpad: the Mac's multi-finger gestures arrive on a virtual
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
"""
EXAMPLES = """-- Enable touchpad gestures for changing workspaces.
-- hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
"""


def ways(input_lua, entry=ENTRY):
    write(f"{HOME}/.config/hypr/hyprland.lua", entry)
    write(f"{HOME}/.config/hypr/input.lua", input_lua)
    return g.workspace_swipes(HOME, OMA)


check(ways(EXAMPLES + OMACVM_LINES) == {3: "lr", 4: "lr"}, "gestures: OmacVM's lines (3 and 4 horizontal): both counts, both ways")
FOCUS3 = """hl.gesture({ fingers = 3, direction = "left", action = function() hl.dispatch(hl.dsp.focus({ direction = "l" })) end })
hl.gesture({ fingers = 3, direction = "right", action = function() hl.dispatch(hl.dsp.focus({ direction = "r" })) end })
"""
check(ways(FOCUS3 + OMACVM_LINES) == {4: "lr"},
      "gestures: 3 fingers left/right move focus (Omarchy's example) before OmacVM's lines: only 4 fingers switch workspaces")
check(ways(EXAMPLES) == {} and g.swipes_line({}) == "G -\n", "gestures: only the commented example: none (G -)")
check(ways('hl.gesture({\n  fingers = 4,\n  direction = "horizontal",\n  action = "workspace",\n})\n') == {4: "lr"},
      "gestures: a table over several lines")
check(ways(OMACVM_LINES + 'hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })\n'
           'hl.gesture({ fingers = 3, direction = "horizontal", action = "move" })\n') == {4: "lr"},
      "gestures: 3 unset, then 3 given to moving windows: only 4")
check(ways('hl.gesture({ fingers = 3, direction = "swipe", action = "move" })\n' + OMACVM_LINES) == {4: "lr"},
      "gestures: 3 fingers any way (swipe) to move windows first: OmacVM's 3-finger line is shadowed, only 4")
check(ways('hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace", mods = "SUPER" })\n') == {},
      "gestures: a workspace swipe that needs a key held (mods): not a plain swipe")
check(ways('hl.gesture({ fingers = 4, direction = "left", action = "workspace" })\n'
           'hl.gesture({ fingers = 4, direction = "right", action = "close" })\n') == {4: "l"},
      "gestures: 4 left switches, 4 right closes a window: only fingers going left")
check(ways('for _, n in ipairs({ 3, 4 }) do hl.gesture({ fingers = n, direction = "horizontal", action = "workspace" }) end\n') is None,
      "gestures: a count that is not written out (a loop): cannot tell (None: the Mac keeps any 3+)")
check(ways("", entry=ENTRY + 'hl.gesture({ fingers = 5, direction = "horizontal", action = "workspace" })\n') == {5: "lr"},
      "gestures: a line in hyprland.lua itself, after the requires")
check(ways("--[[ hl.gesture({ fingers = 3, direction = \"horizontal\", action = \"workspace\" }) ]]\n"
           'hl.gesture({ fingers = 4, direction = "horiz", action = "workspace" }) -- hl.gesture({ fingers = 3 })\n') == {4: "lr"},
      "gestures: block and line comments skipped, Hyprland's short name horiz")
# A user's setup (2026-10-14): a guard wraps hl.gesture and drops OmacVM's
# 3-finger line, then a Lua gesture over several lines snaps windows with 3
# fingers any way; 4 fingers switch workspaces.
GUARD = """local gesture = hl.gesture
hl.gesture = function(spec)
  if spec.fingers == 3 and spec.direction == "horizontal" and spec.action == "workspace" and not spec.mods then
    return
  end
  return gesture(spec)
end
"""
SNAP = """local acc = { x = 0, y = 0 }
hl.gesture({
  fingers = 3,
  direction = "swipe",
  action = {
    start = function() acc.x, acc.y = 0, 0 end,
    finish = function() snap(acc.x, acc.y) end,
  },
})
hl.gesture({ fingers = 3, mods = "SUPER", direction = "swipe", action = "resize" })
"""
write(f"{HOME}/.config/hypr/omacvm_guard.lua", GUARD)
write(f"{HOME}/.config/hypr/windowsnap.lua", SNAP)
USER_ENTRY = ENTRY.replace('require("hypr.input")', 'require("hypr.omacvm_guard")\nrequire("hypr.input")\nrequire("hypr.windowsnap")')
check(ways('hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })\n' + OMACVM_LINES, USER_ENTRY) == {4: "lr"},
      "gestures: 3 fingers snap windows (a later Lua gesture, OmacVM's 3-finger line dropped by a guard): only 4")
check(ways(OMACVM_LINES + 'hl.gesture({ fingers = 3, direction = "left", action = "close" })\n') == {3: "r", 4: "lr"},
      "gestures: a later 3-finger left for something else (Hyprland would refuse it): 3 fingers left stay the VM's")
check(ways('hl.gesture({ fingers = 3, direction = "horizontal", action = "move" })\n'
           'hl.gesture({ fingers = 3, direction = "horizontal", action = "unset" })\n' + OMACVM_LINES) == {3: "lr", 4: "lr"},
      "gestures: 3 given to moving windows, then unset, then OmacVM's lines: 3 and 4")
check(g.sideways_counts(HOME) == {3, 4}, "install: the counts a sideways gesture uses (any action, the guard's file too)")
write(f"{HOME}/.config/hypr/windowsnap.lua", "")
write(f"{HOME}/.config/hypr/input.lua", 'hl.gesture({ fingers = 3, direction = "up", action = "fullscreen" })\n'
      'hl.gesture({ fingers = 4, mods = "SUPER", direction = "horizontal", action = "move" })\n')
check(g.sideways_counts(HOME) == set(), "install: up, or with a key held: no sideways count")
write(f"{HOME}/.config/hypr/unloaded.lua", 'hl.gesture({\n  direction = "left",\n  fingers = 4,\n  action = "close",\n})\n')
check(g.sideways_counts(HOME) == {4}, "install: a file in ~/.config/hypr that nothing requires counts too")
os.remove(f"{HOME}/.config/hypr/unloaded.lua")
os.remove(f"{HOME}/.config/hypr/omacvm_guard.lua")
os.remove(f"{HOME}/.config/hypr/windowsnap.lua")
os.remove(f"{HOME}/.config/hypr/hyprland.lua")
check(g.workspace_swipes(HOME, OMA) is None, "gestures: no hyprland.lua (not Omarchy 4's Lua config): None")
check(g.swipes_line({3: "l", 4: "lr"}) == "G 3l 4lr\n", "gestures: the G line")

# ... sent to the Mac with E, again after a config reload, only when it changed.
write(f"{HOME}/.config/hypr/hyprland.lua", ENTRY)
write(f"{HOME}/.config/hypr/input.lua", OMACVM_LINES)
real_ws = g.workspace_swipes
g.workspace_swipes = lambda: real_ws(HOME, OMA)
H.world(1, [1, 2], {1: 1, 2: 1})
sent.clear()
g.SWIPE.set(False)
line("X on 2")
first = told(1)
check([s for s in sent if s.startswith("G ")] == ["G 3lr 4lr"] and first == ["E - left"] and sent.index("G 3lr 4lr") < sent.index("E - left"),
      "X on 2: G 3lr 4lr (Hyprland's gestures) before E")
sent.clear()
write(f"{HOME}/.config/hypr/input.lua", FOCUS3 + OMACVM_LINES)
event("configreloaded>>")
time.sleep(0.6)
check([s for s in sent if s.startswith("G ")] == ["G 4lr"], "config reloaded (3 fingers now move focus): G 4lr")
sent.clear()
event("configreloaded>>")
time.sleep(0.6)
check([s for s in sent if s.startswith("G ")] == [], "reloaded again, nothing changed: no G")
# A Mac from 3.1.0-3.1.5 ("X on"): the lift follows the counts too.
line("X on")
H.world(1, [1, 2], {1: 1, 2: 1})
check(swipe(0.3, fingers=3) == [] and swipe(0.3, fingers=4) == ["X left"],
      "X on (old Mac): 3 fingers (focus here) no X; 4 fingers X left")
g.workspace_swipes = real_ws

# ---- the rule on its own ----
st = {"active": 1, "ids": [1, 2], "empty": False, "special": False, "invert": True, "create_new": True}
w = 15600
check(g.swipe_out_side(st, 0.2 * w, 0, w) == "left" and g.swipe_out_side(st, -0.2 * w, 0, w) is None,
      "rule: first of two, previous: left; next: Hyprland's")
check(g.swipe_out_side(None, 0.2 * w, 0, w) is None and g.swipe_out_side({}, 0.2 * w, 0, w) is None,
      "rule: no workspaces known: nothing")
check(g.swipe_out_side(dict(st, ids=[]), 0.2 * w, 0, w) == "left", "rule: no list (only the active one): its own edge")
sys.exit(1 if fails else 0)
