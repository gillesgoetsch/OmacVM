#!/usr/bin/env python3
"""The bar patch on a minimal stand-in for Omarchy's Bar.qml (no VM needed).

    python3 src/omanotch/guest/tests/test_bar_patch.py

With node installed, the patch's startup and watchdog logic also runs against
fake state files: the right bar from the first frame after login.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
PATCH = ROOT / "src/omanotch/guest/bar/apply-patch.py"

# Only the lines the patch anchors on, in Omarchy's order.
BAR = '''import Quickshell
Item {
  id: root
  property string home: Quickshell.env("HOME")

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {
    visible: !remapGuard.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
    margins {
      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0
    }
    implicitWidth: root.vertical ? root.barSize : 0
    implicitHeight: root.vertical ? 0 : root.barSize
    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top
    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalBar : horizontalBar
    }
      }
    }
  }
  Component {
      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.left: parent.left
        }
      }
  }
  Item {
    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1
        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }
  }
}
'''


def patched():
    d = pathlib.Path(tempfile.mkdtemp())
    try:
        f = d / "Bar.qml"
        f.write_text(BAR)
        subprocess.run([sys.executable, str(PATCH), str(f)], check=True, capture_output=True)
        return f.read_text()
    finally:
        shutil.rmtree(d)


def file_view(text, name):
    m = re.search(r"FileView \{\n    id: %s\n(.*?)\n  \}" % name, text, re.S)
    return m.group(1) if m else ""


def function(text, name):
    """The JavaScript body of a QML function (brace-matched)."""
    start = text.index("function %s(" % name)
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i + 1:j]
    raise ValueError(name)


def timer_body(text):
    m = re.search(r"triggeredOnStart: true\n    onTriggered: \{\n(.*?)\n    \}\n  \}", text, re.S)
    return m.group(1)


class Patch(unittest.TestCase):
    def setUp(self):
        self.text = patched()

    def test_version(self):
        self.assertIn("// omarchy-notch-bar patch v17", self.text)

    def test_state_files_read_fresh_after_reload(self):
        # blockLoading alone: text() right after reload() gives the old content
        # (the "0" notchcast wrote at its start), which unparked the bar ~5 s
        # after login for one 3 s tick: two bars, one under the other.
        for name in ("notchBeatFile", "notchParkFile", "notchExpectFile", "notchGeomFile", "notchBuiltinFile"):
            self.assertIn("blockAllReads: true", file_view(self.text, name), name)

    def test_boot_reads_the_hint_once(self):
        body = timer_body(self.text)
        self.assertIn("root.notchBoot()", body)
        self.assertEqual(self.text.count("notchBoot()"), 2)  # the definition and the one call

    def test_patch_again_is_a_no_op(self):
        d = pathlib.Path(tempfile.mkdtemp())
        try:
            f = d / "Bar.qml"
            f.write_text(self.text)
            out = subprocess.run([sys.executable, str(PATCH), str(f)], check=True, capture_output=True, text=True)
            self.assertIn("already patched (v17)", out.stdout)
            self.assertEqual(f.read_text(), self.text)
        finally:
            shutil.rmtree(d)


# Runs the patch's own JavaScript with fake files and a fake clock.
HARNESS = r'''
const files = %(files)s;
let now = %(now)s;
const written = {};
function fv(name) {
  return {
    reload() {},
    text() { return files[name] || ""; },
    setText(t) { written[name] = t; files[name] = t; },
  };
}
const root = {
  notchParked: false, notchParkedScreen: "Virtual-1", notchLeft: 918, notchRight: 1138,
  notchHeight: 0, notchBarHeight: 0, notchLastBeat: 0, notchBootPark: false, notchBooted: false,
  notchBootGraceMs: %(grace)s, notchStartedAt: now,
  notchBeatFile: fv("beat"), notchParkFile: fv("park"), notchExpectFile: fv("expect"), notchGeomFile: fv("geom"),
  notchBuiltinFile: fv("builtin"), notchBootExpiry: { interval: 0, restart() { root.expiryAt = now + this.interval; } },
  expiryAt: null,
};
const Date_ = { now: () => now };
const scope = new Proxy(root, {
  has: (t, k) => k in t || k === "root" || k === "Date",
  get: (t, k) => k === "root" ? scope : k === "Date" ? Date_ : t[k],
  set: (t, k, v) => { t[k] = v; return true; },
});
root.notchFollowParkFile = function () { with (scope) { %(follow)s } };
root.notchBoot = function () { with (scope) { %(boot)s } };
root.notchBootParkOn = function (name) { with (scope) { %(bootparkon)s } };
root.notchWatchdog = function () { with (scope) { %(watchdog)s } };
root.notchArmExpiry = function () { with (scope) { %(armexpiry)s } };
function bootPark(name) { with (scope) { %(bootpark)s } }
function tick() { with (scope) { %(tick)s } }
const seen = [];
for (const step of %(steps)s) {
  if (step.files) Object.assign(files, step.files);
  if (step.at !== undefined) now = step.at;
  if (step.ipc === "setParked") { root.notchLastBeat = now; root.notchBootPark = false; root.notchParked = step.on; }
  if (step.ipc === "bootPark") bootPark(step.name);
  // The one-shot grace timer fires when its time has come.
  if (root.expiryAt !== null && now >= root.expiryAt) { root.expiryAt = null; root.notchWatchdog(); }
  if (step.tick) tick();
  seen.push({ parked: root.notchParked, screen: root.notchParkedScreen });
}
console.log(JSON.stringify({ seen, root: { notchLeft: root.notchLeft, notchRight: root.notchRight,
  notchHeight: root.notchHeight, notchBarHeight: root.notchBarHeight }, written }));
'''


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Behaviour(unittest.TestCase):
    """t in ms; the shell starts at t=100000, its timer ticks every 3000."""

    START = 100000

    def run_js(self, files, steps):
        text = patched()
        tick = timer_body(text)
        js = HARNESS % {
            "files": json.dumps(files), "now": self.START, "steps": json.dumps(steps),
            "grace": re.search(r"notchBootGraceMs: (\d+)", text).group(1),
            "follow": function(text, "notchFollowParkFile"), "boot": function(text, "notchBoot"), "tick": tick,
            "bootparkon": function(text, "notchBootParkOn"), "watchdog": function(text, "notchWatchdog"),
            "bootpark": function(text, "bootPark"), "armexpiry": function(text, "notchArmExpiry"),
        }
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        return json.loads(out.stdout)

    def ticks(self, n, first=None):
        first = self.START if first is None else first
        return [{"tick": True, "at": first + 3000 * i} for i in range(n)]

    def test_strip_last_session_starts_parked(self):
        # Last session ended with the strip showing; notchcast has written
        # its start-up "0" (no beat: the old one is long stale).
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n", "beat": "1000\n"}, self.ticks(1))
        self.assertEqual(r["seen"][0], {"parked": True, "screen": "Virtual-1"})

    def test_other_builtin_display(self):
        r = self.run_js({"expect": "1 Virtual-2\n"}, self.ticks(1))
        self.assertEqual(r["seen"][0], {"parked": True, "screen": "Virtual-2"})

    def test_no_hint_starts_unparked(self):
        for expect in ("", "0\n", "1\n", "1 Virtual-1 x\n", "1 ../x\n", "garbage"):
            r = self.run_js({"expect": expect}, self.ticks(1))
            self.assertFalse(r["seen"][0]["parked"], expect)

    def test_confirmed_by_omanotch_stays_parked(self):
        steps = self.ticks(1) + [
            # Omanotch's park 1, ~2 s after login: notchcast writes park, then beat.
            {"at": self.START + 2000, "files": {"park": "1 Virtual-1\n", "beat": str(self.START + 2000)}},
            {"ipc": "setParked", "on": True},
        ]
        beat = self.START + 2000
        for i in range(1, 12):
            t = self.START + 3000 * i
            if t - beat >= 4000:
                beat = t - 500
            steps.append({"tick": True, "at": t, "files": {"beat": str(beat)}})
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertTrue(all(s["parked"] for s in r["seen"]), r["seen"])
        self.assertNotIn("expect", r["written"])

    def test_confirmed_by_files_only(self):
        # The IPC call reached no shell (still loading): the files do it.
        steps = self.ticks(1) + [
            {"at": self.START + 2000, "files": {"park": "1 Virtual-1\n", "beat": str(self.START + 2000)}}]
        steps += [{"tick": True, "at": self.START + 3000 * i, "files": {"beat": str(self.START + 3000 * i - 1000)}}
                  for i in range(1, 8)]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertTrue(all(s["parked"] for s in r["seen"]), r["seen"])

    def test_not_confirmed_comes_back_and_stops_guessing(self):
        # Windowed now, or Omanotch not running: the bar is back within
        # the grace time plus one tick, and the hint says "0".
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, self.ticks(6))
        parked = [s["parked"] for s in r["seen"]]
        self.assertEqual(parked, [True, True, True, False, False, False])  # back at +9 s
        self.assertEqual(r["written"].get("expect"), "0\n")

    def test_omanotch_says_hidden(self):
        # Omanotch (with this change) answers a windowed guest with park 0 at
        # once; notchcast writes park 0 and a beat.
        steps = self.ticks(1) + [
            {"at": self.START + 1500, "files": {"park": "0\n", "beat": str(self.START + 1500), "expect": "0\n"}},
            {"ipc": "setParked", "on": False},
            {"tick": True, "at": self.START + 3000},
        ]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True, True, False, False])

    def test_omanotch_says_hidden_ipc_lost(self):
        steps = self.ticks(1) + [
            {"at": self.START + 1500, "files": {"park": "0\n", "beat": str(self.START + 1500), "expect": "0\n"}},
            {"tick": True, "at": self.START + 3000},
        ]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True, True, False])

    def test_quick_reboot_ignores_the_last_sessions_park_file(self):
        # notchcast removes its beat when it stops; a new session's "0" alone
        # does not unpark.
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, self.ticks(2))
        self.assertEqual([s["parked"] for s in r["seen"]], [True, True])

    def test_shell_restart_mid_session_follows_the_park_file(self):
        beat = str(self.START - 1000)
        r = self.run_js({"expect": "0\n", "park": "1 Virtual-1\n", "beat": beat}, self.ticks(1))
        self.assertTrue(r["seen"][0]["parked"])

    def test_not_confirmed_comes_back_on_time(self):
        # The one-shot grace timer, not the next 3 s tick.
        steps = self.ticks(1) + [{"at": self.START + 7900}, {"at": self.START + 8100}]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True, True, False])
        self.assertEqual(r["written"].get("expect"), "0\n")

    def test_connected_waiting_keeps_the_guess(self):
        # notchcast is connected ("w") but the strip's first frame takes long:
        # parked past the grace time, back 15 s after the last beat if no
        # word comes.
        steps = self.ticks(1) + [{"at": self.START + 2000, "files": {"park": "w Virtual-1\n",
                                                                     "beat": str(self.START + 2000)}}]
        steps += [{"tick": True, "at": self.START + 3000 * i} for i in range(1, 6)]  # to +15 s
        steps += [{"tick": True, "at": self.START + 18000}]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True] * 7 + [False])
        self.assertEqual(r["written"].get("expect"), "0\n")

    def test_connected_waiting_then_confirmed(self):
        steps = self.ticks(1) + [
            {"at": self.START + 2000, "files": {"park": "w Virtual-1\n", "beat": str(self.START + 2000)}},
            {"tick": True, "at": self.START + 3000},
            {"tick": True, "at": self.START + 6000},
            {"at": self.START + 7000, "files": {"park": "1 Virtual-1\n", "beat": str(self.START + 7000)}},
            {"ipc": "setParked", "on": True},
        ]
        steps += [{"tick": True, "at": self.START + 9000 + 3000 * i, "files": {"beat": str(self.START + 8000 + 3000 * i)}}
                  for i in range(6)]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertTrue(all(s["parked"] for s in r["seen"]), r["seen"])
        self.assertNotIn("expect", r["written"])

    def test_connected_before_the_shell_started(self):
        # Boot: notchcast connected (and wrote "w" with a beat) 1.5 s before
        # the shell's bar came up. That beat still counts for the wait.
        steps = self.ticks(1) + [{"tick": True, "at": self.START + 3000 * i} for i in range(1, 5)]
        steps += [{"at": self.START + 13600}]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "w Virtual-1\n", "beat": str(self.START - 1500)}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True] * 5 + [False])  # 15 s after the beat

    def test_waiting_changes_nothing_when_not_guessing(self):
        steps = self.ticks(1) + [
            {"at": self.START + 2000, "files": {"park": "w Virtual-1\n", "beat": str(self.START + 2000)}},
            {"tick": True, "at": self.START + 3000},
        ]
        r = self.run_js({"expect": "0\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [False, False, False])

    def test_hint_after_a_windowed_session(self):
        # The hint said "0" (windowed last time); Omanotch sees full screen at
        # connect: notchcast writes expect 1, "w" and a beat, and calls bootPark.
        steps = self.ticks(1) + [
            {"at": self.START + 500, "files": {"expect": "1 Virtual-1\n", "park": "w Virtual-1\n",
                                               "beat": str(self.START + 500)}},
            {"ipc": "bootPark", "name": "Virtual-1"},
            {"tick": True, "at": self.START + 3000},
            {"at": self.START + 3500, "files": {"park": "1 Virtual-1\n", "beat": str(self.START + 3500)}},
            {"ipc": "setParked", "on": True},
            {"tick": True, "at": self.START + 6000},
            {"at": self.START + 9000},
        ]
        r = self.run_js({"expect": "0\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [False, False, True, True, True, True, True, True])
        self.assertNotIn("expect", r["written"])

    def test_hint_while_parked_changes_nothing(self):
        steps = [{"at": self.START, "files": {"park": "1 Virtual-1\n", "beat": str(self.START - 500)}, "tick": True},
                 {"ipc": "bootPark", "name": "Virtual-3"}]
        r = self.run_js({"expect": "0\n"}, steps)
        self.assertEqual(r["seen"][-1], {"parked": True, "screen": "Virtual-1"})

    def test_builtin_display_named_by_the_app(self):
        # OmacVM.app with external displays: the built-in display is another
        # output than in the last session.
        r = self.run_js({"expect": "1 Virtual-1\n", "builtin": "Virtual-2\n"}, self.ticks(1))
        self.assertEqual(r["seen"][0], {"parked": True, "screen": "Virtual-2"})
        r = self.run_js({"expect": "1 Virtual-1\n", "builtin": "../x\n"}, self.ticks(1))
        self.assertEqual(r["seen"][0], {"parked": True, "screen": "Virtual-1"})

    def test_hidden_said_before_the_shell_started(self):
        # Windowed boot with the hint "1": Omanotch's park 0 at connect came
        # 0.8 s before the shell's bar (expect still "1" when it read it).
        steps = self.ticks(1) + [{"tick": True, "at": self.START + 3000}]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n", "beat": str(self.START - 800)}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [False, False])

    def test_shell_restart_with_the_hint_keeps_the_bar_parked(self):
        # Mid-session restart while the strip shows: parked from the hint, the
        # next beat (after the start) confirms it.
        steps = self.ticks(1) + [
            {"tick": True, "at": self.START + 3000, "files": {"beat": str(self.START + 2000)}},
            {"at": self.START + 9000},
            {"tick": True, "at": self.START + 12000, "files": {"beat": str(self.START + 10000)}},
        ]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "1 Virtual-1\n", "beat": str(self.START - 1000)}, steps)
        self.assertTrue(all(s["parked"] for s in r["seen"]), r["seen"])
        self.assertNotIn("expect", r["written"])

    def test_helper_gone_brings_the_bar_back_and_keeps_the_hint(self):
        # notchcast's "park 0 gone": park 0 and a beat, the hint file untouched.
        steps = self.ticks(1) + [
            {"at": self.START + 2000, "files": {"park": "1 Virtual-1\n", "beat": str(self.START + 2000)}},
            {"ipc": "setParked", "on": True},
            {"at": self.START + 5000, "files": {"park": "0\n", "beat": str(self.START + 5000)}},
            {"tick": True, "at": self.START + 6000},
        ]
        r = self.run_js({"expect": "1 Virtual-1\n", "park": "0\n"}, steps)
        self.assertEqual([s["parked"] for s in r["seen"]], [True, True, True, True, False])
        self.assertNotIn("expect", r["written"])

    def test_geometry_of_the_last_session(self):
        r = self.run_js({"geom": "646 825 33 0\n"}, self.ticks(1))
        self.assertEqual(r["root"], {"notchLeft": 646, "notchRight": 825, "notchHeight": 33, "notchBarHeight": 0})
        r = self.run_js({"geom": "646 825 33 24\n"}, self.ticks(1))
        self.assertEqual(r["root"]["notchBarHeight"], 24)

    def test_bad_geometry_is_ignored(self):
        for geom in ("", "646 825 33\n", "x 825 33 0\n", "825 646 33 0\n", "0 0 0 0\n"):
            r = self.run_js({"geom": geom}, self.ticks(1))
            self.assertEqual(r["root"]["notchLeft"], 918, geom)


if __name__ == "__main__":
    unittest.main()
