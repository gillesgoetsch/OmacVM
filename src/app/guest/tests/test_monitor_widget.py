#!/usr/bin/env python3
"""Tests for monitor-widget/build.py, the omacvm.monitor display panel (no VM needed).

    python3 src/app/guest/tests/test_monitor_widget.py
"""
import importlib.machinery
import importlib.util
import pathlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
OMARCHY_COPIES = HERE.parents[2] / "tests/omarchy-shell"
APP_ROWS = HERE.parents[3] / "app/app/Sources/OmacVM/SettingsRows.swift"
loader = importlib.machinery.SourceFileLoader("monitor_widget_build", str(HERE.parent / "monitor-widget/build.py"))
spec = importlib.util.spec_from_loader("monitor_widget_build", loader)
build = importlib.util.module_from_spec(spec)
loader.exec_module(build)

NOTCH_LINE = "// omarchy-notch-bar display panel patch v"


def panel(optional=True):
    """A stand-in for Omarchy's Panel.qml: every line build.py and Omanotch's patch change."""
    lines = [a for a, _ in build.EDITS] + ([a for a, _ in build.OPTIONAL_EDITS] if optional else [])
    lines += ['    if (brightnessAvailable) list.push("brightness")\n', "          // ---------- Text size ----------\n"]
    lines += ["  property var displays: []\n",
              "    var parsed = Model.parseDisplays(displaysJson)\n",
              '    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"\n']
    return build.COMMONS + "Panel {\n" + "".join(lines) + "}\n"


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        # As in Omarchy: shell/plugins/panels/monitor, the parts in shell/Ui.
        self.source = self.tmp / "shell/plugins/panels/monitor"
        self.source.mkdir(parents=True)
        self.ui = self.tmp / "shell/Ui"
        self.ui.mkdir()
        (self.ui / "ToggleSwitch.qml").write_text(
            "Item {\n  property bool checked: false\n  property bool busy: false\n"
            "  property bool interactive: true\n  property bool hasCursor: false\n}\n")
        (self.ui / "PanelToolTip.qml").write_text("ToolTip {\n}\n")
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

    def test_main_output_through_omacvm_displays(self):
        # #738: Omarchy 4.5's command writes a rule for Virtual-1 whose "preferred" mode
        # undoes the window's size; the VM's main output goes through omacvm-displays too.
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('|| /^Virtual-[1-9][0-9]*$/.test(display.name)', text)
        self.assertNotIn('display.name !== "Virtual-1"', text)

    def test_every_scale_in_fullpanel(self):
        # #355: in "Full screen including notch" every preset, set through omacvm-displays.
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('display.name === root.macFullPanel ? scalePresets', text)
        self.assertIn('root.macScaleManagedFocused() ? ["/usr/local/bin/omacvm-displays", "scale", String(scale)]', text)
        self.assertIn(': ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]', text)
        self.assertIn('display.name === root.macFullPanel', text)
        self.assertIn('command: ["omacvm-displays", "fullpanel"]', text)
        self.assertIn("if (!macFullPanelProc.running) macFullPanelProc.running = true", text)
        # The labels are the presets (1x 1.25x 1.6x 2x 3x 4x), not what the current size rounds them to.
        self.assertIn('display.name === root.macFullPanel ? normalizeScale(scale)\n'
                      '          : Model.cleanScale(scale, display.width, display.height)', text)

    def test_scale_buttons_changed_still_builds(self):
        (self.source / "Panel.qml").write_text(panel(optional=False))
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('"MAC DISPLAYS"', text)
        self.assertNotIn("? scalePresets", text)
        self.assertNotIn("? normalizeScale(scale)", text)

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

    def test_omarchys_colours_by_commons(self):
        # Qt 6.12: a bare Color is QtQuick's own (#376). The row's colour is
        # Commons.Color, with the alias imported once (Omarchy's newer panel
        # imports it itself).
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn("Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)", text)
        self.assertNotIn(", Color.accent)", text)
        self.assertEqual(text.count(build.COMMONS_ALIAS), 1)
        (self.source / "Panel.qml").write_text(build.COMMONS_ALIAS + panel())
        self.assertEqual(self.build(), 0)
        self.assertEqual((self.out / "Panel.qml").read_text().count(build.COMMONS_ALIAS), 1)
        (self.source / "Panel.qml").write_text(panel().replace(build.COMMONS, ""))
        self.assertEqual(self.build(), 1)

    def test_extra_brightness_row(self):
        # Under BRIGHTNESS: Omarchy's ToggleSwitch at the end of a row that owns
        # the click and the keyboard cursor, an (i) with the use-with-care text.
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        self.assertIn('text: "Extra brightness"', text)
        self.assertIn('    if (brightnessAvailable) list.push("brightness")\n    if (macExtraShown) list.push("extra")\n', text)
        self.assertIn('    if (section === "extra") return 1\n', text)
        self.assertIn('section === "scale" || section === "mac" || section === "extra"\n', text)
        self.assertIn('    if (focusSection === "extra") {\n      toggleMacExtra()\n', text)
        self.assertIn('hasCursor: root.cursorActive && root.focusSection === "extra"', text)
        self.assertIn("ToggleSwitch {\n                id: macExtraSwitch", text)
        self.assertIn("interactive: false", text)
        self.assertIn("PanelToolTip {\n                  visible: macExtraRow.hasCursor", text)
        self.assertIn(build.qml_string(build.EXTRA_CAPTION), text)
        self.assertIn(build.qml_string(build.EXTRA_SAFE), text)
        self.assertIn("opacity: root.macExtraSafe ? 0.45 : 1.0", text)
        self.assertIn('["/usr/bin/env", "/usr/local/bin/omacvm", "extra-brightness", "--json"]', text)
        self.assertIn('"extra-brightness", root.macExtraOn ? "on" : "off", "--json"]', text)
        # Asked at each refresh only while it answers; again when the panel opens.
        self.assertIn("    root.askMacExtra()\n", text)
        self.assertIn("root.macExtraAsk = false", text)
        self.assertIn("function onOpenedChanged()", text)
        # The app's row switched on the Mac: the open panel asks every second (Omarchy's refresh is 5 s),
        # and not at all once there is no app answer.
        self.assertIn("  Timer {\n    interval: 1000\n    running: root.opened && root.macExtraAsk\n"
                      "    repeat: true\n    onTriggered: root.askMacExtra()\n  }\n", text)
        # A reading that started before a click (the 5 s refresh) is dropped, and none starts while
        # a click is on its way: the switch never jumps back to the old state.
        self.assertIn("    root.macExtraSeq += 1\n    root.macExtraOn = !root.macExtraOn\n", text)
        self.assertIn("if (!root.macExtraAsk || root.macExtraBusy || macExtraProc.running) return\n"
                      "    macExtraProc.seq = root.macExtraSeq\n", text)
        self.assertIn("if (macExtraProc.seq !== root.macExtraSeq || root.macExtraBusy) return\n", text)
        # No answer: no row only when there was none; a busy port keeps the row.
        self.assertIn("        if (!root.macExtraShown) root.macExtraAsk = false\n", text)
        self.assertNotIn("root.macExtraShown = false", text)
        # A refused or unanswered click: the switch back as it was, then the app's state.
        self.assertIn("        if (root.macExtraAnswer(text)) return\n"
                      "        // Refused (the VM's window not in front, too quick) or no answer:\n"
                      "        // back as it was, then the app's own state.\n"
                      "        root.macExtraOn = !root.macExtraOn\n", text)
        # Its row: right under BRIGHTNESS (before TEXT SIZE), Omarchy's colours as Commons.Color (#376).
        self.assertLess(text.index("id: macExtraRow"), text.index("// ---------- Text size ----------"))
        row = text[text.index("id: macExtraRow"):text.index("// ---------- Text size ----------")]
        self.assertIn("Commons.Color.accent", row)
        self.assertNotIn(" Color.accent", row.replace("Commons.Color.accent", ""))

    def test_extra_brightness_writes_only_on_a_click(self):
        # The switch keeps the user's setting: the panel writes it only from its own click or key, as the
        # opposite of what the app last answered. Opening, the 1 s refresh, Omarchy's refresh and a VM start
        # only read; before the app's first answer there is no row, so nothing can be written back.
        self.assertEqual(self.build(), 0)
        text = (self.out / "Panel.qml").read_text()
        toggle = text[text.index("  function toggleMacExtra() {"):text.index("  function macExtraAnswer(text)")]
        # One write in the whole panel, in toggleMacExtra, behind its guard.
        self.assertEqual(text.count('root.macExtraOn ? "on" : "off"'), 1)
        self.assertEqual(text.count("macExtraSetProc.running = true"), 1)
        self.assertIn('root.macExtraOn ? "on" : "off"', toggle)
        self.assertIn("macExtraSetProc.running = true", toggle)
        self.assertEqual(toggle.split("\n")[1],
                         "    if (!root.macExtraShown || root.macExtraSafe || root.macExtraBusy) return")
        # No row (and no switch) until the app has answered: shown only from an answer.
        self.assertIn("  property bool macExtraShown: false\n", text)
        self.assertEqual(re.findall(r"root\.macExtraShown = [^\n]*", text), ["root.macExtraShown = s.display"])
        # The switch shows the app's answer, a click, or a refused click undone; nothing else sets it.
        self.assertEqual(sorted(re.findall(r"root\.macExtraOn = [^\n]*", text)),
                         ["root.macExtraOn = !root.macExtraOn", "root.macExtraOn = !root.macExtraOn",
                          "root.macExtraOn = s.on === true"])
        self.assertIn("    root.macExtraOn = !root.macExtraOn\n    root.macExtraBusy = true\n", toggle)
        # The reader only asks.
        self.assertIn('    command: ["/usr/bin/env", "/usr/local/bin/omacvm", "extra-brightness", "--json"]\n', text)
        # Called from the row's click and Return/Space on its row only.
        lines = text.split("\n")
        calls = [i for i, line in enumerate(lines) if "toggleMacExtra()" in line and "function" not in line]
        self.assertEqual([lines[i].strip() for i in calls], ["toggleMacExtra()", "onClicked: root.toggleMacExtra()"])
        self.assertEqual(lines[calls[0] - 1].strip(), 'if (focusSection === "extra") {')
        # Opening the panel and the timer ask, never switch.
        opened = text[text.index("    function onOpenedChanged() {"):text.index("  // The app's own row")]
        timer = text[text.index("  Timer {\n    interval: 1000"):text.index("  BarIconButton {")]
        for part in (opened, timer):
            self.assertIn("askMacExtra()", part)
            self.assertNotIn("toggleMacExtra", part)
            self.assertNotIn('"on"', part)

    def test_extra_brightness_tip(self):
        # PanelToolTip neither wraps nor limits its width: the text comes in lines.
        tip = build.extra_tip()
        self.assertTrue(all(len(line) <= 64 for line in tip.split("\n")), tip)
        self.assertGreater(tip.count("\n"), 4)
        self.assertIn("Use with care", tip.replace("\n", " "))
        hdr = ("With HDR and 10-bit colour on, this wins while it is on: the picture gets brighter, "
               "HDR highlights do not. Off, HDR is back at once.")
        self.assertIn(hdr, " ".join(tip.split("\n")))
        # The same sentence as the app's own row, once the app says it.
        rows = APP_ROWS.read_text() if APP_ROWS.is_file() else ""
        if "With HDR and 10-bit colour on" in rows:
            self.assertIn(hdr, rows)
        # Both say the switch stays as the user set it.
        self.assertIn("the switch keeps your setting for the next start", " ".join(tip.split("\n")))
        if rows:
            self.assertIn("The switch keeps your setting for the next start", rows)

    def test_extra_brightness_needs_omarchys_parts(self):
        # Without Omarchy's ToggleSwitch (or one without busy) or PanelToolTip the
        # panel would not load at all: it is built without the row.
        for broken in ("ToggleSwitch.qml", "PanelToolTip.qml", "busy"):
            if broken == "busy":
                (self.ui / "ToggleSwitch.qml").write_text("Item {\n  property bool checked: false\n}\n")
            else:
                (self.ui / broken).unlink()
            self.assertEqual(self.build(), 0)
            text = (self.out / "Panel.qml").read_text()
            self.assertIn('"MAC DISPLAYS"', text)
            self.assertNotIn("macExtra", text)
            self.setUp()

    def test_extra_brightness_anchors_all_or_nothing(self):
        for anchor in ('    if (brightnessAvailable) list.push("brightness")\n', "          // ---------- Text size ----------\n"):
            (self.source / "Panel.qml").write_text(panel().replace(anchor, ""))
            self.assertEqual(self.build(), 0)
            text = (self.out / "Panel.qml").read_text()
            self.assertIn('"MAC DISPLAYS"', text)
            self.assertNotIn("macExtra", text)

    def test_extra_brightness_on_omarchys_panels(self):
        # Omarchy's own files: omarchy-mac's and upstream's newer shell.
        for v in ("omarchy-mac-ba546a61", "omarchy-a06ec133"):
            source = OMARCHY_COPIES / v / "shell/plugins/panels/monitor"
            out = self.tmp / v
            with mock.patch.object(sys, "argv", ["build.py", str(out), str(source)]), mock.patch("sys.stderr"):
                self.assertEqual(build.main(), 0, v)
            text = (out / "Panel.qml").read_text()
            self.assertIn("id: macExtraRow", text, v)
            self.assertIn('"MAC DISPLAYS"', text, v)
            self.assertEqual(text.count("toggleMacExtra()"), 3, v)   # defined, Enter/Space, click

    def test_patch_path(self):
        # The same copy of src/ in the repository and in the VM (/usr/local/share/omacvm).
        self.assertTrue(build.NOTCH_PATCH.is_file(), build.NOTCH_PATCH)


if __name__ == "__main__":
    unittest.main()
