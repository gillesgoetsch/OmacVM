#!/usr/bin/env python3
"""Tests for omacvm-display-sync, the VM's side of "the screen follows the Mac
window" (no VM needed: a fake DRM folder with QEMU-style EDIDs and a fake
hyprctl that acts like Hyprland).

    python3 src/app/guest/tests/test_display_sync.py

What they hold: the mode and scale sent for 4K and 5K at Omarchy's scales,
nothing sent again while Hyprland already shows it (a resend is a modeset:
the screen flashes and every buffer is made again), and the guard that stops
following an output that keeps changing.
"""
import json
import math
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SYNC = HERE.parent / "omacvm-display-sync"


def guest_bash() -> str | None:
    """A bash 4 or newer, as the VM has (macOS's own is 3.2)."""
    for b in (os.environ.get("GUEST_BASH", ""), "/opt/homebrew/bin/bash", "/usr/local/bin/bash", shutil.which("bash")):
        if b and os.access(b, os.X_OK):
            r = subprocess.run([b, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True)
            if r.stdout.strip().isdigit() and int(r.stdout) >= 4:
                return b
    return None


BASH = guest_bash()


def displayid_edid(width: int, height: int, hz: float = 60.0, size: bool = True) -> bytes:
    """A base EDID plus a DisplayID 1.3 type I timing, as QEMU makes them
    (size=False: no physical size, so the scale is Hyprland's "auto")."""
    hblank, hfront, hsync = 160, 48, 32
    vblank, vfront, vsync = 60, 3, 5
    clock = round((width + hblank) * (height + vblank) * hz / 10_000)  # 10 kHz units
    base = bytearray(128)
    base[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    # QEMU's density: 110 points per inch at 2x (the patch rounds to cm).
    if size:
        base[21] = min(255, max(1, round(width / 2 * 2.54 / 110)))
        base[22] = min(255, max(1, round(height / 2 * 2.54 / 110)))
    base[126] = 1
    base[127] = (-sum(base[:127])) % 256

    timing = bytearray(20)
    timing[0:3] = (clock - 1).to_bytes(3, "little")
    timing[3] = 0x80                                   # preferred
    timing[4:6] = (width - 1).to_bytes(2, "little")
    timing[6:8] = (hblank - 1).to_bytes(2, "little")
    timing[8:10] = ((hfront - 1) | 0x8000).to_bytes(2, "little")
    timing[10:12] = (hsync - 1).to_bytes(2, "little")
    timing[12:14] = (height - 1).to_bytes(2, "little")
    timing[14:16] = (vblank - 1).to_bytes(2, "little")
    timing[16:18] = ((vfront - 1) | 0x8000).to_bytes(2, "little")
    timing[18:20] = (vsync - 1).to_bytes(2, "little")
    data = bytes([0x03, 0x00, 20]) + bytes(timing)

    ext = bytearray(128)
    ext[0] = 0x70
    ext[1] = 0x13
    ext[2] = len(data)
    ext[3] = 0x03
    ext[4] = 0
    ext[5:5 + len(data)] = data
    end = 5 + len(data)
    ext[end] = (-sum(ext[1:end])) % 256
    ext[127] = (-sum(ext[:127])) % 256
    return bytes(base) + bytes(ext)


# Hyprland, as far as the display sync sees it: j/monitors, and eval of an
# hl.monitor rule (a modeline mode, a position, a scale).
FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, re, sys
state = os.environ["FAKE_HYPR"]
mons = os.path.join(state, "monitors.json")
args = sys.argv[1:]
if args[:2] == ["-j", "monitors"]:
    print(open(mons).read()); raise SystemExit(0)
if args and args[0] == "eval":
    rule = args[1]
    with open(os.path.join(state, "calls"), "a") as f:
        f.write(rule + "\n")
    if rule.startswith("hl.window_rule("):    # kept apart: the tests count the monitor rules
        if os.path.exists(os.path.join(state, "refuse-window-rule")):
            print("error: refused"); raise SystemExit(0)
        with open(os.path.join(state, "window_rules"), "a") as f:
            f.write(rule + "\n")
        print("ok"); raise SystemExit(0)
    with open(os.path.join(state, "evals"), "a") as f:
        f.write(rule + "\n")
    if os.path.exists(os.path.join(state, "refuse")):
        print("error: refused"); raise SystemExit(0)
    out = re.search(r'output = "([^"]+)"', rule)[1]
    if 'mode = "preferred"' in rule:      # a gone output's parked rule: kept, nothing shown
        print("ok"); raise SystemExit(0)
    m = re.search(r'mode = "modeline (\d+) (\d+) \d+ \d+ (\d+) (\d+) \d+ \d+ (\d+)', rule)
    clock, w, ht, h, vt = map(int, m.groups())
    scale = re.search(r'scale = "([0-9.]+|auto)"', rule)[1]
    scale = 2.0 if scale == "auto" else float(scale)   # Hyprland's own pick
    pos = re.search(r'position = "(-?\d+)x(-?\d+)"', rule)
    data = json.load(open(mons))
    data = [d for d in data if d["name"] != out]
    data.append({"name": out, "width": w, "height": h,
                 "refreshRate": clock * 1e6 / (ht * vt), "scale": scale,
                 "x": int(pos[1]) if pos else 0, "y": int(pos[2]) if pos else 0,
                 "disabled": False, "transform": 0})
    json.dump(data, open(mons, "w"))
    # Hyprland's "Monitor X overlaps with other monitor(s)" after each rule.
    box = lambda d: (d["x"], d["y"], d["width"] / d["scale"], d["height"] / d["scale"])
    for i, a in enumerate(data):
        for b in data[i + 1:]:
            A, B = box(a), box(b)
            if A[0] < B[0] + B[2] and B[0] < A[0] + A[2] and A[1] < B[1] + B[3] and B[1] < A[1] + A[3]:
                with open(os.path.join(state, "overlaps"), "a") as f:
                    f.write(f"{a['name']} {b['name']} after {out}\n")
    print("ok"); raise SystemExit(0)
raise SystemExit(1)
'''

MONITORS_LUA = """-- Omarchy's monitors.lua
local omarchy_monitor_scale = {scale}
hl.monitor({{ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale }})
local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
"""


def clean_scale(width: int, height: int, requested: float) -> float:
    """The closest scale that keeps whole logical pixels (Hyprland's 1/120 steps)."""
    common = math.gcd(width * 120, height * 120)
    want = round(requested * 120)
    divisors = [k for k in range(30, common + 1) if common % k == 0]
    return min(divisors, key=lambda k: (abs(k - want), -k)) / 120


@unittest.skipUnless(BASH, "needs bash 4 or newer (brew install bash)")
class SyncCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="display-sync-"))
        self.drm = self.tmp / "drm"
        self.hypr = self.tmp / "hypr"
        self.bin = self.tmp / "bin"
        self.state = self.tmp / "state"
        for d in (self.drm, self.hypr, self.bin):
            d.mkdir()
        (self.hypr / "monitors.json").write_text("[]")
        fake = self.bin / "hyprctl"
        fake.write_text(FAKE_HYPRCTL)
        fake.chmod(0o755)
        self.config = self.tmp / "monitors.lua"
        self.set_scale("2")

    def tearDown(self):
        # the look the guard schedules for when a hold ends
        subprocess.run(["pkill", "-f", str(SYNC)], capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_scale(self, scale: str):
        self.config.write_text(MONITORS_LUA.format(scale=scale))

    def set_window(self, width: int, height: int, output: str = "Virtual-1", size: bool = True):
        c = self.drm / f"card0-{output}"
        c.mkdir(exist_ok=True)
        (c / "status").write_text("connected\n")
        (c / "edid").write_bytes(displayid_edid(width, height, size=size))

    def run_sync(self) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "FAKE_HYPR": str(self.hypr),
            "OMARCHY_DISPLAY_SYNC_DRM_ROOT": str(self.drm),
            "OMARCHY_DISPLAY_SYNC_MONITOR_CONFIG": str(self.config),
            "OMACVM_DISPLAYS_LAYOUT": str(self.tmp / "no-layout.json"),
            "OMACVM_DISPLAY_SYNC_STATE": str(self.state),
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
            "XDG_RUNTIME_DIR": str(self.tmp / "run"),
        })
        return subprocess.run([BASH, str(SYNC), "--once"], env=env, capture_output=True,
                              text=True, timeout=60)

    def evals(self) -> list[str]:
        try:
            return (self.hypr / "evals").read_text().splitlines()
        except FileNotFoundError:
            return []

    def shown(self, output: str = "Virtual-1") -> dict:
        return next(m for m in json.loads((self.hypr / "monitors.json").read_text())
                    if m["name"] == output)

    def hyprland_reloads(self, width: int, height: int):
        """A config reload: Hyprland goes back to its cached preferred mode."""
        data = json.loads((self.hypr / "monitors.json").read_text())
        for m in data:
            m.update(width=width, height=height, refreshRate=60.0)
        (self.hypr / "monitors.json").write_text(json.dumps(data))


class ModeAndScale(SyncCase):
    def test_secondary_scale_survives_reload_resize_and_replug(self):
        self.set_window(1920, 2160)
        self.set_window(1920, 2160, "Virtual-2")
        self.set_scale("1.6")
        scales = self.tmp / "config/omacvm/scales"
        scales.mkdir(parents=True)
        (scales / "Virtual-2").write_text("1.25\n")
        r = self.run_sync()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.shown("Virtual-2")["scale"], 1.25)
        self.assertEqual(self.shown()["scale"], 1.6)
        self.hyprland_reloads(1920, 1080)
        self.set_window(2560, 1440, "Virtual-2")
        self.run_sync()
        self.assertEqual(self.shown("Virtual-2")["scale"], 1.25)
        self.assertEqual(self.shown("Virtual-2")["width"], 2560)
        (self.drm / "card0-Virtual-2/status").write_text("disconnected\n")
        (self.hypr / "monitors.json").write_text(json.dumps([self.shown()]))
        self.run_sync()
        self.set_window(1920, 2160, "Virtual-2")
        self.run_sync()
        self.assertEqual(self.shown("Virtual-2")["scale"], 1.25)

    def test_panel_command_reaches_dynamic_sync(self):
        from test_omacvm_displays import od
        from unittest import mock
        self.set_window(1920, 2160)
        self.set_window(1920, 2160, "Virtual-2")
        self.set_scale("1.6")
        self.run_sync()
        original = self.config.read_text()
        with mock.patch.object(od, "CONFIG", self.tmp / "config/omacvm/displays.conf"), \
             mock.patch.object(od, "MONITORS_LUA", self.config), \
             mock.patch.object(od, "fullpanel_output", return_value=None), \
             mock.patch.object(od, "focused_monitor", return_value=self.shown("Virtual-2")), \
             mock.patch.object(od.subprocess, "call", side_effect=lambda argv: self.run_sync().returncode) as call:
            self.assertEqual(od.set_scale("1.25"), 0)
            call.assert_called_once_with([od.SYNC, "--once"])
        self.assertEqual(self.shown("Virtual-2")["scale"], 1.25)
        self.assertEqual(self.shown()["scale"], 1.6)
        self.assertEqual(self.config.read_text(), original)

    def test_bad_secondary_preferences_keep_edid_density(self):
        self.set_window(1920, 2160, "Virtual-2")
        scales = self.tmp / "config/omacvm/scales"
        scales.mkdir(parents=True)
        for value in ("nan", "inf", "0", "-1", "broken"):
            (scales / "Virtual-2").write_text(value)
            r = self.run_sync()
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.shown("Virtual-2")["scale"], 2)

    def test_omarchy_scales_at_4k_and_5k(self):
        for width, height in ((5120, 2880), (3840, 2160)):
            for requested in ("1", "1.25", "1.5", "1.6", "1.75", "2"):
                with self.subTest(size=f"{width}x{height}", scale=requested):
                    self.setUp()
                    self.set_window(width, height)
                    self.set_scale(requested)
                    r = self.run_sync()
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(len(self.evals()), 1, r.stderr)
                    m = self.shown()
                    self.assertEqual((m["width"], m["height"]), (width, height))
                    want = clean_scale(width, height, float(requested))
                    self.assertAlmostEqual(m["scale"], want, places=5)
                    # whole logical pixels (to Hyprland's 1/120 steps), or it
                    # falls back to another scale with a warning
                    self.assertAlmostEqual(width / m["scale"], round(width / m["scale"]), places=2)
                    self.assertAlmostEqual(height / m["scale"], round(height / m["scale"]), places=2)
                    self.assertTrue(abs(m["refreshRate"] - 60) < 0.5)
                    self.tearDown()

    def test_nothing_resent_while_shown(self):
        self.set_window(5120, 2880)
        self.set_scale("1.6")
        self.run_sync()
        for _ in range(5):          # reload hook, omacvm-displays, the watcher ...
            r = self.run_sync()
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.evals()), 1)
        self.assertNotIn("keeping", r.stderr)

    def test_scale_change_sent_once(self):
        self.set_window(5120, 2880)
        self.run_sync()
        self.set_scale("1.6")       # Omarchy's scale menu persists it
        self.run_sync()
        self.run_sync()
        self.assertEqual(len(self.evals()), 2)
        self.assertAlmostEqual(self.shown()["scale"], 1.6)

    def test_reload_back_to_cached_mode_is_fixed(self):
        self.set_window(5120, 2880)
        self.run_sync()
        self.hyprland_reloads(1920, 1080)
        self.run_sync()
        self.assertEqual(len(self.evals()), 2)
        self.assertEqual(self.shown()["width"], 5120)

    def test_auto_scale_not_resent(self):
        # No saved scale and no physical size: the rule says scale "auto" and
        # Hyprland picks; the same rule is not sent again while it shows it.
        self.set_window(5120, 2880, size=False)
        self.config.write_text("-- no scale saved\n")
        for _ in range(4):
            r = self.run_sync()
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.evals()), 1, r.stderr)
        self.assertIn('scale = "auto"', self.evals()[0])
        self.set_window(3840, 2160, size=False)     # a new window size is sent
        self.run_sync()
        self.assertEqual(len(self.evals()), 2)

    def test_refused_rule_is_sent_again(self):
        # What a rule changed is only taken as shown once Hyprland said ok:
        # a refused rule (here with Hyprland already at that mode and scale,
        # where only the HDR part would differ) is tried again next time.
        self.set_window(5120, 2880)
        self.run_sync()
        self.assertEqual(len(self.evals()), 1)
        (self.state / "Virtual-1.hdr").write_text(", bitdepth = 10")  # HDR was on
        (self.hypr / "refuse").write_text("")
        r = self.run_sync()
        self.assertIn("rejected", r.stderr)
        self.assertEqual((self.state / "Virtual-1.hdr").read_text(), ", bitdepth = 10")
        (self.hypr / "refuse").unlink()
        self.run_sync()
        self.assertEqual(len(self.evals()), 3)
        self.run_sync()
        self.assertEqual(len(self.evals()), 3)

    def test_users_own_rule_is_left_alone(self):
        self.set_window(5120, 2880)
        self.config.write_text(self.config.read_text() +
                               'hl.monitor({ output = "Virtual-1", mode = "2560x1440", scale = 1 })\n')
        r = self.run_sync()
        self.assertEqual(self.evals(), [])
        self.assertIn("its own rule", r.stderr)
        self.assertFalse((self.state / "Virtual-1.rule").exists())

    # #738: Omarchy 4.5's command keeps the scale in a one-line rule for the
    # output ("preferred" mode). For Virtual-1 that is Omarchy's scale: the
    # screen keeps following the window, with that scale.
    OMARCHY_45 = 'hl.monitor({{ output = "Virtual-1", mode = "preferred", position = "auto", scale = {} }})\n'

    def test_omarchys_scale_rule_is_followed(self):
        self.set_window(3024, 1968)
        self.config.write_text(MONITORS_LUA.format(scale='"auto"') + self.OMARCHY_45.format(1.6))
        r = self.run_sync()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("its own rule", r.stderr)
        m = self.shown()
        self.assertEqual((m["width"], m["height"]), (3024, 1968))
        self.assertAlmostEqual(m["scale"], 1.6)
        self.assertIn('scale = "1.6"', (self.state / "Virtual-1.rule").read_text())
        self.hyprland_reloads(3024, 1964)                # the rule's "preferred": the cached mode
        self.run_sync()
        self.assertEqual((self.shown()["height"], self.shown()["scale"]), (1968, 1.6))
        self.set_window(2940, 1840)                       # window mode: a resize is followed
        self.config.write_text(MONITORS_LUA.format(scale="2") + self.OMARCHY_45.format(1.25))
        self.run_sync()
        m = self.shown()
        self.assertEqual((m["width"], m["height"]), (2940, 1840))
        self.assertAlmostEqual(m["scale"], clean_scale(2940, 1840, 1.25), places=5)

    def test_other_rules_for_the_screen_stay_the_users(self):
        self.set_window(3024, 1968)
        for rule in ('hl.monitor({ output = "Virtual-1", mode = "preferred", position = "auto", scale = 1.6 }) -- mine\n',
                     'hl.monitor({ output = "Virtual-1", mode = "3024x1964@120", position = "auto", scale = 1.6 })\n',
                     'hl.monitor({ output = "Virtual-1", mode = "preferred", position = "0x0", scale = 1.6 })\n'):
            with self.subTest(rule=rule):
                self.config.write_text(MONITORS_LUA.format(scale="2") + rule)
                r = self.run_sync()
                self.assertIn("its own rule", r.stderr)
                self.assertEqual(self.evals(), [])


class KeptRule(SyncCase):
    """The rule an output shows is kept for omacvm_app.lua, which sets it again
    while Hyprland reloads its config (a theme switch): no "auto" place."""

    def kept(self, output: str = "Virtual-1") -> str:
        return (self.state / f"{output}.rule").read_text().strip()

    def test_sent_rule_is_kept(self):
        self.set_window(5120, 2880)
        self.run_sync()
        self.assertEqual(self.kept(), self.evals()[-1])
        self.assertIn('position = "0x0"', self.kept())

    def test_kept_when_already_shown(self):
        # An update of the guest side: Hyprland shows the rule already, so
        # nothing is sent, but the rule is kept for the next reload.
        self.set_window(5120, 2880)
        self.run_sync()
        (self.state / "Virtual-1.rule").unlink()
        self.run_sync()
        self.assertEqual(len(self.evals()), 1)
        self.assertEqual(self.kept(), self.evals()[0])

    def test_follows_a_scale_change(self):
        self.set_window(5120, 2880)
        self.run_sync()
        self.set_scale("1.6")
        self.run_sync()
        self.assertEqual(self.kept(), self.evals()[-1])
        self.assertIn('scale = "1.6"', self.kept())

    def test_user_rule_drops_it(self):
        self.set_window(5120, 2880)
        self.run_sync()
        self.config.write_text(self.config.read_text() +
                               'hl.monitor({ output = "Virtual-1", mode = "2560x1440", scale = 1 })\n')
        self.run_sync()
        self.assertFalse((self.state / "Virtual-1.rule").exists())

    def test_gone_output_drops_it(self):
        self.set_window(4112, 2582)
        self.set_window(6016, 3384, output="Virtual-2")
        self.run_sync()
        self.assertTrue((self.state / "Virtual-2.rule").exists())
        (self.drm / "card0-Virtual-2" / "status").write_text("disconnected\n")
        data = [m for m in json.loads((self.hypr / "monitors.json").read_text()) if m["name"] != "Virtual-2"]
        (self.hypr / "monitors.json").write_text(json.dumps(data))
        self.run_sync()
        self.assertFalse((self.state / "Virtual-2.rule").exists())
        self.assertTrue((self.state / "Virtual-1.rule").exists())


class Guard(SyncCase):
    def run_sync(self):
        # The guard counts changes within 10 s. A slow machine (CI, a busy
        # VM) must not stretch the test past that: every change so far
        # counts as just now.
        h = self.state / "Virtual-1.history"
        if h.exists():
            now = time.time()
            h.write_text("".join(f"{now} {line.split()[1]}\n" for line in h.read_text().splitlines()))
        return super().run_sync()

    def test_ping_pong_is_held(self):
        # Something flips the output between two states (a loop): the 6th
        # change in 10 s is held, and nothing more is sent for a while.
        for i in range(10):
            self.set_window(*((5120, 2880) if i % 2 == 0 else (2560, 1440)))
            r = self.run_sync()
            if "keeping" in r.stderr:
                break
        self.assertEqual(i, 5, "held at the 6th change")
        self.assertEqual(len(self.evals()), 5)
        self.assertIn("between two states", r.stderr)
        held = (self.state / "held").read_text()
        self.assertIn("Virtual-1 changed 6 times", held)
        self.set_window(3840, 2160)          # still held: nothing sent, quietly
        r = self.run_sync()
        self.assertEqual(len(self.evals()), 5)
        self.assertEqual(r.stderr.count("keeping"), 0)
        # one look is scheduled for when the hold ends
        # this checkout's path only: other CI jobs on the same Mac run this test too
        looks = subprocess.run(["pgrep", "-f", "sleep 61; exec .*" + str(SYNC).replace(".", "[.]")],
                               capture_output=True, text=True).stdout.split()
        self.assertEqual(len(looks), 1)

    def test_window_resize_is_followed(self):
        # A window being resized: a new size each time (about one a second
        # in real life); 11 in a row are all sent.
        for i in range(11):
            self.set_window(2400 + 40 * i, 1600)
            r = self.run_sync()
            self.assertNotIn("keeping", r.stderr)
        self.assertEqual(len(self.evals()), 11)

    def test_storm_is_held(self):
        for i in range(14):
            self.set_window(2400 + 40 * i, 1600)
            r = self.run_sync()
            if "keeping" in r.stderr:
                break
        self.assertEqual(i, 11, "held at the 12th change in 10 s")
        self.assertIn("to new states", r.stderr)

    def test_hold_ends(self):
        for i in range(6):
            self.set_window(*((5120, 2880) if i % 2 == 0 else (2560, 1440)))
            self.run_sync()
        hold = self.state / "Virtual-1.hold"
        self.assertTrue(hold.exists())
        hold.write_text("0\n")                # the 60 s are over
        self.set_window(3840, 2160)
        self.run_sync()
        self.assertEqual(self.shown()["width"], 3840)


class TwoDisplays(SyncCase):
    """The user's MacBook (2026-10-06): built-in below a 6K, full screen."""

    def setUp(self):
        super().setUp()
        layout = {"layout": [
            {"output": "Virtual-1", "x": 0, "y": 38, "width": 2056, "height": 1291, "scale": 2},
            {"output": "Virtual-2", "x": -476, "y": -1692, "width": 3008, "height": 1692, "scale": 2}]}
        (self.tmp / "no-layout.json").write_text(json.dumps(layout))

    def test_no_overlap_on_the_way(self):
        self.set_window(4112, 2582)
        self.set_window(6016, 3384, output="Virtual-2")
        # Hyprland's own first places: the main one at 0x0, the 6K to its right.
        (self.hypr / "monitors.json").write_text(json.dumps([
            {"name": "Virtual-1", "x": 0, "y": 0, "width": 4112, "height": 2582, "scale": 2.0,
             "refreshRate": 60.0, "disabled": False, "transform": 0},
            {"name": "Virtual-2", "x": 2056, "y": 0, "width": 6016, "height": 3384, "scale": 2.0,
             "refreshRate": 60.0, "disabled": False, "transform": 0}]))
        r = self.run_sync()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.hypr / "overlaps").exists(),
                         (self.hypr / "overlaps").read_text() if (self.hypr / "overlaps").exists() else "")
        self.assertEqual([re.search(r'output = "([^"]+)"', e)[1] for e in self.evals()],
                         ["Virtual-1", "Virtual-2"])
        self.assertEqual((self.shown("Virtual-2")["x"], self.shown("Virtual-2")["y"]), (0, 0))
        self.assertEqual((self.shown("Virtual-1")["x"], self.shown("Virtual-1")["y"]), (476, 1730))

    def test_gone_output_is_parked(self):
        self.set_window(4112, 2582)
        self.set_window(6016, 3384, output="Virtual-2")
        self.run_sync()
        # The 6K leaves (window mode): its connector and Hyprland's output go.
        (self.drm / "card0-Virtual-2" / "status").write_text("disconnected\n")
        data = [m for m in json.loads((self.hypr / "monitors.json").read_text()) if m["name"] != "Virtual-2"]
        (self.hypr / "monitors.json").write_text(json.dumps(data))
        self.run_sync()
        parked = [e for e in self.evals() if 'output = "Virtual-2"' in e and "auto-right" in e]
        self.assertEqual(len(parked), 1, self.evals())
        self.run_sync()
        self.assertEqual(len([e for e in self.evals() if "auto-right" in e]), 1, "parked once")


def script_python(function: str) -> str:
    """The Python inside one of the script's shell functions (no bash 4 needed)."""
    text = SYNC.read_text()
    start = text.index(f"{function}() {{")
    body = text[start:]
    return body[body.index("<<'PY'\n") + 7:body.index("\nPY\n")]


def overlap(a, b) -> bool:
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


class HDR(SyncCase):
    """HDR and 10-bit colour (the app's switch): Virtual-1 at 10 bits only when
    this start asked for it and the 10-bit driver runs; PQ only while QEMU says
    it shows PQ ("edr", the headroom of the window's display)."""

    def setUp(self):
        super().setUp()
        self.host_env = self.tmp / "host.env"
        self.status = self.tmp / "virtio-gpu"
        self.taint = self.tmp / "taint"
        self.host_env.write_text("OMACVM_DEEPCOLOR=1\n")
        self.status.write_text("omacvm\n")
        self.taint.write_text("O\n")
        self.set_window(5120, 2880)

    def layout(self, edr=None):
        main = {"output": "Virtual-1", "x": 0, "y": 0, "width": 1728, "height": 1117, "scale": 2}
        if edr is not None:
            main["edr"] = edr
        (self.tmp / "no-layout.json").write_text(json.dumps({"layout": [main]}))

    def run_sync(self) -> subprocess.CompletedProcess:
        os.environ.update({"OMACVM_HOST_ENV": str(self.host_env),
                           "OMACVM_VIRTIO_GPU_STATUS": str(self.status),
                           "OMACVM_VIRTIO_GPU_TAINT": str(self.taint)})
        try:
            return super().run_sync()
        finally:
            for k in ("OMACVM_HOST_ENV", "OMACVM_VIRTIO_GPU_STATUS", "OMACVM_VIRTIO_GPU_TAINT"):
                os.environ.pop(k, None)

    def test_nothing_before_qemus_layout(self):
        self.run_sync()
        self.assertNotIn("bitdepth", self.evals()[-1])

    def test_10_bit_sdr_without_pq(self):
        for edr in (None, 0):       # an older runtime; QEMU cannot show PQ
            self.layout(edr)
            self.run_sync()
            self.assertIn('bitdepth = 10, cm = "srgb", supports_wide_color = 1, supports_hdr = 1', self.evals()[-1])
            self.assertNotIn("max_luminance", self.evals()[-1])

    def test_sdr_after_pq_keeps_supports_hdr(self):
        # Hyprland sets or clears an output's HDR metadata only while the
        # output says it supports HDR, and a KMS recorder reads it from the
        # connector (#579): the SDR rule says supports_hdr itself instead of
        # relying on hl.monitor keeping it from the PQ rule.
        self.layout(2)
        self.run_sync()
        self.layout(0)                                   # QEMU cannot show PQ now
        self.run_sync()
        last = self.evals()[-1]
        self.assertIn('cm = "srgb"', last)
        self.assertIn("supports_wide_color = 1, supports_hdr = 1", last)
        self.assertNotIn("max_luminance", last)

    def test_pq_follows_the_headroom_without_hold(self):
        self.layout(4)
        self.run_sync()
        self.assertIn('cm = "hdr"', self.evals()[-1])
        self.assertIn("max_luminance = 812,", self.evals()[-1])
        self.assertIn("sdr_max_luminance = 203", self.evals()[-1])
        # The panel's brightness moves the headroom about once a second: each
        # is sent, none counts towards the hold.
        for i in range(14):
            self.layout(1.5 + i * 0.5)
            r = self.run_sync()
            self.assertNotIn("keeping", r.stderr)
        self.assertEqual(len(self.evals()), 15)
        self.assertIn("max_luminance = 1624,", self.evals()[-1])
        self.run_sync()                      # unchanged: not sent again
        self.assertEqual(len(self.evals()), 15)

    def test_headroom_is_clamped(self):
        self.layout(40)
        self.run_sync()
        self.assertIn("max_luminance = 3248,", self.evals()[-1])
        self.layout("4")                     # not a number: as none
        self.run_sync()
        self.assertIn('cm = "srgb"', self.evals()[-1])

    def test_stock_driver_or_not_asked(self):
        self.layout(4)
        self.status.write_text("stock not built for this kernel\n")
        self.run_sync()
        self.assertNotIn("bitdepth", self.evals()[-1])
        self.status.write_text("omacvm\n")
        self.host_env.write_text("OMACVM_NOTCHPOINTER=1\n")
        self.run_sync()
        self.assertNotIn("bitdepth", self.evals()[-1])

    def test_older_app_hidden_switch(self):
        self.host_env.write_text("OMACVM_HDR=1\n")
        self.run_sync()
        self.assertIn("max_luminance = 1600,", self.evals()[-1])

    # Windows on the PQ output are clipped at max_luminance, not tone-mapped:
    # Chrome draws its whole window in PQ with max 1000 nits, and Hyprland's
    # curve put its SDR white at about half (gray pages).
    CLAMP = 'hl.window_rule({ name = "omacvm-hdr", match = { class = ".*" }, tonemap = "clamp" })'
    DEFAULT = 'hl.window_rule({ name = "omacvm-hdr", match = { class = ".*" }, tonemap = "on" })'

    def window_rules(self) -> list[str]:
        try:
            return (self.hypr / "window_rules").read_text().splitlines()
        except FileNotFoundError:
            return []

    def test_windows_clipped_while_pq(self):
        self.layout(1)
        self.run_sync()
        self.assertEqual(self.window_rules(), [self.CLAMP])
        calls = (self.hypr / "calls").read_text().splitlines()
        self.assertEqual(calls[0], self.CLAMP)          # before the output goes PQ
        self.assertIn('cm = "hdr"', calls[1])
        for edr in (1, 2, 3):                            # the headroom moves: sent once
            self.layout(edr)
            self.run_sync()
        self.assertEqual(self.window_rules(), [self.CLAMP])

    def test_tone_map_back_when_pq_ends(self):
        self.layout(2)
        self.run_sync()
        self.layout(0)                                   # QEMU cannot show PQ now
        self.run_sync()
        self.assertIn('cm = "srgb"', self.evals()[-1])
        self.assertEqual(self.window_rules(), [self.CLAMP, self.DEFAULT])
        self.run_sync()
        self.assertEqual(self.window_rules(), [self.CLAMP, self.DEFAULT])
        self.layout(1.5)                                 # PQ again
        self.run_sync()
        self.assertEqual(self.window_rules(), [self.CLAMP, self.DEFAULT, self.CLAMP])

    def test_no_window_rule_without_pq(self):
        for edr in (None, 0):
            self.layout(edr)
            self.run_sync()
        self.host_env.write_text("")                     # this start did not ask for HDR
        self.layout(2)
        self.run_sync()
        self.assertEqual(self.window_rules(), [])

    def test_refused_window_rule_is_sent_again(self):
        self.layout(2)
        (self.hypr / "refuse-window-rule").write_text("")
        r = self.run_sync()
        self.assertIn("rejected tonemap clamp", r.stderr)
        self.assertIn('cm = "hdr"', self.evals()[-1])    # the output still follows
        r = self.run_sync()                              # tried again, logged once
        self.assertNotIn("rejected", r.stderr)
        (self.hypr / "refuse-window-rule").unlink()
        self.run_sync()
        self.assertEqual(self.window_rules(), [self.CLAMP])
        self.assertFalse((self.state / "tonemap.refused").exists())

    def test_tone_map_held_with_the_output(self):
        self.layout(2)
        self.run_sync()
        sent = len(self.evals())
        (self.state / "Virtual-1.hold").write_text(f"{time.time() + 60}\n")
        self.layout(0)                                   # PQ ends while held
        self.run_sync()
        self.assertEqual(len(self.evals()), sent)
        self.assertEqual(self.window_rules(), [self.CLAMP])
        (self.state / "Virtual-1.hold").unlink()         # the hold ends
        self.run_sync()
        self.assertIn('cm = "srgb"', self.evals()[-1])
        self.assertEqual(self.window_rules(), [self.CLAMP, self.DEFAULT])

    def test_update_into_a_running_pq_output(self):
        # An older display-sync (3.1.25) set the PQ rule and no tone map;
        # Hyprland shows the rule already, so only the window rule is sent.
        self.layout(1)
        self.run_sync()
        sent = len(self.evals())
        (self.state / "tonemap").unlink()
        (self.hypr / "window_rules").unlink()
        self.run_sync()
        self.assertEqual(len(self.evals()), sent)
        self.assertEqual(self.window_rules(), [self.CLAMP])


class Placement(unittest.TestCase):
    """Where the outputs go (output_positions) and in which order the rules
    are sent (apply_order): never one output over another, not even for one
    rule (Hyprland: "Monitor Virtual-2 overlaps with other monitor(s)")."""

    def places(self, layout: list[dict], sizes: dict[str, tuple[int, int, float]]) -> dict:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"layout": layout}, f)
        try:
            args = [f"{n}:{w}:{h}:{s}" for n, (w, h, s) in sizes.items()]
            out = subprocess.run(["python3", "-c", script_python("output_positions"), f.name, *args],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(f.name)
        places = {}
        for line in out.splitlines():
            name, pos = line.split()
            x, y = map(int, pos.split("x"))
            w, h, s = sizes[name]
            places[name] = (x, y, w / s, h / s)
        return places

    def assert_apart(self, places: dict):
        names = sorted(places)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                self.assertFalse(overlap(places[a], places[b]), f"{a} {places[a]} over {b} {places[b]}")

    # The user's MacBook (2026-10-06): built-in 2056x1329 points at 2x, the
    # VM below the camera (38 points), a 6K (3008x1692 points at 2x) above.
    BUILTIN = {"output": "Virtual-1", "x": 0, "y": 38, "width": 2056, "height": 1291, "scale": 2}
    SIXK = {"output": "Virtual-2", "x": -476, "y": -1692, "width": 3008, "height": 1692, "scale": 2}

    def test_macbook_with_6k_above(self):
        p = self.places([self.BUILTIN, self.SIXK],
                        {"Virtual-1": (4112, 2582, 2.0), "Virtual-2": (6016, 3384, 2.0)})
        self.assert_apart(p)
        self.assertEqual(p["Virtual-2"][:2], (0, 0))
        self.assertGreaterEqual(p["Virtual-1"][1], p["Virtual-2"][3], "the built-in below the 6K")
        self.assertEqual(p["Virtual-1"][0], 476)

    def test_zoomed_main_output(self):
        for scale in (1.0, 1.25, 1.6, 2.0, 3.0, 4.0):
            with self.subTest(scale=scale):
                p = self.places([self.BUILTIN, self.SIXK],
                                {"Virtual-1": (4112, 2582, scale), "Virtual-2": (6016, 3384, 2.0)})
                self.assert_apart(p)

    def test_two_externals_above_a_zoomed_main(self):
        # Proportional places above a main output at scale 4 pushed them into each other.
        left = {"output": "Virtual-2", "x": -1000, "y": -1692, "width": 3008, "height": 1692, "scale": 2}
        right = {"output": "Virtual-3", "x": 2008, "y": -1080, "width": 1920, "height": 1080, "scale": 1}
        p = self.places([self.BUILTIN, left, right],
                        {"Virtual-1": (4112, 2582, 4.0), "Virtual-2": (6016, 3384, 2.0),
                         "Virtual-3": (1920, 1080, 1.0)})
        self.assert_apart(p)

    def order(self, shown: list[dict], items: list[str]) -> list[str]:
        out = subprocess.run(["python3", "-c", script_python("apply_order"), json.dumps(shown), *items],
                             capture_output=True, text=True, check=True).stdout
        return out.split()

    SHOWN = [{"name": "Virtual-1", "x": 0, "y": 0, "width": 4112, "height": 2582, "scale": 2.0},
             {"name": "Virtual-2", "x": 2056, "y": 0, "width": 6016, "height": 3384, "scale": 2.0}]

    def test_order_never_overlaps_for_a_moment(self):
        # Hyprland put the 6K at the built-in's right (auto). The built-in goes
        # down under the 6K's new place, the 6K to 0x0: the 6K first would
        # land on the built-in, still at 0x0.
        items = ["Virtual-1:4112:2582:2:476x1730", "Virtual-2:6016:3384:2:0x0"]
        self.assertEqual(self.order(self.SHOWN, items), ["Virtual-1", "Virtual-2"])

    def test_order_moves_the_blocker_first(self):
        shown = json.loads(json.dumps(self.SHOWN))
        shown[1].update(x=0, y=1291)      # the 6K below the built-in now
        # The built-in moves down into the 6K's place; the 6K goes right first.
        items = ["Virtual-1:4112:2582:2:0x500", "Virtual-2:6016:3384:2:2056x0"]
        self.assertEqual(self.order(shown, items), ["Virtual-2", "Virtual-1"])

    def test_a_swap_still_sends_both(self):
        items = ["Virtual-1:4112:2582:2:3008x0", "Virtual-2:6016:3384:2:0x0"]
        self.assertEqual(self.order(self.SHOWN, items), ["Virtual-1", "Virtual-2"])

if __name__ == "__main__":
    unittest.main()
