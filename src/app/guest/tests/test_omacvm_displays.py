#!/usr/bin/env python3
"""Tests for omacvm-displays' desktop check (no VM needed).

    python3 src/app/guest/tests/test_omacvm_displays.py
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("omacvm_displays", str(HERE.parent / "omacvm-displays"))
spec = importlib.util.spec_from_loader("omacvm_displays", loader)
od = importlib.util.module_from_spec(spec)
loader.exec_module(od)


def mon(name, x, y, w, h, scale=2.0, **extra):
    m = {"name": name, "x": x, "y": y, "width": w, "height": h, "scale": scale, "transform": 0}
    m.update(extra)
    return m


def layers(**per_output):
    """layers(Virtual_1=[(ns, x, y, w, h), ...]) -> j/layers shape."""
    out = {}
    for key, items in per_output.items():
        name = key.replace("_", "-")
        out[name] = {"levels": {"0": [{"address": "0x1", "x": x, "y": y, "w": w, "h": h,
                                       "namespace": ns, "pid": 1} for ns, x, y, w, h in items],
                                "1": [], "2": [], "3": []}}
    return out


# The user's 2.8.0 test: external 3840x2400 @2 (Virtual-1), MacBook 3456x2160 @2 left of it.
MONS = [mon("Virtual-1", 1728, 0, 3840, 2400), mon("Virtual-2", 0, 0, 3456, 2160),
        mon("NOTCH", 0, 0, 3456, 74)]


class MisplacedWallpapers(unittest.TestCase):
    def test_all_in_place(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1728, 1080)],
                   NOTCH=[("omarchy-background", 0, 0, 1728, 37)])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_left_behind_after_a_move(self):
        # Virtual-2 came up to the right of Virtual-1, then moved to the left.
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 3648, 0, 1728, 1080)])
        self.assertEqual(od.misplaced_wallpapers(MONS, l),
                         ["Virtual-2: wallpaper at 3648,0 1728x1080, display at 0,0 1728x1080"])

    def test_wrong_size(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1024, 768)])
        self.assertEqual(len(od.misplaced_wallpapers(MONS, l)), 1)

    def test_fractional_rounding_is_fine(self):
        mons = [mon("Virtual-1", 0, 0, 3024, 1964, scale=1.6)]  # 1890 x 1227.5
        l = layers(Virtual_1=[("omarchy-background", 0, 0, 1890, 1228)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_no_shell_no_report(self):
        l = layers(Virtual_1=[("omarchy-bar", 1728, 0, 1920, 26)], Virtual_2=[])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_missing_layer_is_left_alone(self):
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)], Virtual_2=[])
        self.assertEqual(od.misplaced_wallpapers(MONS, l), [])

    def test_notch_and_mirrors_ignored(self):
        mons = MONS[:2] + [mon("NOTCH", 0, 0, 3456, 74), mon("Virtual-3", 0, 0, 3456, 2160, mirrorOf="Virtual-2")]
        l = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 0, 0, 1728, 1080)],
                   Virtual_3=[("omarchy-background", 99, 99, 10, 10)],
                   NOTCH=[("omarchy-background", 500, 500, 1, 1)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_disabled_and_rotated(self):
        mons = [mon("Virtual-1", 0, 0, 2400, 3840, transform=1), mon("Virtual-2", 0, 0, 100, 100, disabled=True)]
        l = layers(Virtual_1=[("omarchy-background", 0, 0, 1920, 1200)],
                   Virtual_2=[("omarchy-background", 9, 9, 9, 9)])
        self.assertEqual(od.misplaced_wallpapers(mons, l), [])

    def test_garbage_input(self):
        for m, l in [(None, None), ([], {}), ("x", "y"), ([1, None], {"a": 1}),
                     (MONS, {"Virtual-2": {"levels": {"0": [None, 3]}}})]:
            self.assertEqual(od.misplaced_wallpapers(m, l), [])


def ppm(w, h, pixel):
    return b"P6\n%d %d\n255\n" % (w, h) + bytes(pixel) * (w * h)


def ws(**per_id):
    return [{"id": int(k[1:]), "windows": v} for k, v in per_id.items()]


def active(m, wid, special=0):
    m = dict(m)
    m["activeWorkspace"] = {"id": wid}
    m["specialWorkspace"] = {"id": special}
    return m


class DesktopOutputs(unittest.TestCase):
    L = layers(Virtual_1=[("omarchy-background", 1728, 0, 1920, 1200)],
               Virtual_2=[("omarchy-background", 0, 0, 1728, 1080)],
               NOTCH=[("omarchy-background", 0, 0, 1728, 37)])

    def test_empty_workspaces_with_wallpaper(self):
        mons = [active(MONS[0], 1), active(MONS[1], 11), active(MONS[2], -1337)]
        self.assertEqual(od.desktop_outputs(mons, ws(w1=0, w11=0), self.L), ["Virtual-1", "Virtual-2"])

    def test_windows_special_mirror_and_no_wallpaper_skipped(self):
        mons = [active(MONS[0], 1), active(MONS[1], 11, special=-98),
                active(mon("Virtual-3", 0, 0, 3456, 2160, mirrorOf="Virtual-2"), 12),
                active(mon("Virtual-4", 0, 0, 10, 10), 13)]
        l = dict(self.L, **layers(Virtual_3=[("omarchy-background", 0, 0, 1, 1)]))
        self.assertEqual(od.desktop_outputs(mons, ws(w1=2, w11=0, w12=0, w13=0), l), [])

    def test_garbage(self):
        for m, w, l in [(None, None, None), ([], [], {}), ([1, "x"], "y", {"a": 1}),
                        ([{"name": "Virtual-1", "activeWorkspace": 3}], [], self.L)]:
            self.assertEqual(od.desktop_outputs(m, w, l), [])


class LayoutEvent(unittest.TestCase):
    def test_events(self):
        self.assertTrue(od.layout_event(b"monitoraddedv2>>2,Virtual-2,QEMU\n"))
        self.assertTrue(od.layout_event(b"workspace>>1\nmonitorremoved>>Virtual-2\n"))
        self.assertTrue(od.layout_event(b"configreloaded>>\n"))
        # grim (the desktop check's own screenshots) must not count as a layout change
        self.assertFalse(od.layout_event(b"screencast>>1,monitor\nscreencastv2>>1,monitor,Virtual-1\n"))
        self.assertFalse(od.layout_event(b"focusedmon>>Virtual-1,1\nfocusedmonv2>>Virtual-1,1\n"))


class Shown(unittest.TestCase):
    def test_grey_is_undrawn(self):
        self.assertTrue(od.undrawn(od.ppm_shown(ppm(40, 30, (17, 17, 17)), od.HYPR_GREY)))

    def test_wallpaper_is_drawn(self):
        img = ppm(20, 10, (17, 17, 17))
        mixed = b"P6\n4 20\n255\n" + bytes((17, 17, 17)) * 40 + bytes((90, 140, 200)) * 40
        self.assertFalse(od.undrawn(od.ppm_shown(mixed, od.HYPR_GREY)))
        self.assertTrue(od.undrawn(od.ppm_shown(img, od.HYPR_GREY)))

    def test_flat_other_colour_is_not_undrawn(self):
        # A plain wallpaper or a dark (DPMS off) output is not Hyprland's grey.
        self.assertFalse(od.undrawn(od.ppm_shown(ppm(8, 8, (0, 0, 0)), od.HYPR_GREY)))
        self.assertFalse(od.undrawn(od.ppm_shown(ppm(8, 8, (40, 90, 200)), od.HYPR_GREY)))

    def test_bar_rows_do_not_count(self):
        # A drawn bar at the top over a missing wallpaper is still undrawn.
        img = b"P6\n10 20\n255\n" + bytes((30, 30, 46)) * 20 + bytes((17, 17, 17)) * 180
        self.assertTrue(od.undrawn(od.ppm_shown(img, od.HYPR_GREY)))

    def test_not_ppm(self):
        for data in (b"", b"P5\n1 1\n255\n\0", b"P6\n2 2\n255\n\0", b"garbage"):
            self.assertIsNone(od.ppm_shown(data, od.HYPR_GREY))
            self.assertFalse(od.undrawn(od.ppm_shown(data, od.HYPR_GREY)))

    def test_background_colour(self):
        self.assertEqual(od.background_colour({"int": 0xff202122}), (0x20, 0x21, 0x22))
        self.assertEqual(od.background_colour(None), od.HYPR_GREY)
        self.assertEqual(od.background_colour({"int": "x"}), od.HYPR_GREY)


class Agent(unittest.TestCase):
    """check_desktop: look when due, confirm, restart once, rate-limited, counted on success."""

    def make(self, problems, locked=False, exit_code=0):
        self.problems = problems
        self.locked = locked
        self.exit_code = exit_code
        a = od.Agent.__new__(od.Agent)
        a.looks = []
        a.shell = None
        a.suspect = None
        a.repairs = 0
        a.attempts = 0
        a.repaired_at = -od.REPAIR_EVERY
        a.repair = None
        a.repairing = []
        a.repaired_for = []
        a.said = []
        self.started = []
        self.clock = [1000.0]
        test = self

        class P:
            def __init__(self, argv, **kw):
                test.started.append(argv)
                self.returncode = None

            def poll(self):
                self.returncode = test.exit_code
                return self.returncode
        for target, value in [("undrawn_outputs", lambda: list(self.problems)),
                              ("misplaced_wallpapers", lambda m, l: []),
                              ("hypr_json", lambda c: None),
                              ("screen_locked", lambda: self.locked),
                              ("config_flag", lambda n: True),
                              ("REPAIRS", pathlib.Path("/nonexistent/omacvm-test/shell-repairs"))]:
            patcher = mock.patch.object(od, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for patcher in (mock.patch.object(od.time, "monotonic", lambda: self.clock[0]),
                        mock.patch.object(od.subprocess, "Popen", P)):
            patcher.start()
            self.addCleanup(patcher.stop)
        return a

    def run_for(self, a, seconds, step=1.0):
        end = self.clock[0] + seconds
        while self.clock[0] < end:
            self.clock[0] += step
            a.check_desktop()
            a.repair_done()

    def test_nothing_due_nothing_done(self):
        a = self.make(["Virtual-2"])
        self.run_for(a, 300)
        self.assertEqual(self.started, [])

    def test_confirm_then_restart_once(self):
        a = self.make(["Virtual-2"])
        a.look_in(10)
        self.run_for(a, 12)                       # first sight only
        self.assertEqual(self.started, [])
        self.run_for(a, 6)                        # confirmed 4 s later
        self.assertEqual(self.started, [["omarchy-restart-shell"]])
        self.assertEqual(a.repairs, 1)

    def test_drawn_again_resets(self):
        a = self.make(["Virtual-2"])
        a.look_in(1)
        self.run_for(a, 2)
        self.problems = []
        self.run_for(a, 10)
        self.problems = ["Virtual-2"]
        a.look_in(1)
        self.run_for(a, 2)                        # a new first sight
        self.assertEqual(self.started, [])

    def test_new_shell_is_looked_at(self):
        a = self.make([])
        with mock.patch.object(od, "shell_pid", lambda: 4242):
            a.watch_shell()
        self.assertEqual(len(a.looks), len(od.SHELL_LOOKS))
        with mock.patch.object(od, "shell_pid", lambda: 4242):
            a.watch_shell()                       # same shell: no new looks
        self.assertEqual(len(a.looks), len(od.SHELL_LOOKS))

    def test_layout_burst_one_look(self):
        a = self.make([])
        for _ in range(10):
            self.clock[0] += 0.2
            a.layout_changed()
        self.assertEqual(len(a.looks), 1)

    def test_locked_waits_and_does_not_count(self):
        a = self.make(["Virtual-2"], locked=True)
        a.look_in(1)
        self.run_for(a, 60)
        self.assertEqual(self.started, [])
        self.assertEqual(a.repairs, 0)
        self.locked = False                       # unlocked: the pending look restarts it
        self.run_for(a, 40)
        self.assertEqual(self.started, [["omarchy-restart-shell"]])

    def test_failed_restart_not_counted_but_rate_limited(self):
        a = self.make(["Virtual-2"], exit_code=1)
        a.look_in(1)
        self.run_for(a, 10)
        self.assertEqual(len(self.started), 1)
        self.assertEqual(a.repairs, 0)
        self.assertEqual(a.repaired_for, [])
        for _ in range(20):                       # failing restarts: every 2 min, then stop
            a.look_in(1)
            self.run_for(a, 30)
        self.assertLessEqual(len(self.started), 2 * od.REPAIR_MAX)
        self.assertGreater(len(self.started), 1)

    def test_dpms_off_not_judged(self):
        mons = [dict(active(MONS[0], 1), dpmsStatus=False), dict(active(MONS[1], 11), dpmsStatus=True)]
        self.assertEqual(od.desktop_outputs(mons, ws(w1=0, w11=0), DesktopOutputs.L), ["Virtual-2"])

    def test_same_after_restart_stops(self):
        a = self.make(["Virtual-2"])
        for _ in range(10):
            a.look_in(1)
            self.run_for(a, od.REPAIR_EVERY)
        self.assertEqual(len(self.started), 1)

    def test_good_look_after_repair_allows_another(self):
        a = self.make(["Virtual-2"])
        a.look_in(1)
        self.run_for(a, 10)
        self.assertEqual(len(self.started), 1)    # repaired once
        self.problems = []
        a.look_in(1)
        self.run_for(a, 10)                       # the new shell draws
        self.problems = ["Virtual-2"]             # later the same output goes grey again
        for _ in range(2):                        # (once the 2-minute gap is over)
            a.look_in(1)
            self.run_for(a, od.REPAIR_EVERY)
        self.assertEqual(len(self.started), 2)
        self.assertEqual(a.repairs, 2)

    def test_at_most_three(self):
        a = self.make(["Virtual-2"])
        for i in range(20):
            self.problems = [f"Virtual-{2 + i % 2}"]  # a different display each time
            a.look_in(1)
            self.run_for(a, od.REPAIR_EVERY)
        self.assertEqual(len(self.started), od.REPAIR_MAX)

    def test_switched_off(self):
        a = self.make(["Virtual-2"])
        with mock.patch.object(od, "config_flag", lambda n: n != "repair-shell"):
            for _ in range(5):
                a.look_in(1)
                self.run_for(a, od.REPAIR_EVERY)
        self.assertEqual(self.started, [])


MOVE = "misc:mouse_move_enables_dpms"
KEY = "misc:key_press_enables_dpms"


class FakeHypr:
    """Hyprland's outputs with their DPMS, for Pause, and its two wake options
    (Omarchy turns both on): as Hyprland 0.56.2, a pointer move (or a key) with
    the option on turns EVERY output on while one is off."""

    def __init__(self, *names, off=(), config=None):
        self.dpms = {n: n not in off for n in names}
        self.calls = []
        self.refuse = False
        self.config = dict(config if config is not None else {MOVE: True, KEY: True})
        self.options = dict(self.config)
        self.answer = None        # j/getoption's answer instead of {"bool": value}
        self.puts = []

    def monitors(self):
        return [{"name": n, "dpmsStatus": on} for n, on in self.dpms.items()]

    def set(self, name, on):
        self.calls.append((name, on))
        if self.refuse or name not in self.dpms:
            return False
        self.dpms[name] = on
        return True

    def get(self, name):
        return self.answer if self.answer is not None else self.options.get(name)

    def put(self, name, on):
        self.puts.append((name, on))
        if self.refuse:
            return False
        self.options[name] = on
        return True

    def move(self, option=MOVE):
        """A pointer move (or with KEY a key press) anywhere."""
        if self.options.get(option) and not all(self.dpms.values()):
            self.dpms = dict.fromkeys(self.dpms, True)

    def reload(self, **config):
        """hyprctl reload / a theme switch: the config's values again."""
        self.config.update({MOVE if k == "move" else KEY: v for k, v in config.items()})
        self.options = dict(self.config)


class PauseCase(unittest.TestCase):
    """A Pause on a FakeHypr, its files in a temporary folder."""

    def make(self, *names, off=(), config=None):
        self.h = FakeHypr(*names, off=off, config=config)
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.path = self.tmp / "omacvm/paused-displays"
        self.wake = self.tmp / "omacvm/paused-wake"
        self.t = [1000.0]
        # (an agent without the guard: the same tests show what it does)
        extra = {"guard": self.guard()} if hasattr(od, "WakeGuard") else {}
        p = od.Pause(set_dpms=self.h.set, monitors=self.h.monitors, path=self.path, clock=lambda: self.t[0],
                     **extra)
        patcher = mock.patch.object(od, "log", lambda m: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.t[0] += od.CAST_SETTLE   # past the start's share settle
        return p

    def guard(self):
        return od.WakeGuard(get=self.h.get, put=self.h.put, path=self.wake)


class PauseTest(PauseCase):
    """Pause drawing while hidden: the Mac's "unseen" list -> DPMS of those outputs."""

    def test_unseen_off_seen_on(self):
        p = self.make("Virtual-1", "NOTCH")
        p.mac(["Virtual-1"])
        p.apply()
        self.assertEqual(self.h.dpms, {"Virtual-1": False, "NOTCH": True})
        self.assertEqual(json.loads(self.path.read_text()), ["Virtual-1"])
        p.mac([])
        p.apply()
        self.assertEqual(self.h.dpms, {"Virtual-1": True, "NOTCH": True})
        self.assertFalse(self.path.exists())

    def test_only_mac_outputs_and_only_known_ones(self):
        # Not a Virtual-N name: never touched; an output Hyprland does not have: no call at all
        # (Hyprland's dpms with an unknown monitor would turn every display off).
        p = self.make("Virtual-1", "NOTCH")
        p.mac(["NOTCH", "Virtual-2", 3, None, 'Virtual-1" })'])
        p.apply()
        self.assertEqual(self.h.calls, [])
        self.assertEqual(self.h.dpms, {"Virtual-1": True, "NOTCH": True})

    def test_the_guests_own_dpms_off_is_left_alone(self):
        # Omarchy's idle turned the display off before: the agent did not, so it never turns it on.
        p = self.make("Virtual-1", off=("Virtual-1",))
        p.mac(["Virtual-1"])
        p.apply()
        p.mac([])
        p.apply()
        self.assertEqual(self.h.calls, [])
        self.assertFalse(self.h.dpms["Virtual-1"])

    def test_turned_on_by_someone_else_while_unseen_goes_off_again(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.dpms["Virtual-1"] = True        # a key press (key_press_enables_dpms)
        p.apply()                              # the next look
        self.assertFalse(self.h.dpms["Virtual-1"])
        p.mac([])
        p.apply()
        self.assertTrue(self.h.dpms["Virtual-1"])

    def test_seen_again_after_someone_turned_it_on(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.dpms["Virtual-1"] = True
        p.mac([])
        p.apply()
        self.assertEqual(self.h.calls, [("Virtual-1", False)])
        self.assertEqual(p.paused, set())

    def test_a_share_of_the_output_keeps_it_drawing(self):
        p = self.make("Virtual-1", "Virtual-2")
        for on, kind, name in od.screencasts(b"screencast>>1,monitor\nscreencastv2>>1,monitor,Virtual-1\n"):
            p.cast(on, kind, name)
        p.mac(["Virtual-1", "Virtual-2"])
        p.apply()
        self.assertEqual(self.h.dpms, {"Virtual-1": True, "Virtual-2": False})
        for on, kind, name in od.screencasts(b"screencastv2>>0,monitor,Virtual-1\n"):
            p.cast(on, kind, name)
        p.apply()
        self.assertEqual(self.h.dpms, {"Virtual-1": False, "Virtual-2": False})

    def test_a_share_starting_while_paused_turns_it_on(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        p.cast(True, "monitor", "Virtual-1")
        p.apply()
        self.assertTrue(self.h.dpms["Virtual-1"])

    def test_a_window_share_keeps_every_output_drawing(self):
        p = self.make("Virtual-1", "Virtual-2")
        p.cast(True, "window", "5a3b1c")
        p.mac(["Virtual-1", "Virtual-2"])
        p.apply()
        self.assertEqual(self.h.calls, [])
        p.cast(False, "window", "5a3b1c")
        p.apply()
        self.assertEqual(self.h.dpms, {"Virtual-1": False, "Virtual-2": False})

    def test_shares_lost_with_the_event_socket(self):
        # The share's end may be lost with the socket: forgotten, but nothing goes off for CAST_SETTLE
        # (a share that runs on announces nothing new).
        p = self.make("Virtual-1")
        p.cast(True, "monitor", "Virtual-1")
        p.casts_lost()
        p.mac(["Virtual-1"])
        p.apply()
        self.assertTrue(self.h.dpms["Virtual-1"])
        self.t[0] += od.CAST_SETTLE
        p.apply()
        self.assertFalse(self.h.dpms["Virtual-1"])

    def test_nothing_off_right_after_a_start(self):
        h = FakeHypr("Virtual-1")
        t = [50.0]
        p = od.Pause(set_dpms=h.set, monitors=h.monitors, path=pathlib.Path("/nonexistent/omacvm-test/p"),
                     clock=lambda: t[0])
        with mock.patch.object(od, "log", lambda m: None):
            p.mac(["Virtual-1"])
            p.apply()
            self.assertTrue(h.dpms["Virtual-1"])
            self.assertEqual(p.due_at(), 50.0 + od.CAST_SETTLE)
            t[0] += od.CAST_SETTLE
            p.tick()
        self.assertFalse(h.dpms["Virtual-1"])

    def test_the_lease_runs_out(self):
        # The Mac says "unseen" again every 5 s; a lost "seen" (or a QEMU gone) must not leave it dark.
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        self.assertEqual(p.due_at(), self.t[0] + od.LEASE)
        self.t[0] += od.LEASE - 1
        p.mac(["Virtual-1"])           # renewed
        self.t[0] += od.LEASE - 1
        p.tick()
        self.assertFalse(self.h.dpms["Virtual-1"])
        self.t[0] += 2
        p.tick()
        self.assertTrue(self.h.dpms["Virtual-1"])
        self.assertEqual(p.unseen, set())
        self.assertIsNone(p.due_at())

    def test_the_agent_says_it_can_pause(self):
        with mock.patch("sys.stdout", new_callable=__import__("io").StringIO) as out, \
             mock.patch.object(od, "PAUSED", pathlib.Path("/nonexistent/omacvm-test/paused")), \
             mock.patch.object(od, "WAKE", pathlib.Path("/nonexistent/omacvm-test/wake")):
            self.assertEqual(od.main(["omacvm-displays", "pause"]), 0)
        self.assertEqual(json.loads(out.getvalue()), {"able": True, "paused": [], "wake_off": []})
        src = (HERE.parent / "omacvm-displays").read_text()
        self.assertEqual(src.count('self.send({"hello": 1, "external": self.external, "pause": 1})'), 2)

    def test_screenshots_count_up_and_down(self):
        p = self.make("Virtual-1")
        p.cast(True, "monitor", "Virtual-1")
        p.cast(True, "monitor", "Virtual-1")
        p.cast(False, "monitor", "Virtual-1")
        self.assertIn(("monitor", "Virtual-1"), p.casts)
        p.cast(False, "monitor", "Virtual-1")
        p.cast(False, "monitor", "Virtual-1")   # an end without a start: not below zero
        self.assertEqual(p.casts, {})

    def test_a_restarted_agent_turns_its_displays_on(self):
        p = self.make("Virtual-1", "Virtual-2")
        p.mac(["Virtual-1"])
        p.apply()
        q = od.Pause(set_dpms=self.h.set, monitors=self.h.monitors, path=self.path, guard=self.guard())
        q.restore()
        self.assertTrue(self.h.dpms["Virtual-1"])
        self.assertFalse(self.path.exists())

    def test_refused_turn_on_is_tried_again(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.refuse = True
        p.mac([])
        p.apply()
        self.assertEqual(p.paused, {"Virtual-1"})
        self.h.refuse = False
        p.apply()
        self.assertTrue(self.h.dpms["Virtual-1"])
        self.assertEqual(p.paused, set())

    def test_no_hyprland_nothing_happens(self):
        p = od.Pause(set_dpms=lambda n, o: self.fail("called"), monitors=lambda: None,
                     path=pathlib.Path("/nonexistent/omacvm-test/paused"))
        p.mac(["Virtual-1"])
        p.apply()

    def test_the_agent_takes_the_message(self):
        a = od.Agent.__new__(od.Agent)
        a.pause = mock.Mock()
        with mock.patch.object(od, "write_state") as ws, mock.patch.object(od, "run_sync") as rs:
            a.on_line(b'{"unseen": ["Virtual-1"]}')
        a.pause.mac.assert_called_once_with(["Virtual-1"])
        a.pause.apply.assert_called_once_with()
        ws.assert_not_called()
        rs.assert_not_called()


class WakeGuardTest(PauseCase):
    """While the agent holds a display off, Hyprland's wake on moves and keys
    is off (the user's 2026-10-28 two-display case: every move on the LG woke
    the paused built-in output, the Mac's next "unseen" turned it off again)."""

    def test_a_move_on_another_display_leaves_the_paused_one_off(self):
        p = self.make("Virtual-1", "Virtual-2")
        p.mac(["Virtual-1"])
        p.apply()
        for _ in range(10):
            self.h.move()
            self.h.move(KEY)
            self.assertFalse(self.h.dpms["Virtual-1"])
            self.assertTrue(self.h.dpms["Virtual-2"])
            self.t[0] += 5
            p.mac(["Virtual-1"])        # the Mac's lease
            p.apply()
        self.assertEqual(self.h.calls, [("Virtual-1", False)])   # one turn off, no fight
        self.assertEqual(json.loads(self.wake.read_text()), {MOVE: True, KEY: True})

    def test_options_back_as_found_when_seen_again(self):
        # The person's own choice (key presses do not wake) stays theirs.
        p = self.make("Virtual-1", "Virtual-2", config={MOVE: True, KEY: False})
        p.mac(["Virtual-1"])
        p.apply()
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})
        self.assertEqual(self.h.puts, [(MOVE, False)])
        p.mac([])
        p.apply()
        self.assertTrue(self.h.dpms["Virtual-1"])
        self.assertEqual(self.h.options, {MOVE: True, KEY: False})
        self.assertFalse(self.wake.exists())
        self.h.move()   # back to Hyprland's normal: a move wakes displays again
        self.assertEqual(self.h.puts, [(MOVE, False), (MOVE, True)])

    def test_both_off_already_nothing_touched(self):
        p = self.make("Virtual-1", config={MOVE: False, KEY: False})
        p.mac(["Virtual-1"])
        p.apply()
        p.mac([])
        p.apply()
        self.assertEqual(self.h.puts, [])
        self.assertFalse(self.wake.exists())

    def test_an_unknown_answer_touches_nothing(self):
        p = self.make("Virtual-1")
        self.h.answer = "yes"
        p.mac(["Virtual-1"])
        p.apply()
        self.assertFalse(self.h.dpms["Virtual-1"])
        self.assertEqual(self.h.puts, [])

    def test_a_config_reload_turns_them_off_again(self):
        # A theme switch reloads Omarchy's config: its true is back.
        p = self.make("Virtual-1", "Virtual-2")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.reload()
        self.assertTrue(self.h.options[MOVE])
        p.guard.recheck()
        p.apply()
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})
        self.h.move()
        self.assertFalse(self.h.dpms["Virtual-1"])
        p.mac([])
        p.apply()
        self.assertEqual(self.h.options, {MOVE: True, KEY: True})

    def test_a_reload_that_turns_one_off_is_not_undone(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.reload(key=False)       # the person turned key wake off in their config
        p.guard.recheck()
        p.apply()
        p.mac([])
        p.apply()
        self.assertEqual(self.h.options, {MOVE: True, KEY: False})

    def test_a_restarted_agent_puts_them_back(self):
        p = self.make("Virtual-1", "Virtual-2")
        p.mac(["Virtual-1"])
        p.apply()
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})
        q = od.Pause(set_dpms=self.h.set, monitors=self.h.monitors, path=self.path, guard=self.guard())
        q.restore()
        self.assertEqual(self.h.options, {MOVE: True, KEY: True})
        self.assertFalse(self.wake.exists())
        self.assertTrue(self.h.dpms["Virtual-1"])

    def test_not_taken_now_tried_again(self):
        p = self.make("Virtual-1")
        self.h.refuse = True
        p.mac(["Virtual-1"])
        p.apply()                      # DPMS refused too: nothing paused, nothing held
        self.h.refuse = False
        p.apply()
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})
        self.h.refuse = True
        p.mac([])
        p.apply()                      # the put back refused: kept, the agent stays busy
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})
        self.assertTrue(p.busy())
        self.h.refuse = False
        p.apply()
        self.assertEqual(self.h.options, {MOVE: True, KEY: True})
        self.assertFalse(p.busy())

    def test_the_guests_idle_on_another_display_gets_its_wake(self):
        # Omarchy's idle turned the LG's output off too: a move must wake it as usual.
        p = self.make("Virtual-1", "Virtual-2")
        p.mac(["Virtual-1"])
        p.apply()
        self.h.dpms["Virtual-2"] = False
        self.t[0] += 5
        p.mac(["Virtual-1"])
        p.apply()
        self.assertEqual(self.h.options, {MOVE: True, KEY: True})
        self.h.move()                  # the person is back: everything on
        self.assertTrue(self.h.dpms["Virtual-2"])
        p.apply()                      # the next look: the paused one off again, held again
        self.assertFalse(self.h.dpms["Virtual-1"])
        self.assertEqual(self.h.options, {MOVE: False, KEY: False})

    def test_the_agent_shows_what_it_holds(self):
        p = self.make("Virtual-1")
        p.mac(["Virtual-1"])
        p.apply()
        with mock.patch("sys.stdout", new_callable=__import__("io").StringIO) as out, \
             mock.patch.object(od, "PAUSED", self.path), mock.patch.object(od, "WAKE", self.wake):
            self.assertEqual(od.main(["omacvm-displays", "pause"]), 0)
        self.assertEqual(json.loads(out.getvalue()),
                         {"able": True, "paused": ["Virtual-1"], "wake_off": [KEY, MOVE]})

    def test_getoption_bool_and_int(self):
        for answer, value in (({"option": MOVE, "bool": True, "set": True}, True), ({"bool": False}, False),
                              ({"int": 1}, True), ({"int": 0}, False), ({"int": 2}, None),
                              ({"str": "1"}, None), ({"bool": "yes"}, None), (None, None), ([], None)):
            with mock.patch.object(od, "hypr_json", lambda c, a=answer: a):
                self.assertIs(od.hypr_bool(MOVE), value, answer)

    def test_set_through_hyprlands_lua(self):
        sent = []
        with mock.patch.object(od, "hypr_request", lambda c: sent.append(c) or "ok"), \
             mock.patch.object(od, "hypr_json", lambda c: {"bool": False}):
            self.assertTrue(od.set_hypr_bool(MOVE, False))
            self.assertFalse(od.set_hypr_bool(KEY, True))    # Hyprland still says false
            self.assertFalse(od.set_hypr_bool("misc:x }) os.exit(", False))
        self.assertEqual(sent, ["eval hl.config({ misc = { mouse_move_enables_dpms = false } })",
                                "eval hl.config({ misc = { key_press_enables_dpms = true } })"])

    def test_the_agent_hears_a_reload(self):
        a = od.Agent.__new__(od.Agent)
        a.pause = mock.Mock()
        a.pause.busy.return_value = True
        with mock.patch.object(od.Agent, "layout_changed"), mock.patch.object(od.Agent, "soon"):
            a.on_events(b"activewindow>>x,y\nconfigreloaded>>\n")
        a.pause.guard.recheck.assert_called_once_with()
        a.pause.apply.assert_called_once_with()


class Idle(unittest.TestCase):
    """The agent sleeps until something is due: no once-a-second wake-up."""

    def agent(self, events=True, watch_ok=True):
        a = od.Agent.__new__(od.Agent)
        a.events = object() if events else None
        a.check_at = 0.0
        a.last_check = 1000.0
        a.last_report = 1000.0
        a.follow_until = 0.0
        a.looks = []
        a.repair = None
        a.config_watch = mock.Mock(ok=watch_ok)
        return a

    def test_idle_sleeps_until_the_layout_compare(self):
        self.assertEqual(self.agent().timeout(1000.0), od.REPORT_EVERY)
        self.assertEqual(self.agent().timeout(1004.0), od.REPORT_EVERY - 4)
        self.assertGreater(od.REPORT_EVERY, 5.0)   # no frequent wake-up on an idle desktop

    def test_following_a_change_twice_a_second(self):
        a = self.agent()
        a.follow_until = 1000.0 + od.FOLLOW
        self.assertEqual(a.timeout(1000.0), od.FOLLOW_EVERY)
        a.last_report = 1000.0 + od.FOLLOW                   # the last compare while following
        self.assertEqual(a.timeout(1000.0 + od.FOLLOW + 1), od.REPORT_EVERY - 1)

    def test_without_hyprland_events_more_often(self):
        self.assertEqual(self.agent(events=False).timeout(1000.0), od.SAFETY_WITHOUT_EVENTS)

    def test_due_check_and_looks_come_first(self):
        a = self.agent()
        a.check_at = 1000.3
        self.assertAlmostEqual(a.timeout(1000.0), 0.3)
        a = self.agent()
        a.looks = [1012.0, 1004.0]
        self.assertEqual(a.timeout(1000.0), 4.0)

    def test_overdue_is_zero(self):
        a = self.agent()
        a.looks = [990.0]
        self.assertEqual(a.timeout(1000.0), 0.0)

    def test_once_a_second_while_needed(self):
        self.assertEqual(self.agent(watch_ok=False).timeout(1000.0), 1.0)   # no inotify
        a = self.agent()
        a.repair = object()                                                  # a shell restart runs
        self.assertEqual(a.timeout(1000.0), 1.0)

    def test_shell_event(self):
        self.assertTrue(od.shell_event(b"activewindow>>a,b\nopenlayer>>omarchy-background\n"))
        self.assertFalse(od.shell_event(b"closelayer>>notifications\nworkspace>>2\n"))
        self.assertFalse(od.layout_event(b"openlayer>>omarchy-background\n"))


class StaleLayout(unittest.TestCase):
    """The Air, 3.0.0: a config reload moved Virtual-1 "auto" right of NOTCH,
    then display-sync and Omanotch moved them back with hyprctl eval (no
    socket2 event). The agent's report from the middle of that stayed for
    30 s, and QEMU kept the pointer in the left half of the screen."""

    MID = [{"name": "NOTCH", "x": 1470, "y": -33, "width": 1470.0, "height": 33.0},
           {"name": "Virtual-1", "x": 0, "y": 0, "width": 1470.0, "height": 923.0}]
    BACK = [{"name": "NOTCH", "x": 0, "y": -33, "width": 1470.0, "height": 33.0},
            {"name": "Virtual-1", "x": 0, "y": 0, "width": 1470.0, "height": 923.0}]

    def setUp(self):
        self.clock = [1000.0]
        self.layout = list(self.MID)
        self.sent = []
        a = od.Agent.__new__(od.Agent)
        a.events = object()
        a.check_at = 0.0
        a.last_check = 0.0
        a.last_report = 0.0
        a.follow_until = 0.0
        a.reported = None
        a.looks = []
        a.suspect = None
        a.repair = None
        a.config_watch = mock.Mock(ok=True)
        a.send = self.sent.append
        a.watch_shell = lambda: None
        a.check_desktop = lambda: None
        self.agent = a
        for patcher in (mock.patch.object(od.time, "monotonic", lambda: self.clock[0]),
                        mock.patch.object(od, "monitors", lambda: list(self.layout))):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_until(self, end):
        """The agent's loop without select: sleep its timeout, do what is due."""
        while self.clock[0] < end:
            self.clock[0] = min(end, self.clock[0] + max(self.agent.timeout(self.clock[0]), 0.01))
            self.agent.due()

    def reported_at(self, layout, start, limit):
        while self.clock[0] < start + limit:
            self.run_until(self.clock[0] + 0.05)
            if self.sent and self.sent[-1] == {"monitors": layout}:
                return self.clock[0] - start
        return None

    def test_move_after_a_restart_mid_reload(self):
        # The agent restarts and reports the passing layout at once ...
        self.agent.follow()
        self.agent.due()
        self.assertEqual(self.sent, [{"monitors": self.MID}])
        # ... then NOTCH moves back with no event: reported within a second.
        self.run_until(1000.4)
        self.layout = list(self.BACK)
        took = self.reported_at(self.BACK, 1000.4, 2.0)
        self.assertIsNotNone(took)
        self.assertLessEqual(took, od.FOLLOW_EVERY + 0.06)

    def test_move_after_a_reload_event(self):
        self.agent.due()
        self.run_until(1020.0)
        self.agent.layout_changed()          # socket2 configreloaded
        self.agent.soon(0.3)
        self.run_until(1022.0)
        self.layout = list(self.BACK)        # moved back 2 s later, no event
        took = self.reported_at(self.BACK, 1022.0, 2.0)
        self.assertIsNotNone(took)
        self.assertLessEqual(took, od.FOLLOW_EVERY + 0.06)

    def test_move_on_an_idle_desktop_is_reported_too(self):
        self.agent.due()
        self.run_until(1100.0)               # long after any change
        sends = len(self.sent)
        self.layout = list(self.BACK)
        took = self.reported_at(self.BACK, 1100.0, od.REPORT_EVERY + 1)
        self.assertIsNotNone(took)
        self.assertLessEqual(took, od.REPORT_EVERY + 0.06)
        self.assertEqual(len(self.sent), sends + 1)

    def test_same_layout_sends_nothing(self):
        self.agent.follow()
        self.run_until(1060.0)
        self.assertEqual(self.sent, [{"monitors": self.MID}])


class PokeTest(unittest.TestCase):
    def test_poke_wakes_the_agent(self):
        import select
        import tempfile
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            path = pathlib.Path(tmp) / "omacvm" / "displays.poke"
            od.poke(path)                                # no agent: nothing happens
            p = od.Poke(path)
            self.addCleanup(p.close)
            self.assertTrue(p.ok)
            self.assertEqual(select.select([p], [], [], 0)[0], [])
            self.assertFalse(p.drain())
            od.poke(path)
            od.poke(path)
            self.assertEqual(select.select([p], [], [], 1)[0], [p])
            self.assertTrue(p.drain())                   # both read at once
            self.assertEqual(select.select([p], [], [], 0)[0], [])
            p2 = od.Poke(path)                           # a restarted agent takes the path over
            self.addCleanup(p2.close)
            self.assertTrue(p2.ok)
            od.poke(path)
            self.assertEqual(select.select([p2], [], [], 1)[0], [p2])

    def test_lua_hook_pokes(self):
        lua = (HERE.parent / "omacvm_app.lua").read_text()
        self.assertIn('hl.on("monitor.layout_changed"', lua)
        self.assertIn("/usr/local/bin/omacvm-displays poke", lua)


class RefreshWidget(unittest.TestCase):
    def test_installer_rewriting_the_widget_does_not_stop_the_agent(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            widget = tmp / "omacvm.monitor"
            widget.mkdir()
            (widget / ".source-sha256").mkdir()          # read_text fails like a file gone midway
            build = tmp / "build.py"
            build.write_text("")
            panel = tmp / "Panel.qml"
            panel.write_text("x")
            with mock.patch.object(od, "WIDGET", widget), mock.patch.object(od, "WIDGET_BUILD", build), \
                    mock.patch.object(od, "OMARCHY_PANEL", panel), \
                    mock.patch.object(od.subprocess, "run") as run, mock.patch.object(od, "log"):
                od.refresh_widget()
                run.assert_not_called()

    @staticmethod
    def stale(tmp):
        """A widget built from an older Omarchy panel: (widget, build, panel)."""
        widget = tmp / "omacvm.monitor"
        widget.mkdir()
        (widget / ".source-sha256").write_text("old\n")
        build = tmp / "build.py"
        build.write_text("")
        panel = tmp / "Panel.qml"
        panel.write_text("x")
        return widget, build, panel

    def refresh(self, states):
        """refresh_widget with the session in these states, one per look: the commands run."""
        with tempfile.TemporaryDirectory() as tmp:
            widget, build, panel = self.stale(pathlib.Path(tmp))
            with mock.patch.object(od, "WIDGET", widget), mock.patch.object(od, "WIDGET_BUILD", build), \
                    mock.patch.object(od, "OMARCHY_PANEL", panel), \
                    mock.patch.object(od, "session_state", side_effect=states), \
                    mock.patch.object(od.time, "sleep"), \
                    mock.patch.object(od.subprocess, "run") as run, mock.patch.object(od, "log"):
                od.refresh_widget()
                return [c.args[0] for c in run.call_args_list]

    def test_not_while_the_session_is_locked(self):
        # A write in the plugins folder or a rescan would reload Omarchy's
        # lock screen without its password field (omarchy-mac 4.0.3).
        self.assertEqual(self.refresh(["locked"]), [])
        self.assertEqual(self.refresh(["busy"] * 21), [])          # never answered in 20 s

    def test_open_no_shell_or_a_shell_that_answers_in_time(self):
        for states in (["open"], ["down"], ["busy", "busy", "open"]):
            ran = self.refresh(states)
            self.assertEqual(len(ran), 2, states)
            self.assertEqual(ran[1], ["omarchy-shell", "-q", "shell", "rescanPlugins"])

    def test_session_state_reads_session_lock_sh(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = pathlib.Path(tmp) / "session-lock.sh"
            with mock.patch.object(od, "SESSION_LOCK", script):
                self.assertEqual(od.session_state(), "open")         # not there: as before
                script.write_text("echo locked\n")
                self.assertEqual(od.session_state(), "locked")
                script.write_text("echo something else\n")
                self.assertEqual(od.session_state(), "open")


class ConfigWatchTest(unittest.TestCase):
    def test_wakes_on_a_change_or_falls_back(self):
        import select
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp) / "omacvm"
            w = od.ConfigWatch(folder)
            self.assertTrue(folder.is_dir())
            if not w.ok:
                # The guest is Linux: there a missing watch is a bug (CI runs
                # this on Linux too). Elsewhere the agent's fallback is all there is.
                self.assertNotEqual(sys.platform, "linux", "no inotify watch on Linux")
                self.skipTest("no inotify here (the agent looks once a second)")
            self.assertEqual(select.select([w], [], [], 0)[0], [])
            conf = folder / "displays.conf"
            tmpfile = folder / "displays.tmp"
            tmpfile.write_text("external=off\n")
            tmpfile.replace(conf)                       # what set_external does
            self.assertEqual(select.select([w], [], [], 1)[0], [w])
            w.drain()
            self.assertTrue(w.ok)
            self.assertEqual(select.select([w], [], [], 0)[0], [])
            conf.unlink()
            folder.rmdir()                              # the folder gone: the watch ends
            select.select([w], [], [], 1)
            w.drain()
            self.assertFalse(w.ok)


class Scale(unittest.TestCase):
    """#355: every scale in "Full screen including notch". The agent tells the
    Mac the scale the main output wants; `scale` asks the Mac for a size that
    fits before Omarchy sets it."""

    def setUp(self):
        import tempfile
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, self.tmp)
        self.lua = self.tmp / "monitors.lua"
        self.env = self.tmp / "host.env"
        self.builtin = self.tmp / "builtin"
        for target, value in [("CONFIG", self.tmp / "displays.conf"), ("MONITORS_LUA", self.lua), ("HOST_ENV", self.env), ("BUILTIN", self.builtin)]:
            patcher = mock.patch.object(od, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_wanted_scale(self):
        self.assertIsNone(od.wanted_scale())                          # no monitors.lua
        self.lua.write_text("local omarchy_monitor_scale = 1.6\nlocal omarchy_gdk_scale = 2\n")
        self.assertEqual(od.wanted_scale(), 1.6)
        self.lua.write_text("local omarchy_monitor_scale = 1.666667 -- clean\n")
        self.assertEqual(od.wanted_scale(), 1.666667)
        self.lua.write_text('local omarchy_monitor_scale = "auto"\n')
        self.assertIsNone(od.wanted_scale())
        self.lua.write_text("local omarchy_monitor_scale = 6\n")
        self.assertIsNone(od.wanted_scale())                          # out of 1-4

    def test_fullpanel_output(self):
        self.assertIsNone(od.fullpanel_output())                      # no host.env
        self.env.write_text("OMACVM_SCREEN=2940x1912\n")
        self.assertIsNone(od.fullpanel_output())                      # a normal start
        self.env.write_text("OMACVM_FULLPANEL=645.5x824.5x34x1470x956\n")
        self.assertEqual(od.fullpanel_output(), "Virtual-1")
        self.builtin.write_text("Virtual-2\n")
        self.assertEqual(od.fullpanel_output(), "Virtual-2")

    def test_fits(self):
        self.assertTrue(od.scale_fits(2944, 1912, 1.6))               # the 13" Air at 1.6
        self.assertFalse(od.scale_fits(2940, 1912, 1.6))              # its panel: not
        self.assertTrue(od.scale_fits(2940, 1915, 1.25))
        self.assertTrue(od.scale_fits(2940, 1912, 2))
        self.assertFalse(od.scale_fits(2940, 1912, 1.25))

    def agent(self):
        sent = []
        a = od.Agent.__new__(od.Agent)
        a.send = sent.append
        a.scale = None
        a.layout_changed = mock.Mock()
        a.soon = mock.Mock()
        return a, sent

    def test_agent_tells_the_mac(self):
        a, sent = self.agent()
        a.lua_scale = None
        a.lua_changed()
        self.assertEqual(sent, [])                                    # automatic: nothing
        self.lua.write_text("local omarchy_monitor_scale = 2\n")
        a.lua_changed()
        a.lua_changed()
        self.assertEqual(sent, [{"scale": 2.0}])                      # once
        a.on_poke([b"scale 1.6"])
        self.assertEqual(sent[-1], {"scale": 1.6})                    # picked: at once
        a.layout_changed.assert_not_called()
        a.on_poke([b"scale 9", b"scale x"])
        self.assertEqual(len(sent), 2)                                # nonsense: nothing
        a.on_poke([b"layout"])
        a.layout_changed.assert_called_once()

    def test_a_picked_scale_is_not_undone_by_the_old_file(self):
        # The MacBook Air, 2026-10-12: 1.25 picked while monitors.lua still said 1.6;
        # the next report sent 1.6 again and the Mac went back to 1.6's size.
        a, sent = self.agent()
        a.lua_scale = None
        self.lua.write_text("local omarchy_monitor_scale = 1.6\n")
        a.lua_changed()
        a.on_poke([b"scale 1.25"])
        a.lua_changed()                                               # the report, the file not written yet
        self.assertEqual(sent, [{"scale": 1.6}, {"scale": 1.25}])
        self.lua.write_text("local omarchy_monitor_scale = 1.25\n")  # Omarchy's command wrote it
        a.lua_changed()
        self.assertEqual(sent, [{"scale": 1.6}, {"scale": 1.25}])     # the same: nothing more
        self.lua.write_text("local omarchy_monitor_scale = 2\n")     # changed in the file (a key binding)
        a.lua_changed()
        self.assertEqual(sent[-1], {"scale": 2.0})

    def set_scale(self, sizes, fullpanel=True, focused="Virtual-1", value="1.6"):
        """set_scale with the focused output's sizes one after the other (the Mac's change)."""
        if fullpanel:
            self.env.write_text("OMACVM_FULLPANEL=645.5x824.5x34x1470x956\n")
        sizes = list(sizes)
        pokes, calls = [], []

        def monitors(cmd):
            w, h = sizes.pop(0) if len(sizes) > 1 else sizes[0]
            return [{"name": focused, "focused": True, "width": w, "height": h}]
        with mock.patch.object(od, "hypr_json", monitors), \
             mock.patch.object(od, "poke", lambda path=None, message=b"": pokes.append(message)), \
             mock.patch.object(od.subprocess, "call", lambda argv: calls.append(argv) or 0), \
             mock.patch.object(od.time, "sleep", lambda s: None), mock.patch("sys.stderr"):
            rc = od.set_scale(value, wait=0.5)
        return rc, pokes, calls

    def test_scale_in_fullpanel(self):
        rc, pokes, calls = self.set_scale([(2940, 1912), (2940, 1912), (2944, 1912)])
        self.assertEqual((rc, pokes), (0, [b"scale 1.6\n"]))
        self.assertEqual(calls, [["omarchy-hyprland-monitor-scaling", "1.6"]])   # once the size fits

    def test_scale_elsewhere_is_omarchys(self):
        rc, pokes, calls = self.set_scale([(2940, 1840)], fullpanel=False)
        self.assertEqual((pokes, calls), ([], [["omarchy-hyprland-monitor-scaling", "1.6"]]))
        rc, pokes, calls = self.set_scale([(3840, 2160)], focused="Virtual-2")   # an external display
        self.assertEqual(pokes, [])

    def test_scale_old_mac_falls_back(self):
        # An OmacVM.app without #355 never changes the size: Omarchy's nearest after the wait.
        rc, pokes, calls = self.set_scale([(2940, 1912)])
        self.assertEqual(calls, [["omarchy-hyprland-monitor-scaling", "1.6"]])

    def test_secondary_choice_is_saved_without_changing_global_scale(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            config = pathlib.Path(d) / "displays.conf"
            self.lua.write_text("local omarchy_monitor_scale = 1.6\n")
            with mock.patch.object(od, "CONFIG", config):
                rc, pokes, calls = self.set_scale([(1920, 2160)], fullpanel=False,
                                                 focused="Virtual-2", value="1.25")
            self.assertEqual(rc, 0)
            self.assertEqual(calls, [[od.SYNC, "--once"]])
            self.assertEqual((config.parent / "scales/Virtual-2").read_text(), "1.25\n")
            self.assertEqual(self.lua.read_text(), "local omarchy_monitor_scale = 1.6\n")
            self.assertEqual(pokes, [])

    def test_secondary_clean_scale_above_last_preset(self):
        # Omarchy's panel can round its 4x preset up to a clean 5x.
        rc, _, calls = self.set_scale([(2940, 1915)], fullpanel=False,
                                      focused="Virtual-2", value="5")
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [[od.SYNC, "--once"]])

    def test_secondary_named_rule_refuses_without_side_effects(self):
        original = 'local omarchy_monitor_scale = 1.6\nhl.monitor({ output = "Virtual-2", scale = 2 })\n'
        self.lua.write_text(original)
        folder = od.CONFIG.parent / "scales"
        folder.mkdir()
        saved = folder / "Virtual-2"
        saved.write_text("2\n")
        # Even a full-panel output must refuse before asking the Mac to resize.
        with mock.patch.object(od, "focused_monitor", return_value={
                "name": "Virtual-2", "width": 1920, "height": 2160}), \
             mock.patch.object(od, "fullpanel_output", return_value="Virtual-2"), \
             mock.patch.object(od, "poke") as poke, \
             mock.patch.object(od.subprocess, "call") as call, \
             mock.patch("sys.stderr", new_callable=__import__("io").StringIO) as err:
            self.assertEqual(od.set_scale("1.25"), 2)
        call.assert_not_called()
        poke.assert_not_called()
        self.assertEqual(self.lua.read_text(), original)
        self.assertEqual(saved.read_text(), "2\n")
        self.assertIn("Virtual-2", err.getvalue())
        self.assertIn(str(self.lua), err.getvalue())
        self.assertIn("edit", err.getvalue().lower())

    def test_secondary_choices_are_independent(self):
        for output, value in (("Virtual-2", "1.25"), ("Virtual-3", "1.6"), ("Virtual-2", "2")):
            self.set_scale([(1920, 2160)], fullpanel=False, focused=output, value=value)
        self.assertEqual((od.CONFIG.parent / "scales/Virtual-2").read_text(), "2\n")
        self.assertEqual((od.CONFIG.parent / "scales/Virtual-3").read_text(), "1.6\n")

    def test_scale_usage(self):
        with mock.patch("sys.stderr"):
            self.assertEqual(od.set_scale("0.5"), 2)
            self.assertEqual(od.set_scale("big"), 2)


if __name__ == "__main__":
    unittest.main()
