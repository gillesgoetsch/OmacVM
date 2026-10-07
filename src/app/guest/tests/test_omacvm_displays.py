#!/usr/bin/env python3
"""Tests for omacvm-displays' desktop check (no VM needed).

    python3 src/app/guest/tests/test_omacvm_displays.py
"""
import importlib.machinery
import importlib.util
import pathlib
import sys
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


if __name__ == "__main__":
    unittest.main()
