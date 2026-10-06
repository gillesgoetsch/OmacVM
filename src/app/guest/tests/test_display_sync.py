#!/usr/bin/env python3
"""Tests for omacvm-display-sync, the VM's side of "the screen follows the Mac
window" (no VM needed: a fake DRM folder with QEMU-style EDIDs and a fake
hyprctl that acts like Hyprland).

    python3 src/app/guest/tests/test_display_sync.py

What they hold: the mode and scale sent for 4K and 5K at Omarchy's scales,
nothing sent again while Hyprland already shows it (a resend is a modeset:
the screen flashes and every buffer is made again), the rule kept for config
reloads (omacvm_app.lua declares it again), and the guard that stops
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
    for b in ("/opt/homebrew/bin/bash", "/usr/local/bin/bash", shutil.which("bash")):
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
    with open(os.path.join(state, "evals"), "a") as f:
        f.write(rule + "\n")
    if os.path.exists(os.path.join(state, "refuse")):
        print("error: refused"); raise SystemExit(0)
    out = re.search(r'output = "([^"]+)"', rule)[1]
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

    def test_rule_kept_for_reloads(self):
        # A config reload drops eval'd rules; omacvm_app.lua declares the kept
        # one again, so it must be exactly what Hyprland took, one line.
        self.set_window(5120, 2880)
        self.run_sync()
        kept = (self.state / "Virtual-1.rule").read_text()
        self.assertEqual(kept.splitlines(), [self.evals()[0]])
        self.assertRegex(kept, r'^hl\.monitor\(\{ output = "Virtual-1", [^\n]*\}\)\n$')
        self.set_window(3840, 2160)          # the window changed: the new rule
        self.run_sync()
        self.assertEqual((self.state / "Virtual-1.rule").read_text().strip(), self.evals()[-1])

    def test_rule_kept_when_already_shown(self):
        # A sync from before the rule file existed sent it: the file is written
        # without sending anything again.
        self.set_window(5120, 2880)
        self.run_sync()
        (self.state / "Virtual-1.rule").unlink()
        self.run_sync()
        self.assertEqual(len(self.evals()), 1)
        self.assertEqual((self.state / "Virtual-1.rule").read_text().strip(), self.evals()[0])

    def test_refused_rule_not_kept(self):
        self.set_window(5120, 2880)
        (self.hypr / "refuse").write_text("")
        self.run_sync()
        self.assertFalse((self.state / "Virtual-1.rule").exists())

    def test_users_own_rule_is_left_alone(self):
        self.set_window(5120, 2880)
        self.config.write_text(self.config.read_text() +
                               'hl.monitor({ output = "Virtual-1", mode = "2560x1440", scale = 1 })\n')
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "Virtual-1.rule").write_text('hl.monitor({ output = "Virtual-1", mode = "x" })\n')
        r = self.run_sync()
        self.assertEqual(self.evals(), [])
        self.assertIn("its own rule", r.stderr)
        # a reload must not put the sync's old rule over the user's
        self.assertFalse((self.state / "Virtual-1.rule").exists())


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
        looks = subprocess.run(["pgrep", "-f", f"sleep 61; exec .*{SYNC.name}"],
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


if __name__ == "__main__":
    unittest.main()
