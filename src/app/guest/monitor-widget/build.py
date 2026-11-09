#!/usr/bin/python3
"""Build omacvm.monitor: Omarchy's display panel plus OmacVM.app's switch.

    build.py OUT_DIR [OMARCHY_MONITOR_DIR]

Copies Omarchy's own display widget (/usr/share/omarchy/shell/plugins/panels/
monitor) into OUT_DIR, so it follows the installed Omarchy, and adds a "MAC
DISPLAYS" section with "Use external displays" (omacvm-displays external
toggle), under BRIGHTNESS the Mac's Extra brightness (an XDR display: Omarchy's
own switch, `omacvm extra-brightness`, with the use-with-care text in its (i);
left out when the installed Omarchy lacks the parts or the anchors), and on
a display 4K wide or more a line under the scale presets: 2x
is the sharp one there. In "Full screen including notch" every one of
Omarchy's scale presets on that output, set through `omacvm-displays scale`
(the Mac gives the output a size that fits it first, #355). Omanotch's hidden NOTCH output is left out of its
display list (Omanotch's patch, src/omanotch/guest/monitor/display-panel.py).
OUT_DIR gets this folder's manifest.json and placement.sh and a
.source-sha256 stamp of the panel it was built from. Exit 1 when Omarchy's
panel has changed so much that the switch no longer fits: then the stock
widget stays.
"""

import hashlib
import importlib.machinery
import importlib.util
import pathlib
import re
import shutil
import sys
import textwrap

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_SOURCE = "/usr/share/omarchy/shell/plugins/panels/monitor"
# Omanotch's patch that leaves its hidden NOTCH output out (same copy of src/).
NOTCH_PATCH = HERE.parents[2] / "omanotch/guest/monitor/display-panel.py"

PROPS = """
  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  readonly property color barUrgent: bar ? bar.urgent : Commons.Color.bar.active
  // OmacVM.app: in full screen, Omarchy on every Mac display (omacvm-displays).
  property bool macDisplays: false
  property bool macExternal: true
  // OmacVM.app: the output in "Full screen including notch" ("" otherwise).
  property string macFullPanel: ""
  // OmacVM.app: the focused display's width, for the scale hint below.
  readonly property int macFocusedWidth: {
    for (var i = 0; i < displays.length; i++)
      if (displays[i] && displays[i].focused) return displays[i].width
    return 0
  }
"""

FUNCS = """
  // ---- OmacVM.app: the Mac's external displays ----
  function toggleMacExternal() {
    root.macExternal = !root.macExternal
    macToggleProc.command = ["omacvm-displays", "external", root.macExternal ? "on" : "off"]
    if (!macToggleProc.running) macToggleProc.running = true
  }

  Process {
    id: macStateProc
    command: ["omacvm-displays", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        root.macDisplays = state === "on" || state === "off"
        if (root.macDisplays) root.macExternal = state === "on"
      }
    }
  }

  // ---- OmacVM.app: independent secondary zoom, full-panel sizing, and the
  // main output's scale kept where the screen still follows the window (#738) ----
  function macScaleManagedFocused() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return (root.macFullPanel !== "" && display.name === root.macFullPanel)
          || /^Virtual-[1-9][0-9]*$/.test(display.name)
    }
    return false
  }

  Process {
    id: macFullPanelProc
    command: ["omacvm-displays", "fullpanel"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.macFullPanel = String(text || "").trim()
    }
  }

  Process {
    id: macToggleProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && !macStateProc.running) macStateProc.running = true
  }

"""

SECTION = """          // ---------- OmacVM.app: Mac displays ----------
          PanelSeparator {
            visible: root.macDisplays
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.macDisplays

            PanelSectionHeader {
              text: "MAC DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            CursorSurface {
              id: macExternalRow
              width: panelColumn.width
              hasCursor: root.cursorActive && root.focusSection === "mac"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(macExternalRow)
              foreground: root.bar.foreground
              fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
              implicitHeight: macExternalInner.implicitHeight + Style.spacing.xl

              Row {
                id: macExternalInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  text: "󰍺"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  width: Style.space(22)
                  horizontalAlignment: Text.AlignHCenter
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: "Use external displays"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.macExternal ? "Full screen fills every Mac display"
                                           : "Full screen stays on one Mac display"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.macExternal ? "󰄬" : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.subtitle
                  width: Style.space(14)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "mac"
                  root.selectedIndex = 0
                }
                onClicked: root.toggleMacExternal()
              }
            }
          }

"""

# Under the scale presets on a 4K or larger display: whole scales are the sharp
# and light ones there (docs/troubleshooting.md, finding 24).
SCALE_HINT = """          // ---------- OmacVM.app: which scale suits a 4K or 5K display ----------
          Text {
            visible: root.macFocusedWidth >= 3840
            width: parent.width
            leftPadding: Style.space(6)
            rightPadding: Style.space(6)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "2x is the sharpest here. In-between scales look softer in some apps and use more GPU memory."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

"""

# Omarchy's colours as Commons.Color: on Qt 6.12 a bare Color is QtQuick's
# own (#376). Omarchy's panel imports the alias itself from about October 2026.
COMMONS = "import qs.Commons\n"
COMMONS_ALIAS = "import qs.Commons as Commons\n"

# (anchor, replacement): every anchor must be found exactly once.
EDITS = [
    # The VM's outputs through omacvm-displays; anything else stays Omarchy's.
    ('    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]\n',
     '    actionProc.command = root.macScaleManagedFocused() ? ["/usr/local/bin/omacvm-displays", "scale", String(scale)]\n'
     '      : ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]\n'),
    ("  property int enabledDisplayCount: 0\n",
     "  property int enabledDisplayCount: 0\n" + PROPS),
    ('    if (displays.length > 1) list.push("monitors")\n',
     '    if (displays.length > 1) list.push("monitors")\n'
     '    if (macDisplays) list.push("mac")\n'),
    ('    if (section === "monitors") return displays.length\n',
     '    if (section === "monitors") return displays.length\n'
     '    if (section === "mac") return 1\n'),
    ('    return section === "brightness" || section === "textsize" || section === "scale"\n',
     '    return section === "brightness" || section === "textsize" || section === "scale" || section === "mac"\n'),
    ('    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {\n',
     '    if (focusSection === "mac") {\n'
     '      toggleMacExternal()\n'
     '      return\n'
     '    }\n'
     '    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {\n'),
    ("    if (!stateProc.running) stateProc.running = true\n",
     "    if (!stateProc.running) stateProc.running = true\n"
     "    if (!macStateProc.running) macStateProc.running = true\n"
     "    if (!macFullPanelProc.running) macFullPanelProc.running = true\n"),
    ("  BarIconButton {\n    id: button\n",
     FUNCS + "  BarIconButton {\n    id: button\n"),
    ("          // ---------- Monitors ----------\n",
     SCALE_HINT + "          // ---------- Monitors ----------\n"),
    ("          Item {\n            width: parent.width\n            height: Style.space(4)\n          }\n",
     SECTION + "          Item {\n            width: parent.width\n            height: Style.space(4)\n          }\n"),
]


# Every one of Omarchy's scales in "Full screen including notch" (#355): its
# presets on that output whatever the size (the Mac gives a size that fits
# the one picked), labelled as they are, set through omacvm-displays. Not found (Omarchy changed its
# panel): the panel as Omarchy has it, and the widget still builds.
OPTIONAL_EDITS = [
    ("        return Model.availableScales(scalePresets, display.width, display.height)\n",
     "        return root.macFullPanel !== \"\" && display.name === root.macFullPanel ? scalePresets\n"
     "          : Model.availableScales(scalePresets, display.width, display.height)\n"),
    # The buttons' labels: the preset itself there, not the scale the current
    # size would round it to (at 1.67 on 2940x1915 that read 1x 1.25x 1.67x
    # 2.5x 5x 5x): the Mac gives each preset a size that fits it.
    ("        return Model.cleanScale(scale, display.width, display.height)\n",
     "        return root.macFullPanel !== \"\" && display.name === root.macFullPanel ? normalizeScale(scale)\n"
     "          : Model.cleanScale(scale, display.width, display.height)\n"),
]


# ---- The Mac's Extra brightness (OmacVM.app, an XDR display) ----
# A row right under BRIGHTNESS built like Omarchy's own `Toggle`: its
# ToggleSwitch at the end, the row owning the click and the keyboard cursor
# (section "extra": j/k, Enter, Space), an (i) with Omarchy's PanelToolTip.
# `omacvm extra-brightness` asks OmacVM.app over this VM's control port; the
# app answers itself (ADR 0031). No answer (an app before 3.1.30, not an app
# VM, the control centre off): no row, and no more asking until the panel
# opens again; a row already there stays (the port was busy a moment). All
# or nothing: Omarchy without the parts or the anchors keeps the panel
# without the row.
EXTRA_CAPTION = "Up to 2x on this Mac's XDR display. Use with care."
EXTRA_SAFE = "Off while GPU safe mode is on."
# The HDR sentence is word for word the app's row (SettingsRows.swift, ExtraBrightnessRow).
EXTRA_TIP = ("Makes the VM's main window up to about twice as bright as the Mac's normal white, "
             "with the extra brightness of this Mac's XDR display. Use with care: it uses much more "
             "battery and makes the Mac warmer; macOS turns it down when the Mac gets hot. "
             "With HDR and 10-bit colour on, this wins while it is on: the picture gets brighter, "
             "HDR highlights do not. Off, HDR is back at once. "
             "It ends when the VM stops; the switch keeps your setting for the next start. "
             "Experimental. The same switch as Extra brightness "
             "in the VM's settings on the Mac.")
# PanelToolTip's text has no width or wrap: the lines are broken here.
EXTRA_TIP_WIDTH = 60
EXTRA_CMD = '["/usr/bin/env", "/usr/local/bin/omacvm", "extra-brightness"'
# The Omarchy parts the row uses, with the properties it sets.
EXTRA_UI = {"ToggleSwitch.qml": ["property bool checked", "property bool busy", "property bool interactive",
                                 "property bool hasCursor"],
            "PanelToolTip.qml": ["ToolTip {"]}


def qml_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def extra_tip() -> str:
    return "\n".join(textwrap.wrap(EXTRA_TIP, EXTRA_TIP_WIDTH))


EXTRA_PROPS = """  // OmacVM.app: the Mac's Extra brightness (omacvm extra-brightness).
  property bool macExtraShown: false
  property bool macExtraOn: false
  property bool macExtraSafe: false
  property bool macExtraBusy: false
  // false after no answer and no row (an older app, not an app VM): until the panel opens again
  property bool macExtraAsk: true
  // One more at each click: a reading that started before it is old.
  property int macExtraSeq: 0
  readonly property string macExtraTip: """ + qml_string(extra_tip()) + "\n"

EXTRA_FUNCS = """  // ---- OmacVM.app: the Mac's Extra brightness (an XDR display) ----
  function toggleMacExtra() {
    if (!root.macExtraShown || root.macExtraSafe || root.macExtraBusy) return
    root.macExtraSeq += 1
    root.macExtraOn = !root.macExtraOn
    root.macExtraBusy = true
    macExtraSetProc.command = """ + EXTRA_CMD + """, root.macExtraOn ? "on" : "off", "--json"]
    macExtraSetProc.running = true
  }

  // The answer of omacvm extra-brightness --json: the state, or a refusal
  // ({"code"}). Anything else: no switch here.
  function macExtraAnswer(text) {
    var s = null
    try { s = JSON.parse(String(text || "").trim()) } catch (e) { s = null }
    if (s && typeof s.display === "boolean") {
      root.macExtraShown = s.display
      root.macExtraSafe = s.safe_mode === true
      root.macExtraOn = s.on === true
      return true
    }
    return false
  }

  // Not while a click is on its way: its own answer says how it went.
  function askMacExtra() {
    if (!root.macExtraAsk || root.macExtraBusy || macExtraProc.running) return
    macExtraProc.seq = root.macExtraSeq
    macExtraProc.running = true
  }

  Process {
    id: macExtraProc
    // macExtraSeq when it started (the 5 s refresh may run into a click).
    property int seq: 0
    command: """ + EXTRA_CMD + """, "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Read before the last click: old, the switch would jump back.
        if (macExtraProc.seq !== root.macExtraSeq || root.macExtraBusy) return
        if (root.macExtraAnswer(text)) return
        // No answer. With the row there, the port was busy a moment (the
        // control centre can hold it for a while): the row stays, the next
        // refresh asks again. Without: no row until the panel opens again.
        if (!root.macExtraShown) root.macExtraAsk = false
      }
    }
  }

  Process {
    id: macExtraSetProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.macExtraBusy = false
        if (root.macExtraAnswer(text)) return
        // Refused (the VM's window not in front, too quick) or no answer:
        // back as it was, then the app's own state.
        root.macExtraOn = !root.macExtraOn
        root.macExtraAsk = true
        root.askMacExtra()
      }
    }
  }

  Connections {
    target: root
    function onOpenedChanged() {
      if (!root.opened) return
      root.macExtraAsk = true
      root.askMacExtra()
    }
  }

  // The app's own row (or defaults write) switches it on the Mac too: asked
  // every second while the panel is open, so the switch follows within about
  // a second (Omarchy's refresh comes every 5 s). Not without an app answer.
  Timer {
    interval: 1000
    running: root.opened && root.macExtraAsk
    repeat: true
    onTriggered: root.askMacExtra()
  }

"""

EXTRA_ROW = """          // ---------- OmacVM.app: the Mac's Extra brightness ----------
          PanelSeparator {
            visible: root.macExtraShown && !root.brightnessAvailable
            foreground: root.bar.foreground
          }

          CursorSurface {
            id: macExtraRow
            visible: root.macExtraShown
            width: panelColumn.width
            hasCursor: root.cursorActive && root.focusSection === "extra"
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(macExtraRow)
            foreground: root.bar.foreground
            fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
            implicitHeight: macExtraInner.implicitHeight + Style.spacing.xl
            opacity: root.macExtraSafe ? 0.45 : 1.0

            Row {
              id: macExtraInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                text: "󰃠"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(22) - macExtraInfo.width - macExtraSwitch.width - 3 * parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: "Extra brightness"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.macExtraSafe ? """ + qml_string(EXTRA_SAFE) + """ : """ + qml_string(EXTRA_CAPTION) + """
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }

              Text {
                id: macExtraInfo
                textFormat: Text.PlainText
                text: "󰋽"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter

                PanelToolTip {
                  visible: macExtraRow.hasCursor
                  text: root.macExtraTip
                  fontFamily: root.bar.fontFamily
                }
              }

              // The row owns the click and the cursor, as in Omarchy's Toggle.
              ToggleSwitch {
                id: macExtraSwitch
                checked: root.macExtraOn
                busy: root.macExtraBusy
                interactive: false
                foreground: root.bar.foreground
                accent: Commons.Color.accent
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.macExtraSafe ? Qt.ArrowCursor : Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                root.cursorActive = true
                root.focusSection = "extra"
                root.selectedIndex = 0
              }
              onClicked: root.toggleMacExtra()
            }
          }

"""

# (anchor, replacement) on the panel after EDITS: Omarchy's lines and the ones EDITS wrote.
EXTRA_EDITS = [
    ('  property string macFullPanel: ""\n', '  property string macFullPanel: ""\n' + EXTRA_PROPS),
    ('    if (brightnessAvailable) list.push("brightness")\n',
     '    if (brightnessAvailable) list.push("brightness")\n'
     '    if (macExtraShown) list.push("extra")\n'),
    ('    if (section === "mac") return 1\n',
     '    if (section === "mac") return 1\n'
     '    if (section === "extra") return 1\n'),
    ('section === "scale" || section === "mac"\n', 'section === "scale" || section === "mac" || section === "extra"\n'),
    ('    if (focusSection === "mac") {\n',
     '    if (focusSection === "extra") {\n'
     '      toggleMacExtra()\n'
     '      return\n'
     '    }\n'
     '    if (focusSection === "mac") {\n'),
    ("    if (!macFullPanelProc.running) macFullPanelProc.running = true\n",
     "    if (!macFullPanelProc.running) macFullPanelProc.running = true\n"
     "    root.askMacExtra()\n"),
    ("  BarIconButton {\n    id: button\n", EXTRA_FUNCS + "  BarIconButton {\n    id: button\n"),
    ("          // ---------- Text size ----------\n", EXTRA_ROW + "          // ---------- Text size ----------\n"),
]


def extra_ui_missing(source: pathlib.Path) -> str:
    """The Omarchy parts the row needs, in its shell's Ui folder ("" = all there)."""
    ui = source.parents[2] / "Ui" if len(source.parents) > 2 else source / "Ui"
    for name, needs in EXTRA_UI.items():
        try:
            text = (ui / name).read_text()
        except OSError:
            return name
        for need in needs:
            if need not in text:
                return f"{name} ({need})"
    return ""


def add_extra(panel: str, source: pathlib.Path) -> str:
    """The Extra brightness row, or the panel as it is (and why, on stderr)."""
    missing = extra_ui_missing(source)
    if missing:
        print(f"omacvm.monitor: no Extra brightness switch (Omarchy has no {missing})", file=sys.stderr)
        return panel
    for anchor, _ in EXTRA_EDITS:
        if panel.count(anchor) != 1:
            print(f"omacvm.monitor: no Extra brightness switch (Omarchy's panel changed: {anchor.strip()[:50]!r})",
                  file=sys.stderr)
            return panel
    for anchor, replacement in EXTRA_EDITS:
        panel = panel.replace(anchor, replacement)
    return panel


# Omarchy's panel reads the bar's colours and font straight from `bar`; the
# copy reads them through the guarded properties in PROPS.
BAR_READS = {"root.bar.foreground": "root.barFg", "root.bar.fontFamily": "root.barFont",
             "root.bar.urgent": "root.barUrgent"}


def guard_bar(panel: str) -> str:
    for read, guarded in BAR_READS.items():
        panel = re.sub(re.escape(read) + r"\b", guarded, panel)
    return panel


def hide_notch(panel: str) -> str:
    """Leave Omanotch's NOTCH output out; the panel as it is if that fails."""
    try:
        loader = importlib.machinery.SourceFileLoader("omanotch_display_panel", str(NOTCH_PATCH))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module.patch(panel)
    except (OSError, ValueError, AttributeError) as error:
        print(f"omacvm.monitor: NOTCH stays in the display list ({error})", file=sys.stderr)
        return panel


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = pathlib.Path(sys.argv[1])
    source = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SOURCE)
    panel = (source / "Panel.qml").read_text()
    for anchor, replacement in EDITS:
        if panel.count(anchor) != 1:
            print(f"omacvm.monitor: Omarchy's display panel changed (no {anchor.strip()[:60]!r})",
                  file=sys.stderr)
            return 1
        panel = panel.replace(anchor, replacement)
    if COMMONS_ALIAS not in panel:
        if panel.count(COMMONS) != 1:
            print("omacvm.monitor: Omarchy's display panel changed (no single 'import qs.Commons')", file=sys.stderr)
            return 1
        panel = panel.replace(COMMONS, COMMONS + COMMONS_ALIAS)
    if all(panel.count(anchor) == 1 for anchor, _ in OPTIONAL_EDITS):
        for anchor, replacement in OPTIONAL_EDITS:
            panel = panel.replace(anchor, replacement)
    else:
        print("omacvm.monitor: Omarchy's scale buttons changed: in full screen including notch "
              "only the scales its size fits", file=sys.stderr)
    panel = add_extra(panel, source)
    panel = hide_notch(panel)
    panel = guard_bar(panel)
    out.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        if item.name not in ("Panel.qml", "manifest.json") and item.is_file():
            shutil.copy2(item, out / item.name)
    (out / "Panel.qml").write_text(panel)
    shutil.copy2(HERE / "manifest.json", out / "manifest.json")
    shutil.copy2(HERE / "placement.sh", out / "placement.sh")
    shutil.copy2(HERE / "LICENSE", out / "LICENSE")
    (out / "placement.sh").chmod(0o755)
    digest = hashlib.sha256((source / "Panel.qml").read_bytes()).hexdigest()
    (out / ".source-sha256").write_text(digest + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
