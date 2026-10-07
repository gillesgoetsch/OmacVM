#!/usr/bin/env python3
"""Tests for monitor-widget/build.py, the omacvm.monitor display panel (no VM needed).

    python3 src/app/guest/tests/test_monitor_widget.py
"""
import importlib.machinery
import importlib.util
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("monitor_widget_build", str(HERE.parent / "monitor-widget/build.py"))
spec = importlib.util.spec_from_loader("monitor_widget_build", loader)
build = importlib.util.module_from_spec(spec)
loader.exec_module(build)

NOTCH_LINE = "// omarchy-notch-bar display panel patch v"


def panel():
    """A stand-in for Omarchy's Panel.qml: every line build.py and Omanotch's patch change."""
    lines = [a for a, _ in build.EDITS]
    lines += ["  property var displays: []\n",
              "    var parsed = Model.parseDisplays(displaysJson)\n",
              '    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"\n']
    return "Panel {\n" + "".join(lines) + "}\n"


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.source = self.tmp / "monitor"
        self.source.mkdir()
        (self.source / "Panel.qml").write_text(panel())
        (self.source / "Model.js").write_text("")
        (self.source / "manifest.json").write_text("{}")
        self.out = self.tmp / "omacvm.monitor"

    def build(self):
        with mock.patch.object(sys, "argv", ["build.py", str(self.out), str(self.source)]), \
             mock.patch("sys.stderr"):
            return build.main()

    def test_notch_left_out(self):
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('"MAC DISPLAYS"', text)
        self.assertIn(NOTCH_LINE, text)
        self.assertIn("Model.parseDisplays(root.notchFilterJson(displaysJson))", text)
        self.assertIn("root.notchScreenCount() > 1", text)

    def test_without_omanotch_patch(self):
        # Omanotch's patch missing or no longer fitting: the widget still builds.
        with mock.patch.object(build, "NOTCH_PATCH", self.tmp / "missing.py"):
            self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('"MAC DISPLAYS"', text)
        self.assertNotIn(NOTCH_LINE, text)
        (self.source / "Panel.qml").write_text(panel().replace("Quickshell.screens.length", "screens.count"))
        self.assertEqual(self.build(), 0)
        self.assertNotIn(NOTCH_LINE, (self.out / "Panel.qml").read_text())

    def test_patch_path(self):
        # The same copy of src/ in the repository and in the VM (/usr/local/share/omacvm).
        self.assertTrue(build.NOTCH_PATCH.is_file(), build.NOTCH_PATCH)


if __name__ == "__main__":
    unittest.main()
