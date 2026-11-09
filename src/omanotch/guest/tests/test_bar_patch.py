#!/usr/bin/env python3
"""The bar patch on a minimal stand-in for Omarchy's Bar.qml (no VM needed).

    python3 src/omanotch/guest/tests/test_bar_patch.py

With node installed, the patch's startup and watchdog logic also runs against
fake state files: the right bar from the first frame after login. RealOmarchy
runs it on Omarchy's own Bar.qml as omarchy-mac, upstream (October 2026) and
Omarchy 4.5.0 have it (src/tests/omarchy-shell).
"""
import json
import os
import math
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
PATCH = ROOT / "src/omanotch/guest/bar/apply-patch.py"
# The patch's version, its version line and what a second run says.
V = int(re.search(r"^VERSION = (\d+)$", PATCH.read_text(), re.M).group(1))
VERSION_LINE = "// omarchy-notch-bar patch v%d" % V
ALREADY = "already patched (v%d)" % V

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

        RightModules {
          anchors.right: parent.right
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

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.left: centerAnchorModule.right
        }
  }
  component ModuleList: Loader {
    id: moduleListRoot

    property var entries: []
    property string region: ""
      Row {
        spacing: 0

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            entry: modelData
            region: moduleListRoot.region
          }
        }
      }
  }
  component ModuleSlot: Item {
    id: slot

    required property var entry
    property string region: ""
    z: modulePointer.dragging ? 100 : 0
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
        self.assertEqual(V, 41)
        self.assertIn(VERSION_LINE, self.text)

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
            self.assertIn(ALREADY, out.stdout)
            self.assertEqual(f.read_text(), self.text)
        finally:
            shutil.rmtree(d)


def load_patch():
    import importlib.util
    spec = importlib.util.spec_from_file_location("bar_apply_patch", PATCH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Incomplete(unittest.TestCase):
    """#354: the version line alone is not a patch; every piece must be there."""

    def setUp(self):
        self.full = patched()
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.bar = self.dir / "Bar.qml"
        self.backup = self.dir / "Bar.qml.before-notchbar"

    def tearDown(self):
        shutil.rmtree(self.dir)

    def run_patch(self):
        return subprocess.run([sys.executable, str(PATCH), str(self.bar)], capture_output=True, text=True)

    @property
    def pieces(self):
        return load_patch().PIECES

    def test_every_piece_is_in_the_patch_and_not_in_omarchy(self):
        for piece in self.pieces:
            self.assertGreaterEqual(self.full.count(piece), 1, piece)
            self.assertNotIn(piece, BAR, piece)

    def test_version_line_alone_with_a_backup_gets_the_whole_patch(self):
        self.bar.write_text(VERSION_LINE + "\n")
        self.backup.write_text(BAR)
        out = self.run_patch()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("replacing an incomplete or older patch", out.stdout)
        self.assertEqual(self.bar.read_text(), self.full)
        self.assertEqual(self.backup.read_text(), BAR)

    def test_version_line_alone_without_a_backup_stops(self):
        self.bar.write_text(VERSION_LINE + "\n")
        out = self.run_patch()
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("re-clone the bar", out.stderr)
        self.assertEqual(self.bar.read_text(), VERSION_LINE + "\n")

    def test_a_backup_that_is_patched_itself_is_not_used(self):
        self.bar.write_text(VERSION_LINE + "\n")
        self.backup.write_text(self.full)
        out = self.run_patch()
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("no clean backup", out.stderr)
        self.assertEqual(self.bar.read_text(), VERSION_LINE + "\n")

    def test_each_missing_piece_is_patched_again(self):
        self.backup.write_text(BAR)
        for piece in self.pieces:
            self.bar.write_text(self.full.replace(piece, ""))
            out = self.run_patch()
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("replacing an incomplete or older patch", out.stdout, piece)
            self.assertEqual(self.bar.read_text(), self.full, piece)

    def test_whole_patch_stays_as_it_is(self):
        self.backup.write_text(BAR)
        self.bar.write_text(self.full)
        out = self.run_patch()
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(ALREADY, out.stdout)
        self.assertEqual(self.bar.read_text(), self.full)

    def test_a_piece_found_twice_still_counts(self):
        # Present, not "exactly once": "id: notchRemap" is also in "id: notchRemapSettle".
        twice = self.full + "// " + "    readonly property string notchRole: root.notchRoleFor(screen)\n"
        self.bar.write_text(twice)
        out = self.run_patch()
        self.assertIn(ALREADY, out.stdout)
        self.assertEqual(self.bar.read_text(), twice)


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
  notchHostEnvFile: fv("hostenv"), notchLayoutFile: fv("layout"),
  notchPanel: [], notchPanelOn: false, notchPanelScreen: "Virtual-1",
  notchSkipOn: false, notchSkipBoot: false, notchSkipFile: fv("skip"),
  Quickshell: { screens: %(screens)s },
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
root.notchPanelParse = function (text) { with (scope) { %(panelparse)s } };
root.notchPanelState = function (layoutText, g) { with (scope) { %(panelstate)s } };
root.notchPanelBox = function (g, logicalWidth) { with (scope) { %(panelbox)s } };
root.notchPanelUpdate = function () { with (scope) { %(panelupdate)s } };
root.notchSkipUpdate = function () { with (scope) { %(skipupdate)s } };
function bootPark(name) { with (scope) { %(bootpark)s } }
function tick() { with (scope) { %(tick)s } }
const seen = [];
const panels = [];
const skips = [];
for (const step of %(steps)s) {
  if (step.files) Object.assign(files, step.files);
  if (step.at !== undefined) now = step.at;
  if (step.ipc === "setParked") { root.notchLastBeat = now; root.notchBootPark = false; root.notchParked = step.on; }
  if (step.ipc === "bootPark") bootPark(step.name);
  // The one-shot grace timer fires when its time has come.
  if (root.expiryAt !== null && now >= root.expiryAt) { root.expiryAt = null; root.notchWatchdog(); }
  if (step.screens) root.Quickshell.screens = step.screens;
  if (step.tick) tick();
  seen.push({ parked: root.notchParked, screen: root.notchParkedScreen });
  panels.push({ on: root.notchPanelOn, screen: root.notchPanelScreen });
  skips.push(root.notchSkipOn);
}
console.log(JSON.stringify({ seen, root: { notchLeft: root.notchLeft, notchRight: root.notchRight,
  notchHeight: root.notchHeight, notchBarHeight: root.notchBarHeight }, panel: root.notchPanel, panels, skips, written }));
'''


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Behaviour(unittest.TestCase):
    """t in ms; the shell starts at t=100000, its timer ticks every 3000."""

    START = 100000

    def run_js(self, files, steps, screens=None):
        text = patched()
        tick = timer_body(text)
        js = HARNESS % {
            "files": json.dumps(files), "now": self.START, "steps": json.dumps(steps),
            "screens": json.dumps(screens or [{"name": "Virtual-1", "width": 1470, "height": 956}]),
            "panelparse": function(text, "notchPanelParse"), "panelstate": function(text, "notchPanelState"),
            "panelbox": function(text, "notchPanelBox"), "panelupdate": function(text, "notchPanelUpdate"),
            "grace": re.search(r"notchBootGraceMs: (\d+)", text).group(1),
            "follow": function(text, "notchFollowParkFile"), "boot": function(text, "notchBoot"), "tick": tick,
            "bootparkon": function(text, "notchBootParkOn"), "watchdog": function(text, "notchWatchdog"),
            "bootpark": function(text, "bootPark"), "armexpiry": function(text, "notchArmExpiry"),
            "skipupdate": function(text, "notchSkipUpdate"),
        }
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        return json.loads(out.stdout)

    def ticks(self, n, first=None):
        first = self.START if first is None else first
        return [{"tick": True, "at": first + 3000 * i} for i in range(n)]

    def test_skip_the_notch_from_the_app(self):
        # At the start: host.env (FullPanel or Omanotch's strip alike).
        for env, want in (("OMACVM_NOTCHSKIP=1\n", True), (AIR_ENV + "\nOMACVM_NOTCHSKIP=1\n", True), (AIR_ENV + "\n", False),
                          ("", False), ("OMACVM_NOTCHSKIP=0\n", False), ("OMACVM_NOTCHSKIP=12\n", False)):
            self.assertEqual(self.run_js({"hostenv": env}, self.ticks(1))["skips"], [want], env)
        # Switched while the VM runs: /run/omacvm/notch-skip wins, within a tick.
        r = self.run_js({"hostenv": "OMACVM_NOTCHSKIP=1\n"}, self.ticks(1) + [
            {"tick": True, "at": self.START + 3000, "files": {"skip": "0\n"}},
            {"tick": True, "at": self.START + 6000, "files": {"skip": "1"}},
            {"tick": True, "at": self.START + 9000, "files": {"skip": "0"}},
            {"tick": True, "at": self.START + 12000, "files": {"skip": "junk"}},
            {"tick": True, "at": self.START + 15000, "files": {"skip": ""}}])
        self.assertEqual(r["skips"], [True, False, True, False, True, True])
        r = self.run_js({"hostenv": "", "skip": "1\n"}, self.ticks(2))
        self.assertEqual(r["skips"], [True, True])

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


SHELL_DIR = ROOT / "src/tests/omarchy-shell"
SHELLS = sorted(SHELL_DIR.glob("*/shell/plugins/bar/Bar.qml"))


def patch_file(path):
    return subprocess.run([sys.executable, str(PATCH), str(path)], capture_output=True, text=True)


def is_45(stock):
    """Omarchy 4.5's bar (a widget pool per bar surface, GridLayout lists)."""
    return "  component WidgetPool: Item {\n" in stock


class RealOmarchy(unittest.TestCase):
    """Omarchy's own Bar.qml: omarchy-mac's (what 4.0 VMs have), upstream's
    from October 2026 (notch floor from display-cutouts.json, a thickness per
    screen, the centre's hover area up to the anchor widget) and Omarchy
    4.5.0's (each bar surface spans its screen, a widget pool, three centre
    sections)."""

    def setUp(self):
        self.assertEqual(len(SHELLS), 3, SHELLS)
        self.assertEqual(sum(is_45(b.read_text()) for b in SHELLS), 1)
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def full(self, stock):
        f = self.dir / "full.qml"
        f.write_text(stock)
        out = patch_file(f)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "patched")
        return f.read_text()

    def each(self):
        for bar in SHELLS:
            with self.subTest(omarchy=bar.parts[-5]):
                yield bar.parts[-5], bar.read_text()

    def test_patch_and_again(self):
        for name, stock in self.each():
            full = self.full(stock)
            self.assertIn(VERSION_LINE, full)
            self.assertEqual(load_patch().missing_pieces(full), [])
            f = self.dir / "Bar.qml"
            f.write_text(full)
            out = patch_file(f)
            self.assertIn(ALREADY, out.stdout)
            self.assertEqual(f.read_text(), full)

    def test_omarchys_own_conditions_stay(self):
        for name, stock in self.each():
            full = self.full(stock)
            visible = re.search(r"^    visible: !remapGuard\.remapping(.*)$", stock, re.M).group(1)
            self.assertIn("    visible: !remapGuard.remapping%s && !notchRemap.remapping\n" % visible, full)
            # Ordinary bars: Omarchy's height and how far it parks a hidden bar.
            height = re.search(r"^    implicitHeight: root\.vertical \? 0 : (.*)$", stock, re.M).group(1)
            self.assertIn('implicitHeight: root.vertical ? 0 : (barWindow.notchRole === "" ? %s : barWindow.parkedSize)' % height, full)
            size = ("barWindow.parkDistance" if "-barWindow.parkDistance : 0" in stock
                    else "barWindow.thickness" if "-barWindow.thickness : 0" in stock else "root.barSize")
            self.assertIn('notchRole === "fullpanel" ? notchPanelFit[0] : %s\n' % size, full)
            self.assertIn('top: barWindow.parked && root.position === "top" ? -barWindow.parkedSize : 0', full)
            self.assertNotIn("root.barHidden && root.position", full)

    def test_centre_around_the_housing(self):
        for name, stock in self.each():
            if is_45(stock):
                continue   # test_45_centre_sections_around_the_housing
            full = self.full(stock)
            self.assertEqual(full.count("notchLayout: barWindow.notchLayout"), 1)
            self.assertEqual(full.count("anchors.right: centerRoot.notchLayout ? notchLeftEdge.left : centerAnchorModule.left"), 1)
            self.assertEqual(full.count("anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined"), 2)
            # Omarchy's hover over the centre stays as it is.
            self.assertEqual(full.count("onHoveredChanged: root.setCenterSectionHovered(hovered)"),
                             stock.count("onHoveredChanged: root.setCenterSectionHovered(hovered)"))

    def test_skip_the_notch_only_in_the_horizontal_bar(self):
        for name, stock in self.each():
            full = self.full(stock)
            vertical = re.compile(r"\n    Component \{\n      id: verticalBar\n.*?\n    \}\n", re.S)
            self.assertEqual(vertical.search(full).group(0), vertical.search(stock).group(0))
            self.assertEqual(full.count("id: notchSkipBar"), 1)
            self.assertEqual(full.count("notchShift: notchSkipBar.notchSkip ? { items: notchSkipBar.notchSkip."), 2)
            self.assertEqual(full.count("id: rightModules"), 1)
            # Each item of a list (only the horizontal bar's lists get a shift).
            index = "notchSlotIndex" if is_45(stock) else "index"
            self.assertEqual(full.count("notchShift: root.notchShiftAt(moduleListRoot.notchShift, %s)" % index), 1)
            self.assertEqual(full.count("transform: Translate { x: slot.notchShift ? slot.notchShownX - (slot.notchEnd ? slot.width : 0) - slot.notchPlaceX : 0 }"), 1)
            # The housing's centre widths, and the after list named for them.
            if is_45(stock):
                self.assertIn("? [beginList.notchRest, centerBox.notchRest + endList.notchRest, beginList.notchPeekMore] : [0, 0]", full)
                self.assertEqual(full.count("    readonly property real notchRest: boxList.notchRest\n"), 1)
            else:
                self.assertEqual(full.count("id: notchCentreAfter"), 1)
                self.assertIn("? [notchCentreBefore.width, centerAnchorModule.width + notchCentreAfter.width]", full)
            # The indicators' hidden ones: their own transform, set from the bar.
            self.assertEqual(full.count("    Translate { id: notchPeekMove; x: slot.notchPeekDx }\n"), 1)
            self.assertIn("area.transform = s && s.peekAt !== undefined ? [notchPeekMove] : []", full)
            # Omanotch's clicks and hover skip hidden items.
            self.assertEqual(full.count("if (!moduleTargetClickable(t) || t.enabled === false) continue"), 2)

    def test_45_a_notch_roles_window_is_its_strip(self):
        # 4.5's bar window spans its screen and draws the strip at its edge.
        # The parked copy (1 px), NOTCH's and FullPanel's bar are only their
        # strip: the window, the strip in it, the zone it reserves.
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        full = self.full(stock)
        self.assertIn('    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === "" ? '
                      '(screen ? screen.height : thickness) : barWindow.parkedSize)\n', full)
        self.assertIn('      height: root.vertical ? parent.height : (barWindow.notchRole === "" ? barWindow.thickness : parent.height)\n', full)
        self.assertIn('    exclusionMode: barWindow.parked ? ExclusionMode.Ignore : ExclusionMode.Normal\n'
                      '    exclusiveZone: barWindow.notchRole === "" ? thickness\n'
                      '      : barWindow.notchRole === "fullpanel" ? barWindow.notchPanelZone : barWindow.parkedSize\n', full)
        self.assertIn('      : notchRole === "notch" ? notchFit[0] : notchRole === "fullpanel" ? notchPanelFit[0] : barWindow.parkDistance\n', full)
        strip = full[full.index("      id: barStrip\n"):full.index("    PopupWindow {")]
        self.assertIn("        anchors.topMargin: barWindow.notchPadTop\n        anchors.bottomMargin: barWindow.notchPadBottom\n"
                      "        visible: !barWindow.notchClear\n", strip)
        self.assertEqual(strip.count("visible: !barWindow.notchClear"), 2)   # its background too
        # Omarchy's own input mask and remap stay.
        self.assertEqual(full.count("mask: dragActive ? null : (underFullscreen ? noInputRegion : stripInputRegion)"), 1)
        self.assertEqual(full.count("ScreenMoveRemap {"), stock.count("ScreenMoveRemap {"))

    def test_45_centre_sections_around_the_housing(self):
        # centerBegin ends left of the housing, the center box and centerEnd
        # start right of it (4.0's look); vertical bars and the sections
        # beside the right one (4.5's own notch layout) as Omarchy has them.
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        full = self.full(stock)
        self.assertEqual(full.count("notchLayout: barWindow.notchLayout"), 1)
        self.assertEqual(full.count("notchLayout: centerRoot.notchLayout"), 1)
        sections = full[full.index("  component CenterSections: Item {"):full.index("  component CenterBox: Item {")]
        self.assertIn(": (sections.notchLayout ? root.notchLeft - Style.space(6) - width : centerBox.x - width)", sections)
        self.assertIn("x: root.vertical ? 0 : (sections.notchLayout ? root.notchRight + Style.space(6) : "
                      "sections.besideRight ? beginList.width : Math.round((sections.width - width) / 2))", sections)
        self.assertIn('fixedEdge: sections.notchLayout ? "start" : sections.besideRight ? "end" : "center"', sections)
        self.assertIn("x: root.vertical ? Math.round((sections.width - width) / 2) : centerBox.x + centerBox.width", sections)
        self.assertEqual(full.count("drawn: !barWindow.centerBesideRight"), 1)
        self.assertEqual(full.count("active: barWindow.centerBesideRight"), 1)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_45_list_widths_at_rest(self):
        # A 4.5 list's items by their place in its keys (a drag's spacers and
        # the Repeater are no items of it); the indicators count at rest.
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        full = self.full(stock)
        widths = re.search(r"    readonly property var notchWidths: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        rest = re.search(r"    readonly property real notchRest: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        more = re.search(r"    readonly property real notchPeekMore: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        # implicitWidth (what each slot asks for), never the laid-out width,
        # which the layout's polish sets later (999: not laid out yet, #757).
        js = """
var children = [ {}, { notchSlotIndex: 2, width: 999, implicitWidth: 40, notchPeekFull: 0 },
                 { notchSlotIndex: 0, width: 0, implicitWidth: 30, notchPeekFull: 0 },
                 { width: 50, implicitWidth: 50 },
                 { notchSlotIndex: 1, width: 999, implicitWidth: 90, notchPeekRest: 22, notchPeekFull: 68 } ];
var notchWidths = (function () { WIDTHS })();
console.log(JSON.stringify([notchWidths, (function () { REST })(), (function () { MORE })()]));
""".replace("WIDTHS", widths).replace("REST", rest).replace("MORE", more)
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        # The indicators' peek widens the list by their hidden ones (68).
        self.assertEqual(json.loads(out.stdout), [[30, [90, 22, 68], 40], 92, 68])
        self.assertIn("            notchSlotIndex: moduleListRoot.keys.indexOf(modelData.key)\n", full)
        self.assertIn("onKeysChanged: if (notchShift && notchShift.animate)", full)

    def test_45_skip_never_reads_a_laid_out_width(self):
        # What Skip the notch decides by on 4.5 (the lists' widths, their rest,
        # the indicators' rest) reads no laid-out width: the slots force the
        # layout's polish while it is counted, a binding loop QML drops (#757).
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        full = self.full(stock)
        widths = re.search(r"    readonly property var notchWidths: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        rest = re.search(r"    readonly property real notchPeekRest: (.*)\n", full).group(1)
        for text in (widths, rest):
            self.assertNotIn("c.width", text)
            self.assertNotIn("width -", text)
            self.assertNotRegex(text, r"(?<![\w.])width\b")
        self.assertIn("var w = c.implicitWidth\n", widths)
        # The slot's own width: 4.5's widget width (a drag changes only the
        # length it asks for), 4.0's its implicit width.
        self.assertIn("readonly property real notchContentWidth: widgetWidth\n", full)
        for name, other in self.each():
            if not is_45(other):
                self.assertIn("readonly property real notchContentWidth: implicitWidth\n", self.full(other))

    def test_an_older_patcher_puts_its_own_back(self):
        # 3.1.4's patcher (v22) does not take this file for its own: it patches
        # again from the clean backup (the revert of an RC with this patch).
        for name, stock in self.each():
            full = self.full(stock)
            self.assertIn(load_patch().MARK, full)
            for older in range(10, V):
                self.assertNotIn("// omarchy-notch-bar patch v%d" % older, full)

    def test_one_room_function_for_toasts(self):
        for name, stock in self.each():
            full = self.full(stock)
            self.assertEqual(full.count("  function barSizeFor(screenName) {\n"), 1)
            body = function(full, "barSizeFor")
            self.assertTrue(body.startswith("\n    // omarchy-notch-bar: a bar parked in the notch strip takes no room here,\n"), body)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_toasts_keep_only_the_gap_under_the_parked_bar(self):
        # Omarchy's notifications (from about October 2026): the bar's room on
        # that screen plus the gap; a hidden bar counts the default size.
        # FullPanel (#339): the bar on its screen is as tall as the strip
        # (34 here, the bar 26), so the toast goes 34 + the gap down, not 26 +
        # the gap into the bar (the user's MacBook Pro, 2026-10-26).
        js = """
var BarModel = { barSizeFor: function (sizes, name, fallback) { return sizes[name] > 0 ? sizes[name] : fallback } }
function barClearance(bar, screenName, defaultBarSize, gapsOut) {
  var size = Number(defaultBarSize)
  if (bar && !bar.barHidden) size = Math.max(0, Number(bar.barSizeFor(screenName)))
  return size + Number(gapsOut)
}
var out = [];
CASES.forEach(function (c) {
  var root = { notchParked: c[0], notchParkedScreen: "Virtual-1", barHidden: false, barSize: 26,
               notchPanelOn: c[2], notchPanelScreen: "Virtual-1", notchHeight: 33.5, position: "top",
               screenBarSizes: { "Virtual-1": 26, "Virtual-2": 34 } }
  with (root) {   // QML resolves the bar's own properties without "root."
    root.notchRoleFor = function (s) { ROLE }
    root.notchBox = function (outH, strip, flush, size, scale) { BOX }
    root.barSizeFor = function (screenName) { BODY }
  }
  out.push(barClearance(root, c[1], 26, 10))
})
console.log(JSON.stringify(out))
"""
        cases = [[True, "Virtual-1", False], [True, "Virtual-2", False], [False, "Virtual-1", False],
                 [False, "Virtual-2", False], [False, "Virtual-1", True], [False, "Virtual-2", True]]
        for name, stock in self.each():
            full = self.full(stock)
            ask = js
            if is_45(stock):
                # 4.5 asks through its Delivery.js: the deck's top margin is
                # Delivery.barThickness (0 or less: the default size) + the gap.
                delivery = (SHELL_DIR / name / "shell/plugins/notifications/Delivery.js").read_text()
                thick = "function barThickness(bar, screenName, defaultBarSize) {%s}" % function(delivery, "barThickness")
                ask = js.replace("function barClearance(bar, screenName, defaultBarSize, gapsOut) {",
                                thick + "\nfunction barClearance(bar, screenName, defaultBarSize, gapsOut) {\n"
                                "  return barThickness(bar, screenName, defaultBarSize) + Number(gapsOut)")
            js_case = (ask.replace("CASES", json.dumps(cases)).replace("BODY", function(full, "barSizeFor"))
                       .replace("ROLE", function(full, "notchRoleFor")).replace("BOX", function(full, "notchBox")))
            out = subprocess.run(["node", "-e", js_case], check=True, capture_output=True, text=True)
            other = 34 if "screenBarSizes" in stock else 26   # a thicker bar there (notch floor) on the newer one
            self.assertEqual(json.loads(out.stdout), [10, other + 10, 36, other + 10, 34 + 10, other + 10])

    def test_older_patch_and_restore(self):
        for name, stock in self.each():
            full = self.full(stock)
            bar, backup = self.dir / "Bar.qml", self.dir / "Bar.qml.before-notchbar"
            backup.write_text(stock)
            # An older version (3.1.2 had v21; 3.4.0 v37; v38 = the test builds of
            # #733 and #735 alone; 3.4.1 v39; v40 = #759 alone), a version line
            # alone, each piece missing.
            olds = [full.replace(VERSION_LINE, "// omarchy-notch-bar patch v%d" % v) for v in (21, 37, 38, 39, 40)]
            olds.append(VERSION_LINE + "\n")
            mod = load_patch()
            olds += [full.replace(p, "") for p in (mod.PIECES_45 if is_45(stock) else mod.PIECES)]
            for old in olds:
                bar.write_text(old)
                out = patch_file(bar)
                self.assertEqual(out.returncode, 0, out.stderr)
                self.assertIn("replacing an incomplete or older patch", out.stdout)
                self.assertEqual(bar.read_text(), full)
                self.assertEqual(backup.read_text(), stock)
            # No clean backup: stops, the file stays as it is.
            backup.unlink()
            bar.write_text(olds[0])
            out = patch_file(bar)
            self.assertNotEqual(out.returncode, 0)
            self.assertIn("re-clone the bar", out.stderr)
            self.assertEqual(bar.read_text(), olds[0])

    def test_unknown_form_stops_and_writes_nothing(self):
        for name, stock in self.each():
            f = self.dir / "Bar.qml"
            changed = stock.replace("    visible: !remapGuard.remapping", "    visible: !remapGuard.remapping && root.ready", 1)
            f.write_text(changed)
            out = patch_file(f)
            self.assertNotEqual(out.returncode, 0)
            self.assertIn("could not find the bar's visible line", out.stderr)
            self.assertEqual(f.read_text(), changed)


SKIP = r"""
function place(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) { BODY }
console.log(JSON.stringify(CASES.map(function (c) { return place.apply(null, c) })));
"""


@unittest.skipUnless(shutil.which("node"), "node not installed")
class ParkEnd(unittest.TestCase):
    """#727: the window is mapped again when the notch park ends, and only
    then (not on Omarchy's own bar toggle, not on the NOTCH or FullPanel bars).
    The patch's own notchRoleFor and notchParkEnd run per window as QML runs
    them: notchParkEnd at the window's start and on each notchRoleChanged."""

    JS = r"""
const root = { position: "top", notchParked: false, notchParkedScreen: "Virtual-1",
               notchPanelOn: false, notchPanelScreen: "Virtual-1", barHidden: false };
function notchRoleFor(s) { with (root) { ROLE } }
function win(name) {
  const w = { screen: { name: name }, notchRole: "" };
  const r = { remapping: false, roleWas: "", remaps: 0 };
  r.notchParkEnd = function () { with (r) { const barWindow = w; PARKEND } };
  w.update = function () {
    const role = notchRoleFor(w.screen);
    if (role === w.notchRole) return;
    w.notchRole = role; r.remapping = false; r.notchParkEnd(); if (r.remapping) r.remaps++;
  };
  w.notchRole = notchRoleFor(w.screen); r.notchParkEnd();
  return { w: w, r: r };
}
const steps = STEPS;
const wins = {};
for (const st of steps) {
  if (st.window) { wins[st.window] = win(st.window); continue; }
  Object.assign(root, st.set);
  for (const k in wins) wins[k].w.update();
}
const out = {};
for (const k in wins) out[k] = wins[k].r.remaps;
console.log(JSON.stringify(out));
"""

    def remaps(self, steps, text=None):
        text = text or patched()
        js = (self.JS.replace("ROLE", function(text, "notchRoleFor")).replace("PARKEND", function(text, "notchParkEnd"))
              .replace("STEPS", json.dumps(steps)))
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_the_notch_unpark_maps_the_bar_again(self):
        out = self.remaps([{"window": "Virtual-1"}, {"window": "NOTCH"},
                           {"set": {"notchParked": True}}, {"set": {"notchParked": False}},
                           {"set": {"notchParked": True}}, {"set": {"notchParked": False}}])
        self.assertEqual(out, {"Virtual-1": 2, "NOTCH": 0})

    def test_a_bar_started_parked_too(self):
        out = self.remaps([{"set": {"notchParked": True}}, {"window": "Virtual-1"}, {"set": {"notchParked": False}}])
        self.assertEqual(out, {"Virtual-1": 1})

    def test_not_on_omarchys_own_bar_toggle(self):
        steps = [{"window": "Virtual-1"}, {"window": "Virtual-2"}, {"window": "NOTCH"}]
        steps += [{"set": {"barHidden": h}} for h in (True, False, True, False)]
        self.assertEqual(self.remaps(steps), {"Virtual-1": 0, "Virtual-2": 0, "NOTCH": 0})
        # Hidden by Omarchy while the strip shows: the park's end alone remaps.
        steps = [{"window": "Virtual-1"}, {"set": {"barHidden": True}}, {"set": {"notchParked": True}},
                 {"set": {"barHidden": False}}, {"set": {"barHidden": True}}, {"set": {"notchParked": False}},
                 {"set": {"barHidden": False}}]
        self.assertEqual(self.remaps(steps), {"Virtual-1": 1})

    def test_not_on_the_notch_or_fullpanel_bars(self):
        steps = [{"window": "Virtual-1"}, {"window": "NOTCH"},
                 {"set": {"notchPanelOn": True}}, {"set": {"notchPanelOn": False}},
                 {"set": {"notchPanelOn": True}}, {"set": {"barHidden": True}}, {"set": {"barHidden": False}},
                 {"set": {"notchPanelOn": False}}, {"set": {"notchParked": True}}]
        self.assertEqual(self.remaps(steps), {"Virtual-1": 0, "NOTCH": 0})
        # The park moving to another output ends it on the first one only.
        steps = [{"window": "Virtual-1"}, {"window": "Virtual-2"}, {"set": {"notchParked": True}},
                 {"set": {"notchParkedScreen": "Virtual-2"}}, {"set": {"notchParked": False}}]
        self.assertEqual(self.remaps(steps), {"Virtual-1": 1, "Virtual-2": 1})

    def test_wired_to_the_role_in_every_omarchy(self):
        # The window's remap item runs it at its start and on each role change,
        # and nothing else in the window remaps on a park change.
        for bar in SHELLS:
            with self.subTest(omarchy=bar.parts[-5]):
                d = pathlib.Path(tempfile.mkdtemp())
                self.addCleanup(shutil.rmtree, d)
                f = d / "Bar.qml"
                f.write_text(bar.read_text())
                self.assertEqual(patch_file(f).returncode, 0)
                full = f.read_text()
                item = re.search(r"\n    Item \{\n      id: notchRemap\n(.*?)\n    \}\n", full, re.S).group(1)
                self.assertIn("      Component.onCompleted: { note(); notchParkEnd() }\n", item)
                self.assertIn("        target: barWindow\n        function onNotchRoleChanged() { notchRemap.notchParkEnd() }\n", item)
                self.assertEqual(full.count("notchParkEnd()"), 3)   # its definition, the start, the role change
                self.assertNotIn("onParkedChanged", full)
                self.assertEqual(self.remaps([{"window": "Virtual-1"}, {"set": {"notchParked": True}},
                                              {"set": {"notchParked": False}}], full), {"Virtual-1": 1})


@unittest.skipUnless(shutil.which("node"), "node not installed")
class SkipTheNotch(unittest.TestCase):
    """Skip the notch's layout (notchSkipPlace) on a MacBook Air 13" bar:
    1470 pt wide, the housing at 640.5-829.5, Omarchy's margins 8, the gap 8
    a jumped item keeps to the housing, the room kept from the other side's
    items 24. An item stays on its side while it does not reach under the
    housing."""

    W, PAD, HOUSING, EDGE, GAP, KEEP = 1470, 8, [640.5, 829.5], 6, 8, 24

    def place(self, *cases, places=False, body=None):
        body = body or function(patched(), "notchSkipPlace")
        args = [[self.W, self.PAD, left, right, housing or self.HOUSING, beside or [0, 0], self.EDGE, self.GAP, self.KEEP]
                for left, right, housing, beside in cases]
        js = SKIP.replace("BODY", body).replace("CASES", json.dumps(args))
        out = json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)
        for r in out:
            if r:
                r.pop("state", None)
        if not places:   # each item's place on the bar (n): test_places_on_the_bar
            for r in out:
                for s in (r or {}).get("left", []) + (r or {}).get("right", []):
                    s.pop("n")
        return out

    def one(self, left, right, housing=None, beside=None):
        return self.place((left, right, housing, beside))[0]

    def shown(self, out, side, natural):
        """Where each item shows: [start, hidden]."""
        return [[n + s["x"], s["hidden"]] for n, s in zip(natural, out[side])]

    def starts_left(self, left):
        x, out = self.PAD, []
        for w in left:
            out.append(x)
            x += w
        return out

    def starts_right(self, right):
        x, out = self.W - self.PAD, [0] * len(right)
        for i in range(len(right) - 1, -1, -1):
            x -= right[i]
            out[i] = x
        return out

    def test_everything_fits_nothing_moves(self):
        r = self.one([20, 120], [30, 120, 150])
        self.assertEqual([s["x"] for s in r["left"] + r["right"]], [0] * 5)
        self.assertFalse(any(s["hidden"] for s in r["left"] + r["right"]))
        self.assertEqual((r["jumped"], r["hidden"]), (0, 0))

    def test_tray_overflow_continues_left_of_the_housing(self):
        right = [24] * 30 + [150]          # 30 tray icons and the clock
        r = self.one([20, 120], right)
        got = self.shown(r, "right", self.starts_right(right))
        # Items 0-9 would reach under the housing (start < 829.5): they
        # continue left of it, in order, the last one 8 from the housing.
        for i in range(10):
            self.assertEqual(got[i], [632.5 - 24 * (10 - i), False], i)
        for i in range(10, 31):
            self.assertEqual(r["right"][i], {"x": 0, "hidden": False}, i)
        self.assertGreaterEqual(got[10][0], 829.5)
        self.assertEqual((r["jumped"], r["hidden"]), (10, 0))

    def test_workspaces_overflow_continue_right_of_the_housing(self):
        left = [20] + [26] * 30            # the menu and 30 workspaces
        r = self.one(left, [150])
        got = self.shown(r, "left", self.starts_left(left))
        # Workspaces 1-23 end before 640.5; 24-30 go on 8 right of the housing.
        self.assertTrue(all(s == {"x": 0, "hidden": False} for s in r["left"][:24]))
        for k, i in enumerate(range(24, 31)):
            self.assertEqual(got[i], [837.5 + 26 * k, False], i)
        self.assertEqual((r["jumped"], r["hidden"]), (7, 0))

    def test_both_sides_full_hide_and_never_overlap(self):
        left = [20] + [26] * 30
        right = [24] * 30 + [150]
        r = self.one(left, right)
        # Each side is full up to the housing, so nothing that jumped has its
        # 24 pt there: all of them hide; what stays is where Omarchy has it.
        self.assertEqual(r["jumped"], 0)
        self.assertEqual(r["hidden"], 7 + 10)
        self.assertTrue(all(s["hidden"] for s in r["left"][24:] + r["right"][:10]))
        self.assertFalse(any(s["hidden"] or s["x"] for s in r["left"][:24] + r["right"][10:]))
        # Hidden items fade at the housing on their own side.
        lgot = self.shown(r, "left", self.starts_left(left))
        rgot = self.shown(r, "right", self.starts_right(right))
        self.assertTrue(all(abs(lgot[i][0] + 26 - 632.5) < 1e-9 for i in range(24, 31)))
        self.assertTrue(all(rgot[i][0] == 837.5 for i in range(10)))

    def test_24_pt_from_the_other_sides_items(self):
        # The left side ends at 8 + 20 + 90 = 118. One wide item that does not
        # fit right of the housing: shown when it starts 24 after that, hidden
        # half a point closer.
        fits, close = self.place(([20, 90], [490.5, 150], None, None), ([20, 90], [491, 150], None, None))
        self.assertEqual(self.shown(fits, "right", self.starts_right([490.5, 150]))[0], [142, False])
        self.assertTrue(close["right"][0]["hidden"])
        self.assertEqual((close["jumped"], close["hidden"]), (0, 1))
        # The same for the left side: the right side's own items start at 1312.
        w = 1312 - 24 - 837.5
        fits, close = self.place(([20, 580, w], [150], None, None), ([20, 580, w + 0.5], [150], None, None))
        self.assertEqual(self.shown(fits, "left", self.starts_left([20, 580, w]))[2], [837.5, False])
        self.assertTrue(close["left"][2]["hidden"])

    def test_once_one_hides_the_rest_hides_too(self):
        # Three items do not fit right of the housing. Left of it there is room
        # from 428 + 24 to 632.5: the 150 one fits, the 200 one does not, and
        # the small 10 one after it would, but hides too, so the order stays.
        r = self.one([20, 400], [10, 200, 150, 400, 150])
        self.assertEqual([s["hidden"] for s in r["right"]], [True, True, False, False, False])
        self.assertEqual(self.shown(r, "right", self.starts_right([10, 200, 150, 400, 150]))[2], [482.5, False])
        self.assertEqual((r["jumped"], r["hidden"]), (1, 2))

    def test_centre_widgets_beside_the_housing(self):
        # The clock as Omarchy's centre anchor, right of the housing (100 wide),
        # and a widget before it, left of it (60 wide): the sides end there.
        wall_l, wall_r = 640.5 - 6 - 60, 829.5 + 6 + 100
        # Many workspaces: 21 end before wall_l, 4 go on 8 after the clock.
        left = [20] + [26] * 25
        r = self.one(left, [24] * 5 + [150], beside=[60, 100])
        got = self.shown(r, "left", self.starts_left(left))
        self.assertLessEqual(got[21][0] + 26, wall_l)
        self.assertEqual([g for g, s in zip(got, r["left"]) if s["x"]], [[wall_r + 8 + 26 * k, False] for k in range(4)])
        # Many tray icons: 10 no longer fit after the clock; they go on 8
        # before the widget left of the housing.
        right = [24] * 25 + [150]
        r = self.one([20, 100], right, beside=[60, 100])
        got = self.shown(r, "right", self.starts_right(right))
        self.assertGreaterEqual(got[10][0], wall_r)
        self.assertEqual([g for g, s in zip(got, r["right"]) if s["x"]], [[wall_l - 8 - 24 * (10 - i), False] for i in range(10)])

    def test_overflow_clear_of_the_indicators_peek(self):
        # Omarchy 4.5: the indicators left of the housing (60 at rest) open
        # their hidden ones (84) towards the bar's start on a peek, over what
        # lies there, and take its hover. The right side's overflow keeps
        # clear of that room; the left side's own items and everything that
        # fits are as before.
        wall_l, wall_r = 640.5 - 6 - 60, 829.5 + 6 + 100
        right = [24] * 25 + [150]
        r = self.one([20, 100], right, beside=[60, 100, 84])
        got = self.shown(r, "right", self.starts_right(right))
        self.assertEqual([g for g, s in zip(got, r["right"]) if s["x"]], [[wall_l - 84 - 8 - 24 * (10 - i), False] for i in range(10)])
        left = [20] + [26] * 25
        self.assertEqual(self.one(left, [24] * 5 + [150], beside=[60, 100, 84]), self.one(left, [24] * 5 + [150], beside=[60, 100]))
        self.assertEqual(self.one([20, 100], [24] * 5 + [150], beside=[60, 100, 84]),
                         self.one([20, 100], [24] * 5 + [150], beside=[60, 100]))

    def test_workspaces_growing_and_shrinking(self):
        counts = [10, 22, 23, 24, 30, 24, 23, 10]
        rs = self.place(*[([20] + [26] * n, [150], None, None) for n in counts])
        jumped = [r["jumped"] for r in rs]
        self.assertEqual(jumped, [0, 0, 0, 1, 7, 1, 0, 0])
        # Back to Omarchy's places once they fit again.
        self.assertTrue(all(s == {"x": 0, "hidden": False} for s in rs[-1]["left"]))

    def test_the_clock_and_the_menu_stay_at_the_edges(self):
        # Far too much on both sides: the outermost items never move.
        r = self.one([900, 26, 26], [24, 24, 900])
        self.assertEqual(r["left"][0], {"x": 0, "hidden": False})
        self.assertEqual(r["right"][-1], {"x": 0, "hidden": False})
        # A single item per side stays too.
        r = self.one([1400], [1400])
        self.assertEqual((r["left"], r["right"]), ([{"x": 0, "hidden": False}], [{"x": 0, "hidden": False}]))

    def test_empty_items_take_no_room_and_are_not_counted(self):
        right = [24] * 11 + [0, 0] + [24] * 19 + [150]
        r = self.one([20, 120], right)
        self.assertEqual(r["jumped"], 10)

    def test_places_on_the_bar(self):
        # n: Omarchy's place of each item on the bar, as its rows lay them out
        # (the item glides between places on the bar, not in its row).
        left, right = [20] + [26] * 30, [24] * 30 + [150]
        r = self.place((left, right, None, None), places=True)[0]
        self.assertEqual([s["n"] for s in r["left"]], self.starts_left(left))
        self.assertEqual([s["n"] for s in r["right"]], self.starts_right(right))

    # Omarchy's indicators: [width now, at rest, their hidden ones]. At rest
    # 21 (an active one), 84 hidden; peeking (hovered on this bar or another:
    # Omarchy shares the peek between bars) 105.
    def ind(self, open_):
        return [105 if open_ else 21, 21, 84]

    def shows(self, r):
        return [[round(s["n"] + s["x"], 3), s["hidden"]] for s in r["left"] + r["right"]]

    def onep(self, left, right, beside=None):
        return self.place((left, right, None, beside), places=True)[0]

    # The user's right list on a MacBook Air (tray, weather, the indicators,
    # spotify ... clock): Omarchy puts the tray at 830.3, 0.8 pt off the housing.
    def user_right(self, open_):
        return [81, 21, self.ind(open_), 27, 133, 27, 27, 27.2, 27, 27, 27, 27, 27, 132.5]

    def omarchy(self, left, right):
        """Where Omarchy's own rows put each item (no Skip the notch)."""
        w = lambda e: e[0] if isinstance(e, list) else e
        return [[x, False] for x in self.starts_left([w(e) for e in left]) + self.starts_right([w(e) for e in right])]

    def test_at_rest_the_bar_is_omarchys(self):
        # The user's bar (MacBook Air): the tray 5.8 pt from the housing stays;
        # no room is kept for the indicators' hidden ones.
        left, right = [27, 105.5], self.user_right(False)
        r = self.onep(left, right)
        self.assertEqual(round(r["right"][0]["n"], 3), 830.3)
        self.assertEqual(self.shows(r), self.omarchy(left, right))
        self.assertEqual((r["jumped"], r["hidden"]), (0, 0))

    def test_hidden_indicators_open_in_place_when_they_fit(self):
        # Room right of the housing: they open where they are, as Omarchy
        # opens them (the items inside them make way), nothing jumps.
        left, right = [27, 105.5], [54, 21, self.ind(True), 150]
        r = self.onep(left, right)
        self.assertEqual(self.shows(r), self.omarchy(left, right))
        self.assertNotIn("peekAt", r["right"][2])
        self.assertEqual((r["jumped"], r["hidden"]), (0, 0))

    def test_hidden_indicators_open_left_of_the_housing_when_they_do_not(self):
        # The user's bar: the tray and the weather stay where they are at
        # rest; the hidden indicators would push them under the housing, so
        # they open left of it, 8 from it, growing to the left.
        left = [27, 105.5]
        right = self.user_right
        rest, peek = self.place((left, right(False), None, None), (left, right(True), None, None), places=True)
        self.assertEqual(self.shows(rest), self.omarchy(left, right(False)))
        self.assertEqual(peek["right"][2]["peekAt"], 640.5 - 8 - 84)
        self.assertFalse(peek["right"][2]["peekHidden"])
        self.assertEqual(rest["right"][2]["peekAt"], peek["right"][2]["peekAt"])
        # Nothing else moves; the indicators' visible part stays (their right end).
        a, b = self.shows(rest), self.shows(peek)
        for i in range(len(a)):
            if i != len(left) + 2:
                self.assertEqual(a[i], b[i], i)
        ra, rb = rest["right"][2], peek["right"][2]
        self.assertEqual(ra["n"] + ra["x"] + 21, rb["n"] + rb["x"] + 105)

    def test_hidden_indicators_hide_when_the_left_side_is_full(self):
        # The workspaces leave no 24 pt left of the hidden ones' place.
        left = [27] + [26] * 19          # ends at 529: 548.5 - 529 < 24
        r = self.onep(left, self.user_right(True))
        self.assertTrue(r["right"][2]["peekHidden"])
        self.assertEqual(r["right"][2]["peekAt"], 640.5 - 8 - 84)
        left = [27] + [26] * 16          # ends at 451: 548.5 - 451 = 97.5 >= 24
        r = self.onep(left, self.user_right(True))
        self.assertFalse(r["right"][2]["peekHidden"])

    def test_a_tray_too_wide_even_without_them(self):
        # The tray jumps at rest (the original rule); the hidden indicators
        # then open left of it, and hide when there is no room left of that.
        # The weather stays at 870, so the hidden ones (84) have no room right
        # of the housing; the tray (300) is under it at rest and jumps.
        right = lambda o: [300, 21, self.ind(o), 400, 150]
        r = self.onep([27, 105.5], right(True))
        tray = r["right"][0]
        self.assertTrue(tray["x"] < 0 and not tray["hidden"])
        tray_at = tray["n"] + tray["x"]
        self.assertEqual(tray_at + 300, 640.5 - 8)
        self.assertEqual(r["right"][2]["peekAt"], tray_at - 84)
        self.assertFalse(r["right"][2]["peekHidden"])
        r = self.onep([27] + [26] * 8, right(True))   # the workspaces end at 243
        self.assertTrue(r["right"][2]["peekHidden"])
        # Once the tray has jumped, a right side with room opens them in place.
        r = self.onep([27, 105.5], [400, 21, self.ind(True), 27, 133, 150])
        self.assertNotIn("peekAt", r["right"][2])

    def test_where_they_open_never_depends_on_their_own_peek(self):
        # Stateless: open or not (a hover on this bar, an external one, the
        # strip), the same items jump and hide, the hidden ones get the same
        # place, everything else shows at the same place.
        user = [81, 21, "I", 27, 133, 27, 27, 27.2, 27, 27, 27, 27, 27, 132.5]
        cases = [([27, 105.5], [54, 21, "I", 150]), ([27, 105.5], user), ([27] + [26] * 19, user),
                 ([27, 105.5], [300, 21, "I", 400, 150]), ([27, 105.5], [81, 21, "I", 27, 133, 150]),
                 ([27, 105.5], [400, 21, "I", 27, 133, 150]), ([27] + [26] * 19, [81, 21, "I", 27, 133, 150]),
                 ([27] + [26] * 30, [300, 21, "I", 27, 133, 150]), ([27, 105.5], [24] * 30 + ["I", 150])]
        for left, right in cases:
            with self.subTest(left=len(left), right=right[:3]):
                fill = lambda o: [self.ind(o) if e == "I" else e for e in right]
                a, b = self.place((left, fill(False), None, None), (left, fill(True), None, None), places=True)
                k = right.index("I")
                self.assertEqual((a["jumped"], a["hidden"]), (b["jumped"], b["hidden"]))
                self.assertEqual((a["right"][k].get("peekAt"), a["right"][k].get("peekHidden")),
                                 (b["right"][k].get("peekAt"), b["right"][k].get("peekHidden")))
                in_place = "peekAt" not in a["right"][k]
                sa, sb = self.shows(a), self.shows(b)
                for i in range(len(sa)):
                    if i == len(left) + k:
                        continue
                    j = i - len(left)
                    if in_place and 0 <= j < k and a["right"][j]["x"] == 0 and not a["right"][j]["hidden"]:
                        # In place: the items inside them make way, as in Omarchy.
                        self.assertEqual(sb[i][0], sa[i][0] - 84)
                    else:
                        self.assertEqual(sa[i], sb[i], i)

    def test_no_indicators_no_peek(self):
        r = self.one([27, 105.5], [81, 21, 27, 133, 150])
        self.assertFalse(any("peekAt" in s or s.get("peekHidden") for s in r["right"]))

    def test_a_slot_places_its_row_before_it_shifts(self):
        # The parked copy (1 px tall) draws no frame when the indicators open,
        # so Omarchy's row kept its old places under the new shift (Omanotch's
        # clicks went to the wrong items until its next frame). Both shells.
        for bar in SHELLS:
            d = pathlib.Path(tempfile.mkdtemp())
            try:
                f = d / "Bar.qml"
                f.write_text(bar.read_text())
                subprocess.run([sys.executable, str(PATCH), str(f)], check=True, capture_output=True)
                text = f.read_text()
            finally:
                shutil.rmtree(d)
            with self.subTest(omarchy=bar.parts[-5]):
                m = re.search(r"    onNotchShiftChanged: \{\n(.*?)\n    \}\n", text, re.S)
                self.assertIsNotNone(m)
                body = m.group(1)
                self.assertIn('parent.forceLayout()', body)
                self.assertLess(body.index("parent.forceLayout()"), body.index("notchShownX ="))
                self.assertLess(body.index("parent.ensurePolished()"), body.index("notchShownX ="))
                if is_45(text):
                    # 4.5: the slot sits right in Omarchy's GridLayout (a
                    # delegate of its Repeater); Qt's ensurePolished lays it out.
                    m = re.search(r"  component ModuleList: GridLayout \{\n(.*?)\n  \}\n", text, re.S)
                    self.assertIsNotNone(m)
                    self.assertRegex(m.group(1), r"\n    Repeater \{\n(?:.*\n){0,30}        DelegateChoice \{\n          ModuleSlot \{")
                    continue
                # The slot sits right in Omarchy's Row (or Column): forceLayout is theirs.
                m = re.search(r"id: horizontalModuleList\n\n      Row \{\n(.*?)\n    Component \{", text, re.S)
                self.assertIsNotNone(m)
                self.assertRegex(m.group(1), r"\n        Repeater \{\n(?:.*\n){0,3}          ModuleSlot \{")

    def test_the_real_shells_have_the_same_layout(self):
        # The layout function as both Omarchy shells' patched bars have it.
        mine = function(patched(), "notchSkipPlace")
        for bar in SHELLS:
            d = pathlib.Path(tempfile.mkdtemp())
            try:
                f = d / "Bar.qml"
                f.write_text(bar.read_text())
                subprocess.run([sys.executable, str(PATCH), str(f)], check=True, capture_output=True)
                body = function(f.read_text(), "notchSkipPlace")
            finally:
                shutil.rmtree(d)
            with self.subTest(omarchy=bar.parts[-5]):
                self.assertEqual(body, mine)

    def test_the_peek_block_is_found(self):
        # Omarchy's indicators in both shells: the horizontal row's hidden
        # block, not the vertical one's; nothing in other widgets.
        js = """
function peek(item, depth) { BODY }
var notchPeekBlockIn = peek;
var block = { indicatorBlock: "inactive", horizontal: true, implicitWidth: 84, children: [] };
var vblock = { indicatorBlock: "inactive", horizontal: false, implicitWidth: 30, children: [] };
var active = { indicatorBlock: "active", horizontal: true, children: [] };
var mac = { revealInactiveIndicators: false, children: [
  { children: [ { children: [] }, { width: 0, children: [block] }, active ] },
  { children: [ { width: 0, children: [vblock] } ] } ] };
var upstream = { revealInactiveIndicators: false, children: [ { item: null, children: [ { children: [ { children: [
  { width: 0, children: [block] }, active ] } ] } ] } ] };
var deep = { children: [] }, at = deep;
for (var i = 0; i < 12; i++) { var n = { children: [] }; at.children.push(n); at = n; }
at.children.push(block);
var clock = { children: [ { children: [ { text: "Tue" } ] } ] };
console.log(JSON.stringify([peek(mac, 0) === block, peek(upstream, 0) === block, peek(deep, 0), peek(clock, 0), peek(null, 0)]));
"""
        body = function(patched(), "notchPeekBlockIn")
        out = subprocess.run(["node", "-e", js.replace("BODY", body)], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [True, True, None, None, None])

    def test_their_width_at_rest_is_found(self):
        js = """
function act(area) { BODY }
var area = {}, active = { indicatorModel: [], implicitWidth: 21 }, row = { children: [area, active] };
area.parent = row;
var lone = {}; lone.parent = { children: [lone] };
console.log(JSON.stringify([act(area) === active, act(lone), act(null)]));
"""
        body = function(patched(), "notchPeekActiveIn")
        out = subprocess.run(["node", "-e", js.replace("BODY", body)], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [True, None, None])

    def test_omarchys_indicators_still_peek_this_way(self):
        # What the bar relies on, in Omarchy's own Indicators.qml of both
        # shells: a clipping item as wide as the hidden block only while they
        # peek, the block a horizontal "inactive" IndicatorBlock in it.
        for bar in SHELLS:
            ind = (bar.parent / "widgets" / "Indicators.qml").read_text()
            with self.subTest(omarchy=bar.parts[-5]):
                self.assertIn("readonly property bool revealInactiveIndicators:", ind)
                area = re.search(r"id: inactiveHorizontalArea\n(.*?)\n\s*IndicatorBlock \{\n(.*?)\n\s*\}", ind, re.S)
                self.assertIsNotNone(area)
                self.assertIn("implicitWidth: root.revealInactiveIndicators ? inactiveHorizontalBlock.implicitWidth : 0", area.group(1))
                self.assertIn("width: implicitWidth", area.group(1))
                self.assertIn("clip: true", area.group(1))
                self.assertIn('indicatorBlock: "inactive"', area.group(2))
                self.assertIn("horizontal: true", area.group(2))
                self.assertIn('property string indicatorBlock: "active"', ind)
                # Their width at rest is the block of the ones that show, the
                # area's sibling in the same row (notchPeekActiveIn).
                self.assertRegex(ind, r": activeHorizontalBlock\.implicitWidth \+ inactiveHorizontalArea\.implicitWidth")
                row = re.search(r"id: inactiveHorizontalArea\n.*?\n\s*ActiveIndicatorBlock \{\n\s*id: activeHorizontalBlock", ind, re.S)
                self.assertIsNotNone(row)
                self.assertIn("property var indicatorModel: null", ind)

    def test_no_housing_no_layout(self):
        self.assertEqual(self.place(([20], [150], [0, 0], None), ([20], [150], [900, 800], None),
                                    ([20], [150], [600, 1500], None)), [None, None, None])


HOVER = r"""
var calls = [];
var root = {
  notchHovering: false, barHidden: false, notchFullscreen: false,
  setCenterSectionHovered: function(h) { calls.push("center " + h) },
  setBarHovered: function(h) { calls.push("bar " + h) },
  notchTargetAt: function(x, y) { return x >= 100 && x < 130 ? {} : null },
  notchTraySet: function(open, name, region) { closed++ },
};
var closed = 0;
root.notchHover = function(x) { %s };
var out = [];
%s.forEach(function(x) { calls = []; out.push([root.notchHover(x), calls]) });
console.log(JSON.stringify(out));
"""


AIR = "OMACVM_FULLPANEL=640.5x829.5x37.0x1470.0x956.0"
AIR_ENV = AIR


def layout(builtin="Virtual-1", height=950, width=1470, fullscreen=True, others=()):
    outs = [{"output": builtin, "x": 0, "y": 0, "width": width, "height": height, "scale": 2}]
    outs += [{"output": o, "x": -1920, "y": 0, "width": 1920, "height": 1080, "scale": 1} for o in others]
    return json.dumps({"layout": outs, "external": True, "fullscreen": fullscreen, "builtin": builtin})


@unittest.skipUnless(shutil.which("node"), "node not installed")
class FullPanel(unittest.TestCase):
    """OmacVM.app's FullPanel (#339): the bar on the built-in display sits in
    the strip when the app's full screen covers it. No notched Mac needed:
    host.env and the app's layout message are made up (a MacBook Air 13")."""

    START = Behaviour.START
    run_js = Behaviour.run_js
    ticks = Behaviour.ticks

    def test_parse(self):
        r = self.run_js({"hostenv": "OMACVM_HDR=1\n" + AIR + "\nOMACVM_NOTCHPOINTER=1\n", "layout": layout()}, self.ticks(1))
        self.assertEqual(r["panel"], [640.5, 829.5, 37, 1470, 956])
        for bad in ("OMACVM_FULLPANEL=1", "OMACVM_FULLPANEL=0x829.5x37x1470x956", "OMACVM_FULLPANEL=900x800x37x1470x956",
                    "OMACVM_FULLPANEL=640x830x5x1470x956", "OMACVM_FULLPANEL=100x1300x37x1470x956",
                    "OMACVM_FULLPANEL=640x830x37x1470", "OMACVM_FULLPANEL=640x830x37x1470x956x1", "XOMACVM_FULLPANEL=640x830x37x1470x956"):
            r = self.run_js({"hostenv": bad + "\n", "layout": layout()}, self.ticks(1))
            self.assertEqual(r["panel"], [], bad)
            self.assertFalse(r["panels"][0]["on"], bad)

    def test_in_the_strip_at_the_macs_scale(self):
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout()}, self.ticks(1))
        self.assertEqual(r["panels"][0], {"on": True, "screen": "Virtual-1"})
        self.assertEqual((r["root"]["notchLeft"], r["root"]["notchRight"], r["root"]["notchHeight"]), (640.5, 829.5, 37))

    def test_in_the_strip_at_another_guest_scale(self):
        # Omarchy at 1.25 on the Air's 2940 px: 2352 logical pixels wide.
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout()}, self.ticks(1),
                        screens=[{"name": "Virtual-1", "width": 2352, "height": 1520}])
        k = 2352 / 1470
        self.assertTrue(r["panels"][0]["on"])
        self.assertAlmostEqual(r["root"]["notchLeft"], 640.5 * k)
        self.assertAlmostEqual(r["root"]["notchRight"], 829.5 * k)
        self.assertAlmostEqual(r["root"]["notchHeight"], 37 * k)

    def test_pro_and_air_at_2x_and_1_6x(self):
        # The housing differs per model (a 16-inch Pro's strip is taller than
        # an Air's): never one height, always the numbers of this start, in
        # the guest's logical pixels at its own scale (2x and 1.6x here).
        pro = "OMACVM_FULLPANEL=765.0x963.0x43.0x1728.0x1117.0"
        cases = [(AIR, 1470, 956, 2.0), (AIR, 1470, 956, 1.6), (pro, 1728, 1117, 2.0), (pro, 1728, 1117, 1.6)]
        strips = {}
        for env, w, d, scale in cases:
            g = [float(x) for x in env.split("=")[1].split("x")]
            px_w = w * 2                      # the Mac's pixels (Retina)
            lw = px_w / scale                 # Omarchy's scale in the guest
            r = self.run_js({"hostenv": env + "\n", "layout": layout(width=w, height=d - 4)}, self.ticks(1),
                            screens=[{"name": "Virtual-1", "width": lw, "height": d * 2 / scale}])
            k = lw / g[3]
            self.assertTrue(r["panels"][0]["on"], (env, scale))
            self.assertAlmostEqual(r["root"]["notchLeft"], g[0] * k, msg=(env, scale))
            self.assertAlmostEqual(r["root"]["notchRight"], g[1] * k, msg=(env, scale))
            self.assertAlmostEqual(r["root"]["notchHeight"], g[2] * k, msg=(env, scale))
            strips[(g[2], scale)] = r["root"]["notchHeight"]
        # The Pro's strip is taller than the Air's at the same scale, and a
        # smaller scale makes the same strip more logical pixels.
        self.assertGreater(strips[(43.0, 2.0)], strips[(37.0, 2.0)])
        self.assertGreater(strips[(37.0, 1.6)], strips[(37.0, 2.0)])

    def test_never_guesses_a_park(self):
        # The last native session ended with Omanotch's strip: a FullPanel
        # boot does not park the bar for a strip that will not come.
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout(), "expect": "1 Virtual-1\n",
                         "park": "1 Virtual-1\n", "beat": str(self.START - 500)}, self.ticks(3))
        self.assertFalse(any(x["parked"] for x in r["seen"]), r["seen"])
        self.assertTrue(all(p["on"] for p in r["panels"]))
        self.assertNotIn("expect", r["written"])

    def test_below_the_notch_is_the_normal_bar(self):
        # QEMU fell back (a private part missing, the menu bar always shown):
        # the window is a whole strip shorter. The clean size's few rows are not.
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout(height=956 - 37 - 4)}, self.ticks(1))
        self.assertFalse(r["panels"][0]["on"])
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout(height=956 - 6)}, self.ticks(1))
        self.assertTrue(r["panels"][0]["on"])

    def test_windowed_is_the_normal_bar(self):
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout(fullscreen=False, height=956, width=1470)}, self.ticks(1))
        self.assertFalse(r["panels"][0]["on"])

    def test_no_layout_yet_waits(self):
        r = self.run_js({"hostenv": AIR + "\n"}, self.ticks(1))
        self.assertFalse(r["panels"][0]["on"])
        r = self.run_js({"hostenv": AIR + "\n", "layout": "{not json"}, self.ticks(1))
        self.assertFalse(r["panels"][0]["on"])

    def test_external_display_holds_the_main_window(self):
        # The MacBook's display is Virtual-2; Virtual-1 is the external one.
        screens = [{"name": "Virtual-1", "width": 1920, "height": 1080}, {"name": "Virtual-2", "width": 1470, "height": 956}]
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout(builtin="Virtual-2", others=("Virtual-1",))},
                        self.ticks(1), screens=screens)
        self.assertEqual(r["panels"][0], {"on": True, "screen": "Virtual-2"})
        self.assertEqual(r["root"]["notchLeft"], 640.5)  # Virtual-2's width, not Virtual-1's

    def test_plug_and_unplug_while_running(self):
        screens1 = [{"name": "Virtual-1", "width": 1470, "height": 956}]
        screens2 = [{"name": "Virtual-1", "width": 1920, "height": 1080}, {"name": "Virtual-2", "width": 1470, "height": 956}]
        steps = self.ticks(1) + [
            # An external display comes and takes the main window: the MacBook's is Virtual-2.
            {"tick": True, "at": self.START + 3000, "screens": screens2,
             "files": {"layout": layout(builtin="Virtual-2", others=("Virtual-1",))}},
            # For a moment the MacBook's output is not in full screen yet.
            {"tick": True, "at": self.START + 6000, "files": {"layout": layout(builtin="Virtual-2", fullscreen=False)}},
            {"tick": True, "at": self.START + 9000, "files": {"layout": layout(builtin="Virtual-2", others=("Virtual-1",))}},
            # Unplugged: back to Virtual-1 alone.
            {"tick": True, "at": self.START + 12000, "screens": screens1, "files": {"layout": layout()}},
            # Lid closed with an external display: no built-in output at all.
            {"tick": True, "at": self.START + 15000, "screens": [{"name": "Virtual-1", "width": 1920, "height": 1080}],
             "files": {"layout": json.dumps({"layout": [{"output": "Virtual-1", "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1}],
                                             "external": True, "fullscreen": True})}},
        ]
        r = self.run_js({"hostenv": AIR + "\n", "layout": layout()}, steps, screens=screens1)
        self.assertEqual([(p["on"], p["screen"]) for p in r["panels"]],
                         [(True, "Virtual-1"), (True, "Virtual-2"), (False, "Virtual-2"), (True, "Virtual-2"),
                          (True, "Virtual-1"), (False, "Virtual-1")])

    def test_native_boot_ignores_the_layout(self):
        # No OMACVM_FULLPANEL: Omanotch's behaviour as before.
        r = self.run_js({"layout": layout(height=956), "expect": "1 Virtual-1\n"}, self.ticks(1))
        self.assertFalse(r["panels"][0]["on"])
        self.assertEqual(r["seen"][0], {"parked": True, "screen": "Virtual-1"})


class FullPanelLayout(unittest.TestCase):
    """The bar's QML for FullPanel (structure: no Quickshell here)."""

    def setUp(self):
        self.text = patched()

    def test_role_before_parked(self):
        body = function(self.text, "notchRoleFor")
        self.assertLess(body.index('"fullpanel"'), body.index('"parked"'))
        self.assertIn('notchPanelOn && n === notchPanelScreen', body)

    def test_strip_height_and_reserved(self):
        # The bar is the strip's height (not the output's: outH 0), so its
        # exclusive zone keeps the strip free; parked never in FullPanel
        # (a hidden bar still reserves the strip, see below).
        self.assertIn("root.notchBox(0, root.notchHeight, 0, root.barSize,", self.text)
        self.assertIn('notchRole === "fullpanel" ? notchPanelFit[0]', self.text)

    def prop(self, name):
        # The expression, also over continuation lines (indented further).
        m = re.search(r"readonly property bool %s: (.*(?:\n {10,}\S.*)*)" % name, self.text)
        return " ".join(m.group(1).split()) if m else "false"

    def state(self, role, hidden, fullscreen):
        """black, clear, parked of a bar copy, from the patch's own expressions."""
        env = {"notchRole": role, "barHidden": hidden, "notchFullscreen": fullscreen}
        for name in ("notchBlack", "notchClear", "parked"):
            js = self.prop(name).replace("===", "==").replace("&&", " and ").replace("||", " or ")
            js = re.sub(r"!(?!=)", " not ", js).replace("root.", "").replace("barWindow.", "")
            js = re.sub(r"\bfalse\b", "False", re.sub(r"\btrue\b", "True", js))
            env[name] = bool(eval(js, {}, dict(env)))
        return env["notchBlack"], env["notchClear"], env["parked"]

    def test_hidden_bar_shows_the_wallpaper_in_the_strip(self):
        # Super+Shift+Space in FullPanel: the bar stays in the strip (not
        # parked: it keeps reserving it, windows stay below the notch) but is
        # see-through, so the wallpaper reaches the top edge. Not black.
        self.assertEqual(self.state("fullpanel", True, False), (False, True, False))
        self.assertIn('Binding { target: barWindow; property: "color"; value: "transparent"; when: barWindow.notchClear }',
                      self.text)
        self.assertIn("      visible: !barWindow.notchClear\n      sourceComponent:", self.text)
        self.assertIn('visible: barWindow.notchBlack || barWindow.notchClear\n      color: barWindow.notchBlack ? "black" : "transparent"',
                      self.text)
        # The one-pixel repaint dot is the bar's colour: not over the wallpaper.
        self.assertIn('      visible: !barWindow.notchClear\n', self.text)
        self.assertIn('      color: barWindow.color.a < 1 ? "transparent" : barWindow.color\n', self.text)

    def test_shown_bar_and_fullscreen_as_before(self):
        self.assertEqual(self.state("fullpanel", False, False), (False, False, False))   # the bar in the strip
        self.assertEqual(self.state("fullpanel", False, True), (True, False, False))     # black over a video
        self.assertEqual(self.state("fullpanel", True, True), (True, False, False))      # hidden too
        self.assertEqual(self.state("notch", False, True), (True, False, False))
        self.assertEqual(self.state("notch", True, False), (False, False, True))         # NOTCH: Omanotch's wallpaper
        self.assertEqual(self.state("", True, False), (False, False, True))              # Omarchy's own hiding
        self.assertEqual(self.state("", False, False), (False, False, False))
        self.assertEqual(self.state("parked", False, False), (False, False, True))

    def test_above_fullscreen_windows(self):
        self.assertIn('barWindow.notchRole === "notch" || barWindow.notchRole === "fullpanel" ? WlrLayer.Overlay', self.text)

    def test_state_says_fullpanel(self):
        self.assertIn('fullpanel: root.notchPanel.length ? (root.notchPanelOn ? "strip" : "waiting") : "off"', self.text)
        self.assertIn('fullpanel: notchPanel.length ? (notchPanelOn ? "strip" : "waiting") : "off"', self.text)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class FullPanelZone(unittest.TestCase):
    """#758: FullPanel's bar reserves its strip less half of Omarchy's top
    window gap (5 px at most), so windows sit closer under the notch but
    never in the strip; every other role reserves what it did (v40). The
    owner's MacBook Pro 14" at the guest's scale 2: strip 33.5, bar 26,
    gaps_out 10: reserved 29, windows at 29 + 10 + border 2 = 41."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def full(self, stock):
        f = self.dir / "Bar.qml"
        f.write_text(stock)
        out = patch_file(f)
        self.assertEqual(out.returncode, 0, out.stderr)
        return f.read_text()

    def node(self, js):
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def expr(self, text, name):
        """A window property's expression, with its continuation lines."""
        m = re.search(r"^    %s: (.*\n(?:      .*\n)*)" % name, text, re.M)
        return " ".join(m.group(1).split()) if m else None

    def reserved(self, full, stock_height):
        """[role, reserved px or null for none] per role, from the patch's own
        expressions (Quickshell: Ignore = none, Auto = the window's height,
        Normal = exclusiveZone; on 4.0 FullPanel's zone comes from its Binding)."""
        mode = self.expr(full, "exclusionMode")
        zone = self.expr(full, "exclusiveZone")
        binding = re.search(r'    Binding \{\n      target: barWindow; property: "exclusiveZone"; value: (.*)\n'
                            r'      when: (.*); restoreMode: Binding\.RestoreNone\n    \}\n', full)
        js = """
const ExclusionMode = { Ignore: "Ignore", Normal: "Normal", Auto: "Auto" };
const root = { barSize: 26, barHidden: false, notchHeight: 33.5, notchGapsTop: GAPS };
function notchBox(outH, strip, flush, size, scale) { BOX }
function notchPanelZoneFor(size, gapsTop) { ZONEFOR }
root.notchBox = notchBox; root.notchPanelZoneFor = notchPanelZoneFor;
const out = [];
for (const [role, parkedSize] of [["", STOCK], ["parked", 1], ["notch", 34], ["fullpanel", 34]]) {
  const notchPanelFit = notchBox(0, root.notchHeight, 0, root.barSize, 2);
  const barWindow = { notchRole: role, parked: role === "parked", parkedSize: parkedSize, thickness: STOCK,
                      notchPanelFit: notchPanelFit };
  barWindow.notchPanelZone = ZONEPROP;
  const thickness = STOCK;
  const mode = MODE;
  let px = null;
  if (mode === "Auto") px = role === "" ? STOCK : parkedSize;
  if (mode === "Normal") px = ZONE;
  out.push([role, px]);
}
console.log(JSON.stringify(out));
"""
        zoneprop = re.search(r"readonly property int notchPanelZone: (.*)\n", full)
        normal = zone if zone else ("(%s) ? %s : 0" % (binding.group(2), binding.group(1)) if binding else "0")
        js = (js.replace("MODE", mode).replace("ZONEPROP", zoneprop.group(1).replace("notchPanelFit", "barWindow.notchPanelFit")
                                                if zoneprop else "0")
              .replace("ZONEFOR", function(full, "notchPanelZoneFor") if "function notchPanelZoneFor(" in full else "return 0")
              .replace("ZONE", normal).replace("BOX", function(full, "notchBox"))
              .replace("STOCK", str(stock_height)).replace("GAPS", "10"))
        return self.node(js)

    def test_zone_per_role_in_every_omarchy(self):
        for bar in SHELLS:
            stock = bar.read_text()
            with self.subTest(omarchy=bar.parts[-5]):
                full = self.full(stock)
                self.assertEqual(self.reserved(full, 26),
                                 [["", 26], ["parked", None], ["notch", 34], ["fullpanel", 29]])

    def test_40_only_fullpanel_leaves_auto(self):
        # Omarchy 4.0's bar (omarchy-mac and upstream's October form): the
        # normal and parked roles keep Auto and Ignore as before; FullPanel's
        # zone is written only in that role, and its value does not follow
        # the role (a write switches Quickshell to Normal: never while the
        # role changes to another).
        for bar in SHELLS:
            stock = bar.read_text()
            if is_45(stock):
                continue
            with self.subTest(omarchy=bar.parts[-5]):
                full = self.full(stock)
                self.assertEqual(self.expr(full, "exclusionMode"),
                                 'barWindow.parked ? ExclusionMode.Ignore : barWindow.notchRole === "fullpanel" ? '
                                 'ExclusionMode.Normal : ExclusionMode.Auto')
                self.assertIsNone(self.expr(full, "exclusiveZone"))
                self.assertEqual(full.count('property: "exclusiveZone"'), 1)
                self.assertIn('      when: barWindow.notchRole === "fullpanel" && !barWindow.parked; '
                              'restoreMode: Binding.RestoreNone\n', full)
                zone = re.search(r"readonly property int notchPanelZone: (.*)\n", full).group(1)
                self.assertNotIn("notchRole", zone)
                self.assertNotIn("parkedSize", zone)

    def test_45_only_fullpanels_zone_changes(self):
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        full = self.full(stock)
        self.assertEqual(self.expr(full, "exclusiveZone"),
                         'barWindow.notchRole === "" ? thickness : barWindow.notchRole === "fullpanel" ? '
                         'barWindow.notchPanelZone : barWindow.parkedSize')
        self.assertEqual(self.expr(full, "exclusionMode"), "barWindow.parked ? ExclusionMode.Ignore : ExclusionMode.Normal")
        self.assertNotIn('property: "exclusiveZone"', full)

    def zones(self, cases):
        text = patched()
        js = """
function notchBox(outH, strip, flush, size, scale) { BOX }
function notchPanelZoneFor(size, gapsTop) { ZONEFOR }
console.log(JSON.stringify(CASES.map(function (c) {
  const size = notchBox(0, c[0], 0, 26, c[1])[0];
  return [size, notchPanelZoneFor(size, c[2])];
})));
"""
        js = (js.replace("BOX", function(text, "notchBox")).replace("ZONEFOR", function(text, "notchPanelZoneFor"))
              .replace("CASES", json.dumps(cases)))
        return self.node(js)

    def test_windows_never_in_the_strip(self):
        # zone + gap >= the strip (as the bar rounds it, parkedSize): for
        # every gap; gaps_out 0 (Omarchy's window-no-gaps, flush-bar under a
        # transparent bar) reserves the whole strip as before.
        cases = [[strip, scale, gap] for strip in (24, 32, 33, 33.5, 37, 41.875, 43, 53.75)
                 for scale in (1, 1.6, 2) for gap in range(0, 31)]
        for (strip, scale, gap), (size, zone) in zip(cases, self.zones(cases)):
            self.assertGreaterEqual(zone + gap, size, (strip, scale, gap))
            self.assertLessEqual(zone, size)
            self.assertEqual(zone, size - min(5, gap), (strip, scale, gap))
            if gap == 0:
                self.assertEqual(zone, size)

    def test_the_owners_numbers(self):
        # 3024x1964/1968 at scale 2: the strip 33.5 logical: bar 34, zone 29,
        # windows at 41 (were 46); 34 >= ceil(33.5) - 10. At the owner's
        # full-screen scale 1.6 (1890 logical wide): strip 41.875, bar 42,
        # zone 37, windows at 49 (were 54). A user's gaps_out 0: 34 as before.
        self.assertEqual(self.zones([[33.5, 2, 10], [33.5 * 1890 / 1512, 1.6, 10], [33.5, 2, 0], [33.5, 2, 3]]),
                         [[34, 29], [42, 37], [34, 34], [34, 31]])
        self.assertGreaterEqual(29 + 10, math.ceil(33.5))

    def test_gaps_out_as_hyprland_says_it(self):
        text = patched()
        cases = ['{"option":"general:gaps_out","css":"10 10 10 10","set":true}', '{"custom":"20 5 5 5"}',
                 '{"css":"8 12 8 12"}', '{"int":7}', '{"css":"0 0 0 0"}', '{"css":"10.6 10 10 10"}',
                 '{"css":"-3 0 0 0"}', '{"css":""}', "not json", ""]
        js = "function f(text) { BODY }\nconsole.log(JSON.stringify(CASES.map(f)))".replace(
            "BODY", function(text, "notchGapsParse")).replace("CASES", json.dumps(cases))
        self.assertEqual(self.node(js), [10, 20, 8, 7, 0, 10, -1, -1, -1, -1])

    def test_gaps_read_at_start_after_a_reload_and_a_look_change(self):
        for bar in SHELLS:
            stock = bar.read_text()
            with self.subTest(omarchy=bar.parts[-5]):
                full = self.full(stock)
                self.assertEqual(full.count('command: ["hyprctl", "-j", "getoption", "general:gaps_out"]'), 1)
                soon = full[full.index("    id: notchGapsSoon\n"):]
                self.assertTrue(soon.startswith("    id: notchGapsSoon\n    interval: 200\n    running: true  // at start\n"))
                self.assertEqual(full.count('if (String(event.name) === "configreloaded") notchGapsSoon.restart()'), 1)
                self.assertEqual(full.count("function onTransparentChanged() { notchGapsSoon.restart() }"), 1)
                # The stock root has the properties the patch listens to.
                self.assertIn("  property bool transparent: ", stock)
                self.assertIn("  property string position: ", stock)
                # A value read while a read runs is read again, not lost.
                self.assertIn("onExited: if (root.notchGapsAgain) {", full)
                # Toasts keep the whole strip (barSizeFor is unchanged).
                self.assertIn("return root.notchBox(0, root.notchHeight, 0, root.barSize, 1)[0]", function(full, "barSizeFor"))


class Hover(unittest.TestCase):
    """#308: the strip's pointer reveals the auto-hidden indicators as the bar's own hover does."""

    def run_hover(self, xs, stock=True):
        body = function(patched(), "notchHover")
        js = HOVER % (body, json.dumps(xs))
        if not stock:
            js = js.replace("setBarHovered: function", "setBarHoveredGone: function")
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_free_space_reveals_and_holds_over_a_widget(self):
        r = self.run_hover([40, 110, 40, -1, -1])
        self.assertEqual(r[0], ["free", ["bar true", "center true"]])   # on the bar: hover held, peek opens
        self.assertEqual(r[1], ["widget", ["center false"]])            # over a widget: held by the bar hover
        self.assertEqual(r[2], ["free", ["center true"]])               # no second bar hover
        self.assertEqual(r[3], ["off", ["center false", "bar false"]])  # left the strip: both let go once
        self.assertEqual(r[4], ["off", []])

    def test_widget_first_does_not_open_the_peek(self):
        r = self.run_hover([110])
        self.assertEqual(r[0], ["widget", ["bar true", "center false"]])

    def test_older_omarchy_without_the_hover_functions(self):
        r = self.run_hover([40, -1], stock=False)
        self.assertEqual(r, [["unsupported", []], ["off", []]])

    def test_ipc_entry(self):
        self.assertIn("return root.notchHover(x)", function(patched(), "hover"))

    def run_hover_45(self, xs, edge=900):
        # Omarchy 4.5: no setCenterSectionHovered; its own hover peeks left of
        # the bar's peekEdge (where the centre box starts), widgets included.
        body = function(patched(), "notchHover")
        js = (HOVER % (body, json.dumps(xs))).replace("setCenterSectionHovered: function", "gone: function")
        js = js.replace("var closed = 0;", "var closed = 0; root.notchPeekEdge = function() { return %d };" % edge)
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_45_peeks_left_of_the_centre_box(self):
        r = self.run_hover_45([40, 110, 950, 40, -1, -1])
        self.assertEqual(r[0], ["free", ["bar true"]])     # left of the centre box: the peek opens
        self.assertEqual(r[1], ["widget", []])             # over a widget there: stays open
        self.assertEqual(r[2], ["free", ["bar false"]])    # past the centre box's start: shut
        self.assertEqual(r[3], ["free", ["bar true"]])
        self.assertEqual(r[4], ["off", ["bar false"]])     # left the strip: let go once
        self.assertEqual(r[5], ["off", []])

    def test_45_without_a_parked_bar_says_so(self):
        self.assertEqual(self.run_hover_45([40, -1], edge=-1), [["unsupported", []], ["off", []]])

    def test_45_edge_of_the_parked_bar(self):
        js = """
var notchParkedScreen = "Virtual-1";
var notchBarVariants = { instances: [ { screen: { name: "NOTCH" }, peekEdge: 700 }, { screen: null },
                                      { screen: { name: "Virtual-1" }, peekEdge: 912.5 } ] };
function edge() { BODY }
var a = edge(); notchParkedScreen = "Virtual-2"; var b = edge();
notchBarVariants.instances[2].peekEdge = undefined; notchParkedScreen = "Virtual-1";
console.log(JSON.stringify([a, b, edge()]));
""".replace("BODY", function(patched(), "notchPeekEdge"))
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [912.5, -1, -1])


# Omarchy's tray (#662) on fake bars: the parked copy on Virtual-1 takes the
# strip's clicks, NOTCH shows it, Virtual-2 is another display. Each bar has
# the tray as Omarchy's Tray.qml lays it out (horizontal): the drawer's
# chevron (a click target), the drawer (clip) with two icons that slide in from
# its right edge, one pinned icon after it; and a clock (a click target).
TRAY = r"""
var log = [];
var Qt = { LeftButton: 1, RightButton: 2, MiddleButton: 4 };
function Item(o, kids) {
  var it = { x: 0, width: 0, height: 30, visible: true, enabled: true, opacity: 1, clip: false, parent: null };
  for (var k in o) Object.defineProperty(it, k, Object.getOwnPropertyDescriptor(o, k));
  it.children = kids || [];
  it.children.forEach(function(c) { c.parent = it });
  it.mapToItem = function(to, px, py) {
    var ax = 0;
    for (var p = this; p && p !== to; p = p.parent) ax += p.x;
    return { x: ax + px, y: py };
  };
  return it;
}
function Icon(screen, id, x, extra) {
  var md = { activate: function() { log.push(screen + " " + id + " activate") },
             secondaryActivate: function() { log.push(screen + " " + id + " secondary") },
             scroll: function(d, h) { log.push(screen + " " + id + " scroll " + d + " " + h) },
             onlyMenu: !!(extra && extra.onlyMenu) };
  return Item({ x: x, width: 32, modelData: md,
                displayMenu: function(m) { log.push(screen + " " + id + " menu " + m.x + "," + m.y) } });
}
var windows = {}, clickTargets = [], moduleSlots = [];
function Bar(screen, trayX) {
  var de = 64;
  var tray = Item({ x: trayX, expanded: false, revealProgress: 0, drawerExtent: de, drawerItems: [1, 2],
                    openTrayMenu: function() {} });
  var chevron = Item({ width: 32, text: "\uf053", get x() { return de - de * tray.revealProgress },
                       triggerPress: function(b) { log.push(screen + " chevron press " + b) } });
  var icons = Item({ width: de, get x() { return de - de * tray.revealProgress } },
                   [Icon(screen, "drawer0", 0), Icon(screen, "drawer1", 32, { onlyMenu: true })]);
  var clip = Item({ x: 32, width: de, clip: true }, [icons]);
  var drawer = Item({ x: 0, width: 32 + de }, [chevron, clip]);
  var pinned = Item({ x: 32 + de, width: 32 }, [Icon(screen, "pinned", 0)]);
  var trayRoot = Item({ width: 32 + de + 32 }, [drawer, pinned]);
  var loader = Item({ width: 32 + de + 32 }, [trayRoot]);
  tray.children = [loader]; loader.parent = tray;
  var clock = Item({ x: 1450, width: 60, triggerPress: function(b) { log.push(screen + " clock press " + b) } });
  var content = Item({ width: 1512 }, [tray, clock]);
  windows[screen] = { screen: { name: screen }, contentItem: content };
  clickTargets.push(chevron, clock);
  moduleSlots.push({ activeItem: tray, moduleName: "omarchy.tray", region: "right", enabled: true });
  return { tray: tray, chevron: chevron };
}
var root = {
  notchParkedScreen: "Virtual-1", barHidden: false, notchFullscreen: false, notchHovering: false,
  clickTargets: clickTargets, moduleSlots: moduleSlots,
  moduleTargetClickable: function(t) {
    return t && t.visible !== false && t.opacity !== 0 && t.interactive !== false && t.pressable !== false &&
      t.concealed !== true && typeof t.triggerPress === "function";
  },
  targetWindow: function(t) {
    var p = t; while (p && p.parent) p = p.parent;
    for (var n in windows) if (windows[n].contentItem === p) return windows[n];
    return null;
  },
  slotWindow: function(s) { return root.targetWindow(s.activeItem) },
  setCenterSectionHovered: function() {}, setBarHovered: function() {},
};
FUNCS
var parked = Bar("Virtual-1", 1290), notch = Bar("NOTCH", 1290), other = Bar("Virtual-2", 1290);
function slide() { [parked, notch, other].forEach(function(b) { b.tray.revealProgress = b.tray.expanded ? 1 : 0 }) }
function state() { return [parked, notch, other].map(function(b) { return b.tray.expanded }) }
var out = {};
function step(name, f) { log = []; var r; try { r = f() } catch (e) { r = String(e) } out[name] = { r: r, log: log, open: state() } }
STEPS
console.log(JSON.stringify(out));
"""

# The functions the tray needs from the patch, and its IPC calls.
TRAY_FUNCS = ["notchTargetAt", "notchTargetRects", "notchHover", "notchIsTray", "notchTrayOf", "notchIsTrayIcon",
              "notchTrayIconsIn", "notchTrayDx", "notchSpan", "notchTraySpans", "notchTrayTarget", "notchTraySet",
              "notchTrayToggle", "notchIsChevron", "notchPeekEdge", "notchParkedX", "notchShownSlots",
              "click", "wheel", "targets", "trays", "pick"]


def tray_js(text, steps):
    """TRAY with the patch's functions (those this patch has) on the fake root."""
    funcs = []
    for name in TRAY_FUNCS:
        m = re.search(r"function %s\(([^)]*)\)" % name, text)
        if not m:
            continue
        args = ", ".join(a.split(":")[0].strip() for a in m.group(1).split(",") if a.strip())
        funcs.append("with (root) { root.%s = function(%s) { %s } }" % (name, args, function(text, name)))
    return TRAY.replace("FUNCS", "\n".join(funcs)).replace("STEPS", steps)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Tray(unittest.TestCase):
    """#662: Omarchy's tray in the strip. Fails with v35 (icons "miss", the
    chevron's left click does nothing), passes from v36."""

    STEPS = r"""
// Clicks at x on the strip: the pinned icon is at 1290+96, the closed
// drawer's icons are cut off, the chevron at 1290+64 (closed) or 1290 (open).
step("pinned left", function() { return root.click(1390, 20, 1) });
step("pinned middle", function() { return root.click(1390, 20, 3) });
step("pinned right", function() { return root.click(1390, 20, 2) });
step("pinned wheel", function() { return root.wheel(1390, 20, -120) });
step("closed drawer icon", function() { return root.click(1290 + 32 + 10, 20, 1) });
step("targets closed", function() { return JSON.parse(root.targets()) });
step("chevron right", function() { return root.click(1290 + 64 + 10, 20, 2) });
step("chevron left", function() { return root.click(1290 + 64 + 10, 20, 1) });
// Mid-slide (the parked copy has not slid yet): where the slide ends.
step("targets sliding", function() { return JSON.parse(root.targets()) });
step("drawer0 sliding", function() { return root.click(1290 + 32 + 10, 20, 1) });
slide();
step("trays open", function() { return JSON.parse(root.trays()) });
step("drawer0 left", function() { return root.click(1290 + 32 + 10, 20, 1) });
step("drawer1 left (only a menu)", function() { return root.click(1290 + 64 + 10, 20, 1) });
step("hover drawer1", function() { return root.notchHover(1290 + 64 + 10) });
step("chevron left again", function() { return root.click(1290 + 10, 20, 1) });
slide();
step("closed again", function() { return root.click(1290 + 32 + 10, 20, 1) });
step("clock", function() { return root.click(1460, 20, 1) });
// Opened again, then the pointer leaves the strip.
root.click(1290 + 64 + 10, 20, 1); slide();
other.tray.expanded = true;
step("hover off", function() { return root.notchHover(-1) });
root.click(1290 + 64 + 10, 20, 1);
step("unparked", function() { root.notchTraySet(false, "", ""); return null });
"""

    def run_tray(self, text):
        js = tray_js(text, self.STEPS)
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def setUp(self):
        self.r = self.run_tray(patched())

    def test_icons_take_the_buttons_and_the_wheel_as_their_mouse_area(self):
        r = self.r
        self.assertEqual(r["pinned left"], {"r": "ok", "log": ["Virtual-1 pinned activate"], "open": [False] * 3})
        self.assertEqual(r["pinned middle"]["log"], ["Virtual-1 pinned secondary"])
        self.assertEqual(r["pinned right"]["log"], ["Virtual-1 pinned menu 16,15"])
        self.assertEqual(r["pinned wheel"], {"r": "ok", "log": ["Virtual-1 pinned scroll -120 false"], "open": [False] * 3})
        self.assertEqual(r["drawer0 left"]["log"], ["Virtual-1 drawer0 activate"])
        self.assertEqual(r["drawer1 left (only a menu)"]["log"], ["Virtual-1 drawer1 menu 16,15"])
        self.assertEqual(r["hover drawer1"]["r"], "widget")

    def test_a_closed_drawers_icons_are_not_there(self):
        r = self.r
        # Under the closed drawer's icons: nothing (the chevron sits right of them).
        self.assertEqual(r["closed drawer icon"], {"r": "miss", "log": [], "open": [False] * 3})
        self.assertEqual(r["closed again"]["r"], "miss")
        # NOTCH's targets: the chevron, the clock, the pinned icon only.
        self.assertEqual(sorted(r["targets closed"]["r"]), [[1354, 0, 32, 30], [1386, 0, 32, 30], [1450, 0, 60, 30]])

    def test_the_chevron_opens_and_closes_the_drawer_on_both_bars(self):
        r = self.r
        self.assertEqual(r["chevron right"], {"r": "ok", "log": ["Virtual-1 chevron press 2"], "open": [False] * 3})
        self.assertEqual(r["chevron left"], {"r": "ok", "log": [], "open": [True, True, False]})
        self.assertEqual(r["trays open"]["r"], [["Virtual-1", "omarchy.tray", True, 1], ["NOTCH", "omarchy.tray", True, 1],
                                                ["Virtual-2", "omarchy.tray", False, 0]])
        self.assertEqual(r["chevron left again"], {"r": "ok", "log": [], "open": [False, False, False]})
        self.assertEqual(r["clock"]["log"], ["Virtual-1 clock press 1"])

    def test_while_the_drawer_slides_where_it_ends(self):
        r = self.r
        self.assertEqual(sorted(r["targets sliding"]["r"]),
                         [[1290, 0, 32, 30], [1322, 0, 32, 30], [1354, 0, 32, 30], [1386, 0, 32, 30], [1450, 0, 60, 30]])
        self.assertEqual(r["drawer0 sliding"]["log"], ["Virtual-1 drawer0 activate"])

    def test_leaving_the_strip_and_unparking_close_it_there_only(self):
        r = self.r
        self.assertEqual(r["hover off"]["open"], [False, False, True])   # another display's bar keeps its own
        self.assertEqual(r["unparked"]["open"], [False, False, True])

    def test_v35_missed_them(self):
        # The patch before #662 on the same bars: icons miss, the chevron's
        # left click is pressed on Omarchy's button, which does nothing with it.
        before = subprocess.run(["git", "-C", str(ROOT), "show", "61c2de6f:src/omanotch/guest/bar/apply-patch.py"],
                                capture_output=True, text=True)
        if before.returncode != 0:
            self.skipTest("no git history")
        d = pathlib.Path(tempfile.mkdtemp())
        try:
            (d / "apply-patch.py").write_text(before.stdout)
            f = d / "Bar.qml"
            f.write_text(BAR)
            subprocess.run([sys.executable, str(d / "apply-patch.py"), str(f)], check=True, capture_output=True)
            js = tray_js(f.read_text(), 'step("pinned", function() { return root.click(1390, 20, 1) });\n'
                                        'step("chevron", function() { return root.click(1364, 20, 1) });\n')
            r = json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)
        finally:
            shutil.rmtree(d)
        self.assertEqual(r["pinned"], {"r": "miss", "log": [], "open": [False] * 3})
        self.assertEqual(r["chevron"], {"r": "ok", "log": ["Virtual-1 chevron press 1"], "open": [False] * 3})


# The strip shows NOTCH's copy of the bar and presses the parked one. Each
# copy's widgets keep their own state: Omarchy's update icon (SystemUpdate.qml,
# 4.0 and 4.5) asks at its start and then every 6 hours, so a NOTCH output
# made after an update came out shows the icon and the parked bar, older, not
# (M1 2026-11-06: weather 1610.3 on NOTCH, 1631.3 on the parked bar). Right
# section: weather, [update], indicators, clock; a click target fills each.
TWINS = r"""
var log = [];
var Qt = { LeftButton: 1, RightButton: 2, MiddleButton: 4 };
function Item(o, kids) {
  var it = { x: 0, width: 0, height: 26, visible: true, enabled: true, opacity: 1, clip: false, parent: null };
  for (var k in o) it[k] = o[k];
  it.children = kids || [];
  it.children.forEach(function(c) { c.parent = it });
  it.mapToItem = function(to, px, py) {
    var ax = 0;
    for (var p = this; p && p !== to; p = p.parent) ax += p.x;
    return { x: ax + px, y: py };
  };
  return it;
}
var windows = {}, clickTargets = [], moduleSlots = [];
function Bar(screen, ids) {
  var x = 1580, slots = [];
  ids.forEach(function(id) {
    var shown = id.charAt(0) !== "-", name = shown ? id : id.slice(1), w = shown ? 21 : 0;
    var t = Item({ width: w, visible: shown, triggerPress: function(b) { log.push(screen + " " + name + " " + b) },
                   wheelMoved: function(d) { log.push(screen + " " + name + " wheel " + d) } });
    var s = Item({ x: x, width: w, region: "right", moduleName: name, activeItem: t }, [t]);
    slots.push(s); clickTargets.push(t); moduleSlots.push(s); x += w;
  });
  windows[screen] = { screen: { name: screen }, contentItem: Item({ width: 1920 }, slots) };
}
var root = {
  notchParkedScreen: "Virtual-1", barHidden: false, notchFullscreen: false, notchHovering: false,
  clickTargets: clickTargets, moduleSlots: moduleSlots,
  moduleTargetClickable: function(t) {
    return t && t.visible !== false && t.opacity !== 0 && t.interactive !== false && t.pressable !== false &&
      t.concealed !== true && typeof t.triggerPress === "function";
  },
  targetWindow: function(t) {
    var p = t; while (p && p.parent) p = p.parent;
    for (var n in windows) if (windows[n].contentItem === p) return windows[n];
    return null;
  },
  slotWindow: function(s) { return root.targetWindow(s) },
  setCenterSectionHovered: function() {}, setBarHovered: function() {},
};
FUNCS
BARS
var out = {};
function step(name, f) { log = []; var r; try { r = f() } catch (e) { r = String(e) } out[name] = { r: r, log: log } }
STEPS
console.log(JSON.stringify(out));
"""


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Twins(unittest.TestCase):
    """A click on the strip presses the parked bar's twin of the item shown
    under it, also while the two copies differ (v37 and older pressed what
    the parked bar had at that x: the update icon's place pressed the
    weather, the weather's place nothing)."""

    STEPS = r"""
step("weather", function() { return root.click(1590, 10, 1) });
step("update", function() { return root.click(1610, 10, 1) });
step("indicators", function() { return root.click(1632, 10, 2) });
step("clock", function() { return root.click(1660, 10, 1) });
step("clock wheel", function() { return root.wheel(1660, 10, 120) });
step("free", function() { return root.click(1000, 10, 1) });
step("hover update", function() { return root.notchHover(1610) });
step("pick weather", function() { return root.pick(1590) });
step("pick update", function() { return root.pick(1610) });
"""

    def run_twins(self, text, notch, parked):
        funcs = []
        for name in TRAY_FUNCS:
            m = re.search(r"function %s\(([^)]*)\)" % name, text)
            if not m:
                continue
            args = ", ".join(a.split(":")[0].strip() for a in m.group(1).split(",") if a.strip())
            funcs.append("with (root) { root.%s = function(%s) { %s } }" % (name, args, function(text, name)))
        bars = 'Bar("Virtual-1", %s); Bar("NOTCH", %s);' % (json.dumps(parked), json.dumps(notch))
        js = TWINS.replace("FUNCS", "\n".join(funcs)).replace("BARS", bars).replace("STEPS", self.STEPS)
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_the_same_copies_press_what_shows(self):
        ids = ["omarchy.weather", "omarchy.system-update", "omarchy.indicators", "omarchy.clock"]
        r = self.run_twins(patched(), ids, ids)
        self.assertEqual(r["weather"], {"r": "ok", "log": ["Virtual-1 omarchy.weather 1"]})
        self.assertEqual(r["update"], {"r": "ok", "log": ["Virtual-1 omarchy.system-update 1"]})
        self.assertEqual(r["indicators"]["log"], ["Virtual-1 omarchy.indicators 2"])
        self.assertEqual(r["clock"]["log"], ["Virtual-1 omarchy.clock 1"])
        self.assertEqual(r["free"]["r"], "miss")

    def test_an_item_only_notch_shows_is_not_pressed_and_moves_nothing(self):
        notch = ["omarchy.weather", "omarchy.system-update", "omarchy.indicators", "omarchy.clock"]
        parked = ["omarchy.weather", "-omarchy.system-update", "omarchy.indicators", "omarchy.clock"]
        r = self.run_twins(patched(), notch, parked)
        self.assertEqual(r["weather"], {"r": "ok", "log": ["Virtual-1 omarchy.weather 1"]})
        self.assertEqual(r["update"], {"r": "miss", "log": []})
        self.assertEqual(r["indicators"], {"r": "ok", "log": ["Virtual-1 omarchy.indicators 2"]})
        self.assertEqual(r["clock"], {"r": "ok", "log": ["Virtual-1 omarchy.clock 1"]})
        self.assertEqual(r["clock wheel"], {"r": "ok", "log": ["Virtual-1 omarchy.clock wheel 120"]})
        self.assertEqual(r["free"]["r"], "miss")
        self.assertEqual(r["hover update"]["r"], "free")
        self.assertEqual(r["pick weather"]["r"], '["Virtual-1","omarchy.weather"]')
        self.assertEqual(r["pick update"]["r"], "miss")

    def test_an_item_only_the_parked_bar_shows_is_skipped(self):
        notch = ["omarchy.weather", "-omarchy.system-update", "omarchy.indicators", "omarchy.clock"]
        parked = ["omarchy.weather", "omarchy.system-update", "omarchy.indicators", "omarchy.clock"]
        r = self.run_twins(patched(), notch, parked)
        self.assertEqual(r["weather"]["log"], ["Virtual-1 omarchy.weather 1"])
        # NOTCH's indicators sit where the parked bar's update icon is.
        self.assertEqual(r["update"], {"r": "ok", "log": ["Virtual-1 omarchy.indicators 1"]})
        self.assertEqual(r["clock"]["log"], ["Virtual-1 omarchy.clock 1"])


TRAYS = sorted((ROOT / "src/tests/omarchy-shell").glob("*/shell/plugins/bar/widgets/Tray.qml"))


class TrayShape(unittest.TestCase):
    """What the patch finds Omarchy's tray by is still there (omarchy-mac's and upstream's Tray.qml)."""

    def test_shape(self):
        self.assertEqual(len(TRAYS), 3, TRAYS)
        for f in TRAYS:
            with self.subTest(omarchy=f.parts[-6]):
                q = f.read_text()
                if "  readonly property bool fixedAtStart: " in q:
                    self.shape_45(q)
                    continue
                self.assertIn("  property bool expanded: false\n", q)
                self.assertIn("  readonly property var drawerItems: ", q)
                self.assertIn("  function openTrayMenu(item, anchorItem, mouse) {\n", q)
                self.assertIn("  readonly property int drawerExtent: ", q)
                self.assertIn("  property real revealProgress: expanded ? 1 : 0\n", q)
                self.assertEqual(q.count('          text: "\\uf053"\n'), 2)
                self.assertEqual(q.count("onHoveredChanged: root.expanded = hovered"), 2)
                # The horizontal drawer: chevron and icons slide by the same amount, the icons in a clip.
                self.assertEqual(q.count("x: root.drawerExtent - root.revealExtent\n"), 2)
                self.assertIn("          id: trayClip\n          x: expandIcon.width\n", q)
                self.assertEqual(q.count("          clip: true\n"), 2)
                # The icons: displayMenu, and what their mouse area does with each button.
                item = q[q.index("  component TrayItem: Item {"):]
                self.assertIn("    function displayMenu(mouse) {\n", item)
                self.assertIn("trayItemRoot.modelData.secondaryActivate()", item)
                self.assertIn("} else if (trayItemRoot.modelData.onlyMenu) {\n          trayItemRoot.displayMenu(mouse)", item)
                self.assertIn("trayItemRoot.modelData.activate()", item)
                self.assertIn("trayItemRoot.modelData.scroll(wheel.angleDelta.y, false)", item)
                self.assertIn("if (mouse.button === Qt.RightButton) {\n          trayItemRoot.displayMenu(mouse)", item)

    def shape_45(self, q):
        # Omarchy 4.5's tray: the drawer grows from the edge the tray is fixed
        # by (its chevron points the other way at the bar's start), the icons
        # sit still in a clip as wide as the part shown, and the whole tray
        # moves by what the drawer still has to open (notchTrayDx).
        self.assertIn("  property bool expanded: false\n", q)
        self.assertIn("  readonly property var drawerItems: ", q)
        self.assertIn("  function openTrayMenu(item, anchorItem, mouse) {\n", q)
        self.assertIn("  readonly property int drawerExtent: ", q)
        self.assertIn("  property real revealProgress: expanded || holdOpen ? 1 : 0\n", q)
        self.assertIn("  readonly property real revealExtent: drawerExtent * revealProgress\n", q)
        self.assertIn('  readonly property bool fixedAtStart: fixedEdge === "start"\n', q)
        self.assertEqual(q.count('          text: root.fixedAtStart ? "\\uf054" : "\\uf053"\n'), 2)
        self.assertEqual(q.count("onHoveredChanged: root.expanded = hovered"), 2)
        self.assertIn("      implicitWidth: pinnedRow.implicitWidth + chevronWidth + root.revealExtent\n", q)
        self.assertIn("          id: trayClip\n          x: root.fixedAtStart ? 0 : expandIcon.width\n", q)
        self.assertIn("          width: root.revealExtent\n          height: root.barSize\n          clip: true\n", q)
        self.assertIn("            x: root.fixedAtStart ? root.revealExtent - root.drawerExtent : 0\n", q)
        item = q[q.index("  component TrayItem: Item {"):]
        self.assertIn("    function displayMenu(mouse) {\n", item)
        self.assertIn("trayItemRoot.modelData.secondaryActivate()", item)
        self.assertIn("} else if (trayItemRoot.modelData.onlyMenu) {\n          trayItemRoot.displayMenu(mouse)", item)
        self.assertIn("trayItemRoot.modelData.activate()", item)
        self.assertIn("trayItemRoot.modelData.scroll(wheel.angleDelta.y, false)", item)
        self.assertIn("if (mouse.button === Qt.RightButton) {\n          trayItemRoot.displayMenu(mouse)", item)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_45_chevron_and_slide(self):
        # 4.5's tray at the bar's start: its chevron is the other glyph, and
        # it opens rightwards; one at the end opens leftwards as before.
        text = patched()
        js = """
function chev(t) { CHEV }
function dx(tray) { DX }
console.log(JSON.stringify([chev({ text: "\\uf053" }), chev({ text: "\\uf054" }), chev({ text: "x" }), chev(null),
  dx({ drawerExtent: 64, revealProgress: 0.25, expanded: true }),
  dx({ drawerExtent: 64, revealProgress: 0.25, expanded: true, fixedAtStart: false }),
  dx({ drawerExtent: 64, revealProgress: 0.25, expanded: true, fixedAtStart: true }),
  dx({ drawerExtent: 64, revealProgress: 1, expanded: true, fixedAtStart: true })]));
""".replace("CHEV", function(text, "notchIsChevron")).replace("DX", function(text, "notchTrayDx"))
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [True, True, False, False, -48, -48, 48, 0])


# Omarchy 4.5's tray grows as its drawer slides open (4.0's keeps the drawer's
# room all the time). Skip the notch on the bar beside the notch, as on the
# M1 Max 14-inch at 1512 pt (housing 663.5-848.5, FullPanel): the right list's
# widths from the patched ModuleList (notchWidths) at each step of the slide,
# laid out by notchSkipPlace, as the bar does each frame. Out per step: the
# tray's span on the bar [start, end] or "hidden".
TRAY_SKIP = r"""
var root = { notchIsTray: function (item) { NOTCHISTRAY } };
function widths(children) { WIDTHS }
function place(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) { PLACE }
function slide(closed, drawer, others, left, beside) {
  var out = [];
  for (var k = 0; k <= 10; k++) {
    var r = k / 10;
    var tray = { expanded: r > 0, drawerItems: [], openTrayMenu: function () {}, drawerExtent: drawer,
                 revealExtent: drawer * r, revealProgress: r };
    var children = [{ notchSlotIndex: 0, implicitWidth: closed + drawer * r, notchPeekFull: 0, activeItem: tray }];
    for (var i = 0; i < others.length; i++) children.push({ notchSlotIndex: i + 1, implicitWidth: others[i], notchPeekFull: 0 });
    var right = widths(children);
    var p = place(1512, 8, left, right, [663.5, 848.5], beside, 6, 8, 24, null, 12);
    var s = p.right[0], w = closed + drawer * r;
    out.push(s.hidden ? "hidden" : [s.n + s.x, s.n + s.x + w]);
  }
  return out;
}
console.log(JSON.stringify(CASES.map(function (c) { return slide.apply(null, c) })));
"""


@unittest.skipUnless(shutil.which("node"), "node not installed")
class TrayBesideTheNotch(unittest.TestCase):
    """Omarchy 4.5's tray drawer beside the notch with Skip the notch on: the
    layout decides where the tray goes by its width with the drawer open, so
    the drawer opens in place, in visible room, and the tray never moves
    while it slides (it jumped over the housing mid-slide and closed as the
    pointer lost it)."""

    HOUSING = (663.5, 848.5)

    def slides(self, *cases):
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        d = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "Bar.qml"
        f.write_text(stock)
        self.assertEqual(patch_file(f).returncode, 0)
        full = f.read_text()
        widths = re.search(r"    readonly property var notchWidths: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        js = (TRAY_SKIP.replace("NOTCHISTRAY", function(full, "notchIsTray")).replace("WIDTHS", widths)
              .replace("PLACE", function(full, "notchSkipPlace")).replace("CASES", json.dumps(cases)))
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def check(self, steps, side, beside=None):
        # Left of the housing: clear of the indicators beside it at rest and
        # of the room their peek opens into (beside[0], beside[2]).
        wall = self.HOUSING[0] - 6 - (beside[0] + beside[2] if beside and len(beside) > 2 else 0)
        for step in steps:
            self.assertNotEqual(step, "hidden", steps)
            a, b = step
            # Visible room: clear of the housing, on the side it started on.
            self.assertTrue(b <= wall if side == "left" else a >= self.HOUSING[1], steps)
        # The drawer grows from the edge the tray keeps (its end): that edge
        # never moves, so neither do the pinned icons and the chevron under
        # the pointer.
        self.assertEqual(len({round(s[1], 3) for s in steps}), 1, steps)

    def test_room_on_the_right(self):
        # Three drawer icons fit between the centre widgets and the right
        # list: the tray stays where Omarchy puts it and opens there.
        steps = self.slides([54, 81, [27] * 7, [27, 110], [90, 260]])[0]
        self.check(steps, "right")
        self.assertEqual(steps[0], [1261, 1315])
        self.assertEqual(steps[-1], [1180, 1315])

    def test_no_room_on_the_right(self):
        # Six drawer icons do not fit there open: the tray sits left of the
        # housing from the start (as Skip the notch moves any item that does
        # not fit) and opens there. v37 decided by the width of the moment:
        # it stayed right, jumped left at 80 % of the slide, and back.
        cases = [[81, 162, [27] * 7, [27, 110], [90, 260]],
                 [108, 216, [27] * 7, [27, 110], [90, 300]],
                 [81, 162, [27] * 9, [27, 110], [90, 300]],
                 # Omarchy 4.5's indicators (21 at rest) peek 105 wider.
                 [54, 135, [27] * 4 + [260], [27, 105.5], [21, 260, 105]]]
        for case, steps in zip(cases, self.slides(*cases)):
            self.check(steps, "left", case[4])

    def test_the_patch_counts_a_tray_open(self):
        # Only a tray counts at its open width; a tray already open, and
        # every other item, at the width it has.
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        d = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "Bar.qml"
        f.write_text(stock)
        patch_file(f)
        full = f.read_text()
        widths = re.search(r"    readonly property var notchWidths: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        js = """
var root = { notchIsTray: function (item) { NOTCHISTRAY } };
function tray(drawer, reveal) {
  return { expanded: reveal > 0, drawerItems: [], openTrayMenu: function () {}, drawerExtent: drawer, revealExtent: drawer * reveal };
}
var children = [ { notchSlotIndex: 0, implicitWidth: 54, activeItem: tray(81, 0) },
                 { notchSlotIndex: 1, implicitWidth: 94.5, activeItem: tray(81, 0.5) },
                 { notchSlotIndex: 2, implicitWidth: 135, activeItem: tray(81, 1) },
                 { notchSlotIndex: 3, implicitWidth: 27, activeItem: { expanded: false } },
                 { notchSlotIndex: 4, implicitWidth: 27, activeItem: tray(0, 0) } ];
console.log(JSON.stringify((function () { WIDTHS })()));
""".replace("NOTCHISTRAY", function(full, "notchIsTray")).replace("WIDTHS", widths)
        out = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [[54, 135], [94.5, 135], 135, 27, 27])

    def patched_45(self):
        stock = next(b.read_text() for b in SHELLS if is_45(b.read_text()))
        d = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        f = d / "Bar.qml"
        f.write_text(stock)
        self.assertEqual(patch_file(f).returncode, 0)
        return f.read_text()

    def run_js(self, full, js, cases):
        widths = re.search(r"    readonly property var notchWidths: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        rest = re.search(r"    readonly property real notchRest: \{\n(.*?)\n    \}\n", full, re.S).group(1)
        js = (js.replace("NOTCHISTRAY", function(full, "notchIsTray")).replace("WIDTHS", widths).replace("REST", rest)
              .replace("PLACE", function(full, "notchSkipPlace")).replace("CASES", json.dumps(cases)))
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_tray_in_the_left_list(self):
        # The tray in the left list: fixed at its start, it grows right. Its
        # start never moves while it slides, and it goes right of the housing
        # from the start when it does not fit left of it open (closed it
        # would; v37 kept it left and jumped it over part-way through).
        js = r"""
var root = { notchIsTray: function (item) { NOTCHISTRAY } };
function widths(children) { WIDTHS }
function place(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) { PLACE }
console.log(JSON.stringify(CASES.map(function (c) {
  var closed = c[0], drawer = c[1], before = c[2], right = c[3], beside = c[4], out = [];
  for (var k = 0; k <= 10; k++) {
    var r = k / 10, w = closed + drawer * r;
    var tray = { expanded: r > 0, drawerItems: [], openTrayMenu: function () {}, drawerExtent: drawer,
                 revealExtent: drawer * r, revealProgress: r };
    var children = [];
    for (var i = 0; i < before.length; i++) children.push({ notchSlotIndex: i, implicitWidth: before[i], notchPeekFull: 0 });
    children.push({ notchSlotIndex: before.length, implicitWidth: w, notchPeekFull: 0, activeItem: tray });
    var s = place(1512, 8, widths(children), right, [663.5, 848.5], beside, 6, 8, 24, null, 12).left[before.length];
    out.push(s.hidden ? "hidden" : [s.n + s.x, s.n + s.x + w]);
  }
  return out;
})));
"""
        beside = [21, 105.5, 105]
        fits, jumps = self.run_js(self.patched_45(), js, [
            [54, 135, [20] + [26] * 5, [90, 260], beside],
            # Closed it ends at 602 (left of 636.5), open at 737.
            [54, 135, [20] + [26] * 20, [90], beside]])
        wall_l = self.HOUSING[0] - 6 - beside[0]
        wall_r = self.HOUSING[1] + 6 + beside[1]
        for steps, left in ((fits, True), (jumps, False)):
            self.assertNotIn("hidden", steps)
            self.assertEqual(len({round(s[0], 3) for s in steps}), 1, steps)
            for a, b in steps:
                self.assertTrue(b <= wall_l if left else a >= wall_r, steps)
        self.assertEqual(fits[0][0], 158)
        self.assertEqual(jumps[0][0], wall_r + 8)

    def test_tray_in_the_centre(self):
        # The tray in Omarchy 4.5's centre section: beside the notch, the
        # centre box sits right of the housing and grows right as the drawer
        # slides open. Where the right list's items end (centre + centerEnd)
        # counts the tray open, so the right side is decided once: nothing
        # moves while it slides (v38's first build took the centre's width of
        # the moment, and the crowded right list glided across the housing
        # mid-slide), and nothing kept right of the housing sits under the
        # open drawer.
        full = self.patched_45()
        beside = re.search(r"readonly property var notchBeside: (notchLayout && active\n\s*\? \[[^\n]*\] : \[0, 0\])",
                           full).group(1).replace("\n", " ")
        rest_m = re.search(r"\n    readonly property real notchRest: (boxList\.notchRest)\n", full)
        js = r"""
var root = { notchIsTray: function (item) { NOTCHISTRAY } };
function widths(children) { WIDTHS }
function rest(notchWidths) { REST }
function place(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) { PLACE }
console.log(JSON.stringify(CASES.map(function (c) {
  var closed = c[0], drawer = c[1], others = c[2], end = c[3], right = c[4], out = [];
  for (var k = 0; k <= 10; k++) {
    var r = k / 10, w = closed + drawer * r;
    var tray = { expanded: r > 0, drawerItems: [], openTrayMenu: function () {}, drawerExtent: drawer,
                 revealExtent: drawer * r, revealProgress: r };
    var children = [{ notchSlotIndex: 0, implicitWidth: w, notchPeekFull: 0, activeItem: tray }], live = w;
    for (var i = 0; i < others.length; i++) {
      children.push({ notchSlotIndex: i + 1, implicitWidth: others[i], notchPeekFull: 0 });
      live += others[i];
    }
    var boxList = { notchRest: rest(widths(children)) };
    var centerBox = { width: live };
    CENTRE_REST
    var beginList = { notchRest: 21, notchPeekMore: 105 }, endList = { notchRest: end };
    var notchLayout = true, active = true;
    var p = place(1512, 8, [20, 26, 26, 26], right, [663.5, 848.5], BESIDE, 6, 8, 24, null, 12);
    out.push(p.right.map(function (s) { return s.hidden ? "hidden" : s.n + s.x }));
  }
  return out;
})));
""".replace("BESIDE", beside).replace(
            "CENTRE_REST", "centerBox.notchRest = %s;" % rest_m.group(1) if rest_m else "")
        right = [27] * 10 + [90, 260]
        steps = self.run_js(full, js, [[54, 135, [80], 27, right]])[0]
        self.assertEqual(len({json.dumps(s) for s in steps}), 1, steps)
        # Right of the housing: after the open centre (54 + 135 + 80) and
        # centerEnd (27).
        wall_r = self.HOUSING[1] + 6 + 54 + 135 + 80 + 27
        shown = [(x, w) for x, w in zip(steps[0], right) if x != "hidden"]
        self.assertTrue(all(x >= wall_r or x + w <= self.HOUSING[0] - 6 - 21 - 105 for x, w in shown), steps[0])
        self.assertIn(1504 - 260, steps[0])


# The notched Macs at their default resolution: strip height and display
# width in points (safe-area top inset; 74 px on the 14- and 16-inch, 66 px
# at the Air's 1470 pt), guest display width in pixels (the Mac's backing
# pixels, or another resolution of the user's choice).
MACS = [
    ("14-inch", 37, 1512, 3024),
    ("14-inch, guest 3600 px (#307)", 37, 1512, 3600),
    ("16-inch", 37, 1728, 3456),
    ("Air 13-inch", 33, 1470, 2940),
    ("Air 13-inch at 1280 pt", 32, 1280, 2560),
]
SCALES = [1, 1.25, 1.5, 1.6, 5 / 3, 1.75, 2]


def notch_mode(logical_h, scale):
    """notchrule.h notch_mode: NOTCH's logical height, whole pixels at `scale`."""
    lh = math.ceil(logical_h - 1e-6)
    while abs(lh * scale - round(lh * scale)) > 1e-3:
        lh += 1
    return lh


class Centre(unittest.TestCase):
    """The bar in the middle of the strip at every scale (the strip shows NOTCH's bottom rows)."""

    def boxes(self, cases):
        js = "function notchBox(outH, strip, flush, size, scale) { %s }\n" % function(patched(), "notchBox")
        js += "console.log(JSON.stringify(%s.map(function (c) { return notchBox.apply(null, c) })))" % json.dumps(cases)
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def check(self, flush_pt):
        cases, info = [], []
        for name, strip_pt, width_pt, guest_px in MACS:
            for s in SCALES:
                strip = strip_pt * (guest_px / s) / width_pt   # notchrule.h strip_logical
                out_h = notch_mode(strip, s)
                flush = flush_pt * (guest_px / s) / width_pt if flush_pt else 0
                # notchcast passes both on with two decimals.
                cases.append([out_h, round(strip, 2), round(flush, 2), 26, s])
                info.append((name, s, strip, out_h, flush, 2 * width_pt / (guest_px / s)))
        for (name, s, strip, out_h, flush, dev), (height, pad) in zip(info, self.boxes(cases)):
            with self.subTest(mac=name, scale=s):
                self.assertEqual(height, out_h if not flush else math.ceil(out_h - strip + flush - 1e-6))
                self.assertAlmostEqual(pad * s, round(pad * s), msg="whole pixels")
                above = pad - (out_h - strip)            # the strip cuts NOTCH's extra rows at the top
                below = (flush or strip) - above - 26
                self.assertLessEqual(abs(above - below) / 2 * dev, 0.5 + 1e-9,
                                     "%.2f device px above, %.2f below" % (above * dev, below * dev))

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_centred_in_the_strip(self):
        self.check(0)

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_flush_centred_in_the_housing_height(self):
        self.check(32)


# Skip the notch on every notched MacBook, macOS size and Omarchy scale, with
# many bars. Notch width: the camera housing's panel pixels (Air 13/15: 311.7,
# Pro 14/16: 396, as macOS reports it: 179 pt on an Air 13 at 1470, 198 pt on a
# Pro 16 at 1728), centred. The guest gets the panel at 2 px per point; Omarchy's
# scale s makes it 2W/s wide (the FullPanel presets and Omanotch's).
DEVICES = [
    ("Air 13", 2560, 311.7, [1024, 1280, 1470, 1710]),
    ("Air 15", 2880, 311.7, [1280, 1440, 1710, 2048]),
    ("Pro 14", 3024, 396, [1147, 1352, 1512, 1800]),
    ("Pro 16", 3456, 396, [1312, 1496, 1728, 2056]),
]
OMARCHY_SCALES = [1, 1.25, 1.5, 1.6, 5 / 3, 1.75, 2, 3, 4]


def tray_width(n):
    """Omarchy's tray with n icons in its drawer: the "<" expander and the drawer's room."""
    return 0 if n == 0 else 27 + 27 * n


def bars():
    """Bars people have: (name, left, right, beside, indicators index), widths in the bar's
    points, left to right. The indicators as [now, at rest, hidden ones' width]."""
    out = []
    for ws in (1, 5, 10):
        for tray in (0, 1, 3, 6, 10, 16, 24):
            for hidden in (0, 1, 5):
                for active in (0, 1):
                    for weather in (True, False):
                        for others in ("all", "few"):
                            left = [27, 21.1 * ws + 0.5]
                            right = []
                            if tray:
                                right.append(tray_width(tray))
                            if weather:
                                right.append(21)
                            ind = len(right) if hidden or active else None
                            if ind is not None:
                                right.append([21 * active, 21 * active, 21 * hidden])
                            if others == "all":
                                right += [27, 133, 27] + [27] * 6 + [27]
                            else:
                                right += [27]
                            right.append(132.5)
                            name = "ws %d, tray %d, hidden %d, active %d, weather %s, %s" % (
                                ws, tray, hidden, active, "on" if weather else "off", others)
                            out.append((name, left, right, [0, 0], ind))
    # Moved modules: the clock in the centre (beside the housing), the tray on the
    # left, a long window title on the left.
    for tray in (0, 6, 16):
        out.append(("clock in the centre, tray %d" % tray, [27, 106], ([tray_width(tray)] if tray else []) +
                    [21, [0, 0, 105]] + [27] * 8, [0, 132.5], 2 if tray else 1))
        out.append(("tray on the left %d" % tray, [27, 106] + ([tray_width(tray)] if tray else []),
                    [21, [0, 0, 105]] + [27] * 8 + [132.5], [0, 0], 1))
        out.append(("window title on the left, tray %d" % tray, [27, 106, 300], ([tray_width(tray)] if tray else []) +
                    [21, [0, 0, 105]] + [27] * 8 + [132.5], [0, 0], 2 if tray else 1))
    return out


MATRIX = r"""
function place(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) { BODY }
var cases = CASES, out = [];
for (var i = 0; i < cases.length; i++) out.push(place.apply(null, cases[i]));
console.log(JSON.stringify(out));
"""


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Matrix(unittest.TestCase):
    """Every device, size and scale with many bars, the indicators closed and
    open: nothing on the housing, nothing overlaps, the menu and the clock stay,
    a peek moves nothing Omarchy's own peek would not, where it opens never
    depends on the peek, and a bar that fits is Omarchy's own."""

    PAD, EDGE, GAP, KEEP, STICK = 8, 6, 8, 24, 12

    def run_cases(self, args):
        body = function(patched(), "notchSkipPlace")
        out = []
        for k in range(0, len(args), 4000):
            js = MATRIX.replace("BODY", body).replace("CASES", json.dumps(args[k:k + 4000]))
            out += json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)
        return out

    @staticmethod
    def rects(r, left, right, ind, open_):
        """What shows on the bar: (name, start, end) per visible part."""
        shown = []
        for i, (s, w) in enumerate(zip(r["left"], left)):
            if not s["hidden"] and w > 0:
                shown.append(("L%d" % i, s["n"] + s["x"], s["n"] + s["x"] + w))
        for i, (s, e) in enumerate(zip(r["right"], right)):
            w = e[0] if isinstance(e, list) else e
            if s["hidden"] or w <= 0:
                continue
            x = s["n"] + s["x"]
            if i == ind and isinstance(e, list) and open_ and s.get("peekAt") is not None:
                p = e[2]
                if w - p > 0:
                    shown.append(("R%d" % i, x + p, x + w))
                if not s.get("peekHidden"):
                    shown.append(("peek", s["peekAt"], s["peekAt"] + p))
            else:
                shown.append(("R%d" % i, x, x + w))
        return shown

    def test_every_device_size_and_scale(self):
        geos, cases, meta = [], [], []
        for dev, panel, notch_px, sizes in DEVICES:
            for size in sizes:
                nw = notch_px * size / panel
                for s in OMARCHY_SCALES:
                    W = 2 * size / s
                    nl = (W - 2 * nw / s) / 2
                    geos.append((dev, size, s, W, [nl, nl + 2 * nw / s]))
        allbars = bars()
        for gi, (dev, size, s, W, housing) in enumerate(geos):
            for bi, (name, left, right, beside, ind) in enumerate(allbars):
                for open_ in (False, True):
                    r = [e[:] if isinstance(e, list) else e for e in right]
                    if ind is not None and isinstance(r[ind], list) and open_:
                        r[ind] = [r[ind][1] + r[ind][2], r[ind][1], r[ind][2]]
                    cases.append([W, self.PAD, left, r, housing, beside, self.EDGE, self.GAP, self.KEEP, None, self.STICK])
                    meta.append((gi, bi, open_, r))
        out = self.run_cases(cases)
        fails, stats = [], {}
        for k in range(0, len(out), 2):
            (gi, bi, _, rc), (_, _, _, ro) = meta[k], meta[k + 1]
            dev, size, s, W, (nl, nr) = geos[gi]
            name, left, right, beside, ind = allbars[bi]
            closed, opened = out[k], out[k + 1]
            where = "%s at %d pt, scale %.3g, %s" % (dev, size, s, name)
            st = stats.setdefault((dev, size), {"bars": 0, "fits": 0, "jumped": 0, "hidden": 0, "left": 0, "fails": 0})
            st["bars"] += 1
            if closed is None or opened is None:
                fails.append(where + ": no layout")
                continue
            wallL = nl - (self.EDGE + beside[0] if beside[0] > 0 else 0)
            wallR = nr + (self.EDGE + beside[1] if beside[1] > 0 else 0)
            for r, rr, open_ in ((closed, rc, False), (opened, ro, True)):
                shown = sorted(self.rects(r, left, rr, ind, open_), key=lambda e: e[1])
                for a, b in zip(shown, shown[1:]):
                    if a[2] > b[1] + 0.01:
                        fails.append("%s (%s): %s overlaps %s" % (where, "open" if open_ else "closed", a, b))
                for e in shown:
                    if e[1] < wallR - 0.01 and e[2] > wallL + 0.01:
                        fails.append("%s (%s): %s on the housing %.1f-%.1f" % (where, "open" if open_ else "closed", e, nl, nr))
                    if e[1] < -0.01 or e[2] > W + 0.01:
                        fails.append("%s: %s off the bar" % (where, e))
                if r["left"][0]["hidden"] or r["left"][0]["x"] != 0 or r["right"][-1]["hidden"] or r["right"][-1]["x"] != 0:
                    fails.append(where + ": the menu or the clock moved")
            # A peek moves nothing but the indicators, or, opening in place, what
            # Omarchy's own peek moves (the right side's items before them).
            if ind is not None and isinstance(right[ind], list):
                p = right[ind][2]
                inplace = opened["right"][ind].get("peekAt") is None
                for side in ("left", "right"):
                    for i, (a, b) in enumerate(zip(closed[side], opened[side])):
                        if side == "right" and i == ind:
                            continue
                        want = 0
                        if side == "right" and inplace and i < ind and not a["hidden"] and a["x"] == 0:
                            want = -p
                        moved = (b["n"] + b["x"]) - (a["n"] + a["x"])
                        if a["hidden"] != b["hidden"] or abs(moved - want) > 0.01:
                            fails.append("%s: %s item %d moved %.1f on the peek (want %.1f)" % (where, side, i, moved, want))
                if closed["right"][ind].get("peekAt") != opened["right"][ind].get("peekAt"):
                    fails.append(where + ": where they open changed with the peek")
                if opened["right"][ind].get("peekAt") is not None:
                    st["left"] += 1
            # Omarchy's own bar has nothing on the housing (closed and open):
            # the setting changes nothing.
            def off_clear(r, rr):
                for i, s_ in enumerate(r["left"]):
                    w = left[i]
                    if w > 0 and s_["n"] < wallR and s_["n"] + w > wallL:
                        return False
                for i, s_ in enumerate(r["right"]):
                    e = rr[i]
                    w = e[0] if isinstance(e, list) else e
                    if w > 0 and s_["n"] < wallR and s_["n"] + w > wallL:
                        return False
                return True
            if off_clear(closed, rc) and off_clear(opened, ro):
                st["fits"] += 1
                for r in (closed, opened):
                    if any(e["x"] != 0 or e["hidden"] or e.get("peekAt") is not None for e in r["left"] + r["right"]):
                        fails.append(where + ": fits, yet the layout differs from Omarchy's")
                        break
            st["jumped"] += closed["jumped"] > 0
            st["hidden"] += closed["hidden"] > 0
            # Hidden in order: on each side's overflow, after the first hidden item all are hidden.
            for side, order in (("left", range(len(closed["left"]))), ("right", range(len(closed["right"]) - 1, -1, -1))):
                seen = False
                for i in order:
                    h = closed[side][i]["hidden"]
                    if seen and not h and closed[side][i]["x"] != 0:
                        fails.append("%s: %s item %d shows after a hidden one" % (where, side, i))
                    seen = seen or h
        if os.environ.get("MATRIX_REPORT"):
            print("\n| device | macOS size (pt) | bars x scales | fit (= setting off) | some jumped | some hidden | peek opens left |")
            print("|---|---|---|---|---|---|---|")
            for (dev, size), v in stats.items():
                print("| %s | %d | %d | %d | %d | %d | %d |" % (dev, size, v["bars"], v["fits"], v["jumped"], v["hidden"], v["left"]))
            print("%d layouts (closed and open), %d failures" % (len(out), len(fails)))
        if os.environ.get("MATRIX_FAILS"):
            print("\n".join(fails))
        self.assertEqual(fails[:20], [], "%d failures" % len(fails))

    def test_a_wobbling_width_moves_nothing_back_and_forth(self):
        # A stats readout that grows and shrinks by 6 points with the tray's
        # edge right at the housing (3 pt clear, then 3 pt under): the tray
        # jumps once and stays until there is room to spare. Without sticking
        # it would jump back and forth every time.
        W, housing = 1470, [645.5, 824.5]
        body = function(patched(), "notchSkipPlace")

        def run(stick):
            prev, sides = None, []
            for k in range(20):
                stats = 133 + (6 if k % 2 else 0)
                right = [0, 21, [0, 0, 105], 27, stats, 27] + [27] * 6 + [132.5]
                # the tray's width that puts its edge 3 pt right of the housing at stats 133
                others = sum(e[0] if isinstance(e, list) else e for e in right) - stats + 133
                right[0] = (W - self.PAD - others) - (housing[1] + 3)
                js = MATRIX.replace("BODY", body).replace("CASES", json.dumps(
                    [[W, self.PAD, [27, 106], right, housing, [0, 0], self.EDGE, self.GAP, self.KEEP, prev, stick]]))
                r = json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)[0]
                prev = r["state"]
                sides.append(r["right"][0]["x"] != 0)
            return sides

        sticky, plain = run(self.STICK), run(0)
        self.assertEqual(sticky, [False] + [True] * 19)   # jumps at the first growth, then stays
        self.assertEqual(plain, [k % 2 == 1 for k in range(20)])   # what it guards against

    def test_decisions_follow_a_real_change(self):
        # Sticking never keeps an item under the housing, and a module removed
        # (the list changed) starts afresh.
        body = function(patched(), "notchSkipPlace")
        def one(right, prev):
            js = MATRIX.replace("BODY", body).replace("CASES", json.dumps(
                [[1470, self.PAD, [27, 106], right, [645.5, 824.5], [0, 0], self.EDGE, self.GAP, self.KEEP, prev, self.STICK]]))
            return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)[0]
        full = [300, 21, [0, 0, 105], 27, 133, 27] + [27] * 6 + [132.5]
        a = one(full, None)
        self.assertNotEqual(a["right"][0]["x"], 0)          # the wide tray jumped
        b = one([81] + full[1:4] + full[5:], a["state"])    # tray small, stats gone
        self.assertEqual(b["right"][0]["x"], 0)             # back on its side at once
        c = one([81, 21, [0, 0, 105], 27, 133, 27] + [27] * 6 + [132.5], b["state"])
        for s in c["right"]:
            self.assertFalse(s["hidden"])


GLIDE = r"""
var queue = [];
var Qt = { callLater: function (f) { if (queue.indexOf(f) < 0) queue.push(f) } };
var clock = 100000; Date.now = function () { return clock };
function flush() { while (queue.length) queue.shift()() }
function Slot(name, memory) {
  var self = this;
  this.slot = this;
  this.moduleName = name; this.notchShown = memory; this.notchShift = null; this.notchShiftGone = false;
  this.notchPlaced = false; this.notchPlaceX = 0; this.notchShiftX = 0; this.notchHold = false; this.notchNew = false;
  this.width = 20; this.notchLastWidth = 20; this.notchPeekFull = 0;
  // implicitWidth follows width unless a step sets it (4.5: equal at rest);
  // the widget's own width follows implicitWidth unless set (a drag differs).
  var iw = null, cw = null;
  Object.defineProperty(this, "implicitWidth", { get: function () { return iw !== null ? iw : self.width },
                                                 set: function (v) { iw = v } });
  Object.defineProperty(this, "notchContentWidth", { get: function () { return cw !== null ? cw : self.implicitWidth },
                                                     set: function (v) { cw = v } });
  this.notchOwnAt = 0; this.notchOpenExtent = 0; this.notchLastOpen = 0; this.notchLastContent = 20; this.notchAppearing = false;
  this.showRestarts = 0; this.limitStarts = 0;
  this.notchShowEnd = { restart: function () { self.showRestarts++ }, stop: function () {} };
  this.notchShowLimit = { restart: function () { self.limitStarts++ }, stop: function () {} };
  this.parent = { forceLayout: function () {} };
  this.notchSlideRun = { running: false };
  this.moves = [];
  var slide = { enabled: false };
  this.notchSlide = slide;
  this.notchFade = { enabled: false };
  this.notchPeekApply = function () {};
  this.region = "left"; this.notchEnd = false;
  this.notchEdge = function (s) { return s.n + s.x + (self.notchEnd ? self.width : 0) };
  this.notchSettle = function () { with (self) { SETTLE } };
  this.endHold = function () { self.notchHold = false; with (self) { HOLDEND } };
  this.notchShowNow = function () { with (self) { SHOWNOW } };
  // Either timer ends the wait (notchShowEnd: quiet; notchShowLimit: 1 s).
  this.endShow = function () { self.notchShowNow() };
  var shown = 0;
  Object.defineProperty(this, "notchShownX", {
    get: function () { return shown },
    set: function (v) { if (v !== shown) self.moves.push([shown, v, slide.enabled]); shown = v } });
}
Slot.prototype.set = function (s) { this.notchShift = s; with (this) { BODY } };
var out = [];
STEPS
console.log(JSON.stringify(out));
"""


@unittest.skipUnless(shutil.which("node"), "node not installed")
class Glide(unittest.TestCase):
    """The slot's own moves (onNotchShiftChanged, notchSettle at the end of a
    round of changes): which ones glide, and that a round glides once."""

    def run_steps(self, steps):
        text = patched()
        m = re.search(r"    onNotchShiftChanged: \{\n(.*?)\n    \}\n", text, re.S)
        settle = function(text, "notchSettle")
        hold = re.search(r"    onNotchHoldChanged: if \(!notchHold\) \{\n(.*?)\n    \}\n", text, re.S).group(1)
        show = function(text, "notchShowNow") if "function notchShowNow(" in text else ""
        js = GLIDE.replace("BODY", m.group(1)).replace("SETTLE", settle).replace("HOLDEND", hold).replace("STEPS", steps)
        js = js.replace("SHOWNOW", show)
        return json.loads(subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True).stdout)

    def test_which_moves_glide(self):
        out = self.run_steps("""
var mem = {};
var a = new Slot("tray", mem);
function round(slot, s) { slot.set(s); flush(); var m = slot.moves.slice(); slot.moves = []; return m }
out.push(round(a, {x: 0, n: 850, hidden: false, animate: false}));     // setting on: at once
out.push(round(a, {x: 0, n: 745, hidden: false, animate: true}));      // Omarchy moved it
out.push(round(a, {x: -300, n: 745, hidden: false, animate: true}));   // it jumped: one glide
var b = new Slot("tray", mem);                                         // Omarchy made the list again
out.push(round(b, {x: 0, n: 860, hidden: false, animate: true}));      // back on its side: glides on
var c = new Slot("clock", mem);
out.push(round(c, {x: 0, n: 1330, hidden: false, animate: true}));     // new, never seen: at once
var d = new Slot("clock", mem);
out.push(round(d, {x: 0, n: 1300, hidden: false, animate: true}));     // in place before and after: at once
""")
        setting_on, omarchy, jumped, rebuilt, new, inplace = out
        self.assertEqual(setting_on, [[0, 850, False]])
        self.assertEqual(omarchy, [[850, 745, False]])
        self.assertEqual(jumped, [[745, 445, True]])
        self.assertEqual(rebuilt, [[0, 445, False], [445, 860, True]])
        self.assertEqual(new, [[0, 1330, False]])
        self.assertEqual(inplace, [[0, 1300, False]])

    def test_a_round_of_changes_glides_once(self):
        # Omarchy makes its list again: the layout passes through a place that
        # is not the end (the tray in its own place far right) and ends where
        # the tray showed. Nothing moves; a new end is one glide.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem);
t.set({x: -300, n: 745, hidden: false, animate: false}); flush(); t.moves = [];
t.set({x: 0, n: 970, hidden: false, animate: true});
t.set({x: -510, n: 955, hidden: false, animate: true}); flush();
out.push(t.moves.slice()); t.moves = [];
var u = new Slot("tray", mem);
u.set({x: 0, n: 970, hidden: false, animate: true});
u.set({x: -500, n: 955, hidden: false, animate: true}); flush();
out.push(u.moves.slice());
""")
        same, rebuilt = out
        self.assertEqual(same, [])
        self.assertEqual(rebuilt, [[0, 445, False], [445, 455, True]])

    def test_a_list_made_again_holds_then_glides_once(self):
        # Omarchy makes the right list again over a few rounds: the new tray
        # slot first sees a place that is not the end (in its own place far
        # right), then the end. It stays where the tray showed, then glides
        # once; the new weather waits unseen and shows at its place.
        out = self.run_steps("""
var mem = {tray: {x: 235.6, ours: true}};
var t = new Slot("tray", mem); t.notchHold = true;
t.set({x: 0, n: 970.8, hidden: false, animate: true}); flush();
t.set({x: -760, n: 995.6, hidden: false, animate: true}); flush();
out.push([t.moves.slice(), t.notchNew]); t.moves = [];
t.endHold(); flush();
out.push(t.moves.slice());
var w = new Slot("weather", mem); w.notchHold = true;
w.set({x: 0, n: 1234.3, hidden: false, animate: true}); flush();
out.push([w.moves.slice(), w.notchNew]); w.moves = [];
w.endHold(); flush();
out.push([w.moves.slice(), w.notchNew]);
""")
        held, after, weather_held, weather_after = out
        self.assertEqual(held, [[[0, 235.6, False]], False])        # where it showed, at once
        self.assertEqual(after, [])                                 # it ended there: nothing moves
        self.assertEqual(weather_held, [[[0, 1234.3, False]], True])  # unseen until the hold ends
        self.assertEqual(weather_after, [[], False])

    def test_a_right_item_keeps_its_end_when_it_grows(self):
        # The tray (jumped left of the housing, its end kept there) gets one
        # more icon: it grows to the left at once, nothing glides.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 459;
t.set({x: -735.2, n: 970.8, hidden: false, animate: false}); flush(); t.moves = [];
t.width = 486; t.set({x: -735.2, n: 943.8, hidden: false, animate: true}); flush();
out.push(t.moves.slice());
""")
        self.assertEqual(out[0], [])

    def test_a_slot_taken_away_before_it_settles(self):
        # Omarchy makes the list again: the old slot's pending notchSettle runs
        # after it is gone (its functions are undefined then): nothing throws.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem);
t.set({x: -300, n: 745, hidden: false, animate: true});
t.notchEdge = undefined;
try { flush(); out.push("ok") } catch (e) { out.push(String(e)) }
""")
        self.assertEqual(out, ["ok"])

    def test_a_peek_glides_nothing(self):
        out = self.run_steps("""
var mem = {};
var ind = new Slot("indicators", mem); ind.notchPeekFull = 105;
ind.set({x: 0, n: 932, hidden: false, animate: true}); flush(); ind.moves = [];
ind.width = 125; ind.set({x: 105, n: 827, hidden: false, peekAt: 533, animate: true}); flush(); out.push(ind.moves.slice());
var tray = new Slot("tray", mem);
tray.set({x: 0, n: 851, hidden: false, animate: true}); flush(); tray.moves = [];
tray.set({x: 105, n: 746, hidden: false, animate: true}); flush(); out.push(tray.moves.slice());
""")
        ind, tray = out
        self.assertEqual(ind, [])        # its own place on the bar did not change
        self.assertEqual(tray, [])       # the tray stays where it showed

    def test_an_own_size_change_moves_at_once(self):
        # A tray right of the housing gets a drawer app: its open width no
        # longer fits there, and it takes its place left of the housing at
        # once, never in a glide under the housing (#757). The same for a
        # widget that grew.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 60; t.notchOpenExtent = 100; t.notchLastOpen = 100;
t.set({x: 0, n: 900, hidden: false, animate: false}); flush(); t.moves = [];
t.notchOpenExtent = 130; t.set({x: -420, n: 900, hidden: false, animate: true}); flush();
out.push(t.moves.slice()); t.moves = [];
t.width = 90; t.set({x: -420, n: 870, hidden: false, animate: true}); flush();
out.push(t.moves.slice()); t.moves = [];
t.width = 120; t.set({x: 0, n: 840, hidden: false, animate: true}); flush();
out.push(t.moves.slice());
""")
        app, grew_in_place, grew_back = out
        self.assertEqual(app, [[960, 540, False]])
        self.assertEqual(grew_in_place, [])          # its end stays: nothing moves
        self.assertEqual(grew_back, [[540, 960, False]])

    def test_the_layouts_next_round_after_an_own_change_is_at_once(self):
        # The layout settles its decisions one round later (notchSkipKeep):
        # a tray that grew stays right in the first round and goes left in
        # the next, with no size change of its own then. Still its own move:
        # at once, never a glide under the housing. A push 100 ms later glides.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 54; t.notchOpenExtent = 27; t.notchLastOpen = 27;
t.set({x: 0, n: 896, hidden: false, animate: false}); flush(); t.moves = [];
t.notchOpenExtent = 54; t.set({x: 0, n: 896, hidden: false, animate: true});
t.set({x: -300, n: 896, hidden: false, animate: true}); flush();
out.push(t.moves.slice()); t.moves = [];
clock += 500; t.set({x: -320, n: 896, hidden: false, animate: true}); flush();
out.push(t.moves.slice());
""")
        kept, pushed = out
        self.assertEqual(kept, [[950, 650, False]])
        self.assertEqual(pushed, [[650, 630, True]])

    def test_a_pushed_item_still_glides_once(self):
        # The weather beside the tray keeps its size; the tray's jump pushes it:
        # that move glides, once.
        out = self.run_steps("""
var mem = {};
var w = new Slot("weather", mem); w.notchEnd = true; w.width = 50;
w.set({x: 0, n: 980, hidden: false, animate: false}); flush(); w.moves = [];
w.set({x: 0, n: 1040, hidden: false, animate: true}); flush(); out.push(w.moves.slice()); w.moves = [];
w.set({x: -120, n: 1040, hidden: false, animate: true}); flush(); out.push(w.moves.slice());
""")
        omarchy, pushed = out
        self.assertEqual(omarchy, [[1030, 1090, False]])  # Omarchy's own move: at once
        self.assertEqual(pushed, [[1090, 970, True]])

    def test_the_drawer_slide_moves_nothing(self):
        # The drawer slides open: the tray grows to the left, its end stays,
        # its place was decided by its open width: no move, no hold.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 60; t.notchOpenExtent = 100; t.notchLastOpen = 100;
t.set({x: -400, n: 900, hidden: false, animate: false}); flush(); t.moves = [];
[80, 110, 140, 160].forEach(function (w) { t.width = w; t.set({x: -400, n: 960 - w, hidden: false, animate: true}); flush() });
out.push([t.moves.slice(), t.notchAppearing, t.showRestarts]);
""")
        self.assertEqual(out[0], [[], False, 0])

    def test_a_drag_does_not_hold(self):
        # A dragged widget's slot asks for no length while its room moves away
        # and gets it back on the drop; the widget kept its width: no hold.
        out = self.run_steps("""
var mem = {};
var c = new Slot("clock", mem); c.width = 70;
c.set({x: 0, n: 1200, hidden: false, animate: false}); flush(); c.moves = [];
c.implicitWidth = 0; c.notchContentWidth = 70; c.set({x: 0, n: 1200, hidden: false, animate: true}); flush();
c.implicitWidth = 70; c.set({x: 0, n: 1200, hidden: false, animate: true}); flush();
out.push([c.moves.slice(), c.notchAppearing, c.showRestarts]);
""")
        self.assertEqual(out[0], [[], False, 0])

    def test_a_shown_up_slot_waits_unseen_then_shows_once_at_its_end_place(self):
        # Omarchy's tray had no width (no app yet). Its apps register one by
        # one: the first fits right of the housing, the later ones do not. The
        # tray stays unseen at each place while they come, then shows once
        # where it stays (#757). The indicators beside it do not hold.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 0; t.notchLastWidth = 0; t.notchLastContent = 0;
t.set({x: 0, n: 1000, hidden: false, animate: true}); flush(); t.moves = [];
t.width = 60; t.set({x: 0, n: 940, hidden: false, animate: true}); flush();
out.push([t.moves.slice(), t.notchAppearing, t.showRestarts]); t.moves = [];
t.width = 90; t.notchOpenExtent = 30; t.set({x: -430, n: 910, hidden: false, animate: true}); flush();
out.push([t.moves.slice(), t.notchAppearing, t.showRestarts]); t.moves = [];
t.endShow(); flush();
out.push([t.moves.slice(), t.notchAppearing, t.notchFade.enabled, mem.tray]);
var i = new Slot("indicators", mem); i.notchEnd = true; i.notchPeekFull = 68; i.width = 40;
i.set({x: 0, n: 1100, hidden: false, animate: false}); flush(); i.moves = [];
i.width = 108; i.set({x: 0, n: 1032, hidden: false, animate: true}); flush();
out.push([i.moves.slice(), i.notchAppearing, i.showRestarts]);
""")
        first, second, shown, peek = out
        self.assertEqual(first, [[], True, 1])                     # unseen, at its place (its end 940 + 60 as before)
        self.assertEqual(second, [[[1000, 570, False]], True, 2])          # the next app: at once, still unseen
        self.assertEqual(shown, [[], False, True, {"x": 570, "ours": True}])  # shows (fades in) where it stays
        self.assertEqual(peek, [[], False, 0])

    def test_a_shown_up_slot_waits_only_for_its_own_place_and_1_s_at_most(self):
        # While the tray waits unseen, other items on the bar change size (the
        # indicators' peek, workspace pills): the layout gives every slot a new
        # shift each time, with the tray's place unchanged. That does not start
        # its 150 ms again; a change of its own place does. Whatever moves, it
        # shows when the 1 s limit ends, at its place then; a limit after it
        # showed does nothing.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 0; t.notchLastWidth = 0; t.notchLastContent = 0;
t.set({x: 0, n: 1000, hidden: false, animate: true}); flush(); t.moves = [];
t.width = 60; t.set({x: -430, n: 940, hidden: false, animate: true}); flush();
for (var k = 0; k < 12; k++) { t.set({x: -430, n: 940, hidden: false, animate: true}); flush() }
out.push([t.moves.slice(), t.notchAppearing, t.showRestarts, t.limitStarts]); t.moves = [];
t.set({x: -400, n: 940, hidden: false, animate: true}); flush();
t.set({x: -400, n: 940, hidden: true, animate: true}); flush();
t.set({x: -400, n: 940, hidden: false, animate: true}); flush();
out.push([t.moves.slice(), t.notchAppearing, t.showRestarts, t.limitStarts]); t.moves = [];
t.endShow(); flush();
out.push([t.moves.slice(), t.notchAppearing, t.notchFade.enabled, mem.tray]);
t.notchFade.enabled = false; t.endShow(); flush();
t.set({x: -400, n: 940, hidden: false, animate: true}); flush();
out.push([t.moves.slice(), t.notchAppearing, t.notchFade.enabled, t.showRestarts, t.limitStarts]);
""")
        same, own, limit, after = out
        self.assertEqual(same, [[[1000, 570, False]], True, 1, 1])   # 12 rounds with its place unchanged: no restart
        self.assertEqual(own, [[[570, 600, False]], True, 4, 1])     # its edge moved, hidden, shown again: 3 restarts
        self.assertEqual(limit, [[], False, True, {"x": 600, "ours": True}])  # the limit shows it where it is
        self.assertEqual(after, [[], False, True, 4, 1])             # a late timer does nothing; no new wait
        text = patched()
        self.assertRegex(text, r"      id: notchShowLimit\n      interval: 1000\n      onTriggered: slot.notchShowNow\(\)\n")
        self.assertRegex(text, r"      id: notchShowEnd\n      interval: 150\n      onTriggered: slot.notchShowNow\(\)\n")

    def test_a_wait_that_ends_while_the_list_is_made_again_does_not_place_it(self):
        # The 150 ms end while Omarchy makes the list again: the tray shows
        # where it waited, and the hold's end places it (one move), not the
        # timer at a place on the way.
        out = self.run_steps("""
var mem = {};
var t = new Slot("tray", mem); t.notchEnd = true; t.width = 0; t.notchLastWidth = 0; t.notchLastContent = 0;
t.set({x: 0, n: 1000, hidden: false, animate: true}); flush(); t.moves = [];
t.width = 60; t.set({x: -430, n: 940, hidden: false, animate: true}); flush(); t.moves = []; clock += 500;
t.notchHold = true; t.set({x: 0, n: 900, hidden: false, animate: true}); flush();
t.endShow(); flush();
out.push([t.moves.slice(), t.notchAppearing]); t.moves = [];
t.set({x: -420, n: 940, hidden: false, animate: true}); t.endHold(); flush();
out.push([t.moves.slice(), t.notchAppearing]);
""")
        during, end = out
        self.assertEqual(during, [[], False])
        self.assertEqual(end, [[[570, 580, True]], False])



WSPATCH = ROOT / "src/omanotch/guest/bar/workspaces-patch.py"


class Workspaces45(unittest.TestCase):
    """Omarchy 4.5 shows each output's own workspaces; the NOTCH copy of the
    bar must show the built-in display's (what the strip stands in for), at
    the parked bar's width, or the strip's clicks land beside the widgets."""

    def stock(self):
        return (SHELL_DIR / "omarchy-ac2690cd/shell/plugins/bar/widgets/Workspaces.qml").read_text()

    def run_patch(self, text):
        d = pathlib.Path(tempfile.mkdtemp())
        try:
            f = d / "Workspaces.qml"
            f.write_text(text)
            out = subprocess.run([sys.executable, str(WSPATCH), str(f)], capture_output=True, text=True)
            return out, f.read_text()
        finally:
            shutil.rmtree(d)

    def test_patch_and_again(self):
        out, full = self.run_patch(self.stock())
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "patched"))
        self.assertEqual(full.count("// omarchy-notch-bar"), 1)
        self.assertEqual(len(full.splitlines()) - len(self.stock().splitlines()), 7)
        out, again = self.run_patch(full)
        self.assertEqual((out.returncode, out.stdout.strip(), again), (0, "already patched", full))

    def test_an_older_widget_stays(self):
        # Omarchy 4.0's widget has no per-output workspaces: nothing to do.
        older = self.stock().replace("return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor",
                                     "return Hyprland.focusedMonitor")
        out, text = self.run_patch(older)
        self.assertEqual((out.returncode, out.stdout.strip(), text), (0, "nothing to patch", older))

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_notch_copy_shows_the_built_in_displays(self):
        out, full = self.run_patch(self.stock())
        body = re.search(r"  readonly property var monitor: \{\n(.*?)\n  \}\n", full, re.S).group(1)
        js = """
var mons = { "Virtual-1": { name: "Virtual-1" }, "Virtual-2": { name: "Virtual-2" }, "NOTCH": { name: "NOTCH" } };
var Hyprland = { monitors: { values: [mons["Virtual-1"], mons["Virtual-2"], mons.NOTCH] },
                 focusedMonitor: mons["Virtual-2"], monitorFor: function (s) { return mons[s.name] } };
function pick(screenName, parked, noBar) {
  var root = { QsWindow: { window: screenName ? { screen: { name: screenName } } : null },
               bar: noBar ? null : { notchParkedScreen: parked } };
  return (function () { BODY })().name;
}
console.log(JSON.stringify([pick("NOTCH", "Virtual-1"), pick("NOTCH", "Virtual-2"), pick("Virtual-1", "Virtual-2"),
  pick("NOTCH", "Virtual-9"), pick("NOTCH", "Virtual-1", true), pick(null, "Virtual-1")]));
""".replace("BODY", body)
        r = subprocess.run(["node", "-e", js], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(r.stdout), ["Virtual-1", "Virtual-2", "Virtual-1", "NOTCH", "NOTCH", "Virtual-2"])

if __name__ == "__main__":
    unittest.main()
