#!/usr/bin/env python3
"""Patch a clone of Omarchy's bar (Bar.qml) for Omanotch.

usage: apply-patch.py <Bar.qml>        (patches the file in place)

The patch is versioned. A file carrying the current version only gets the
older-Omarchy compatibility fix (see COMPAT) if it is still missing; a file
patched by an older version is restored from its unpatched backup
(<Bar.qml>.before-notchbar, kept by install.sh) and patched again.

What the patch adds:
  * A copy of the bar on any output whose name starts with NOTCH (the hidden
    output that feeds the macOS notch helper) lays out its centre widgets
    around the camera housing.
  * While the helper reports that the notch strip is showing ("parked"), the
    bar on the built-in display (Virtual-1 by default) is parked: it stays
    mapped just past the screen edge, reserves no space and uses the same
    notch layout as the NOTCH copy. The helper's clicks are pressed on this
    parked copy, so panels open on the visible display under the strip.
  * IPC target "notchbar" for the helper, and a watchdog that unparks the bar
    when the helper stops sending heartbeats.
  * The bar is remapped when its output moves (Omarchy's own remap never
    fires on Quickshell; see notchRemap), so it does not stay behind at the
    output's old place.
  * notchcast's last word on parking (~/.local/state/omanotch/park), read at
    startup and every few seconds: a shell that (re)starts while the strip
    shows parks at once, and a lost IPC call cannot leave two bars.
"""
import os
import sys

MARK = "omarchy-notch-bar"
VERSION = 15
VERSION_LINE = f"// omarchy-notch-bar patch v{VERSION}"


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        sys.exit(f"apply-patch: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new)


# Omarchy builds up to about September 2026 declare these bar properties as
# `required`. The shell loads a cloned bar by URL and can only set them after
# creation, so such a clone fails to load (and the shell's fallback to the
# stock bar breaks too). Newer builds give them defaults; do the same here.
COMPAT = [
    ("  required property string omarchyPath\n", '  property string omarchyPath: Quickshell.env("OMARCHY_PATH")\n'),
    ("  required property var barWidgetRegistry\n", "  property var barWidgetRegistry: null\n"),
    ("  required property var barConfig\n", "  property var barConfig: ({})\n"),
]


def compat(text):
    for old, new in COMPAT:
        text = text.replace(old, new)
    return text


def main():
    path = sys.argv[1]
    text = open(path).read()
    if VERSION_LINE in text:
        fixed = compat(text)
        if fixed != text:
            open(path, "w").write(fixed)
            print(f"patched (v{VERSION}, older-Omarchy compatibility)")
        else:
            print(f"already patched (v{VERSION})")
        return
    if MARK in text:
        backup = path + ".before-notchbar"
        if not os.path.exists(backup) or MARK in open(backup).read():
            sys.exit(f"apply-patch: {path} carries an older patch and no clean backup exists; "
                     "re-clone the bar (omarchy plugin clone omarchy.bar) and run install.sh again")
        # Patch the clean copy in memory; the file is only written once the
        # whole patch applied, so a failure leaves the old patch in place.
        text = open(backup).read()
        print("replacing an older patch version")

    text = compat(text)

    # 1. State and role helpers (the version line marks the patch).
    text = replace_once(text, '  property string home: Quickshell.env("HOME")\n', '''  property string home: Quickshell.env("HOME")

  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // A hidden output named NOTCH* renders this bar for the macOS notch helper.
  // While the helper shows the strip, the bar on notchParkedScreen is parked
  // (mapped off-screen, no exclusive zone) and takes the helper's clicks, so
  // panels open on the visible display right under the notch strip.
  property bool notchParked: false
  property string notchParkedScreen: "Virtual-1"
  // Camera housing in bar coordinates (logical px == macOS points).
  property real notchLeft: 918
  property real notchRight: 1138
  // Height of the black strip on the Mac (points). The NOTCH copy of the bar
  // is this tall with its content centred, so the strip has no padding the
  // helper would have to fill, and the wallpaper can show through when the
  // bar is hidden. 0 until the helper reports it.
  property real notchHeight: 0
  // Omanotch's flush setting: the NOTCH copy of the bar is only this tall
  // (the camera housing's height) and the wallpaper shows in the rest of the
  // strip below it. 0: the bar fills the strip.
  property real notchBarHeight: 0
  property real notchLastBeat: 0
  // Bumped by the helper's capture program: repaints every bar surface once,
  // so a new capture session gets a frame without waiting for a change.
  property int notchPokeSerial: 0
  // True while a window on the built-in display's active workspace is in
  // real fullscreen (a video, Super+F; not "maximized" or tiled fullscreen).
  // The strip then goes black, as macOS does over full-screen video.
  property bool notchFullscreen: false
  property bool notchFullscreenRecheck: false
  function notchWorkspaceId() {
    var ms = Hyprland.monitors.values
    for (var i = 0; i < ms.length; i++)
      if (ms[i].name === notchParkedScreen && ms[i].activeWorkspace) return ms[i].activeWorkspace.id
    return null
  }
  function notchCheckFullscreen() {
    if (notchFullscreenProc.running) notchFullscreenRecheck = true
    else notchFullscreenProc.running = true
  }
  Process {
    id: notchFullscreenProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      onStreamFinished: {
        var ws = root.notchWorkspaceId(), fs = false
        try {
          var clients = JSON.parse(text)
          for (var i = 0; i < clients.length; i++) {
            var c = clients[i]
            // fullscreen is Hyprland's mode bitmask: 1 maximized, 2 fullscreen.
            if (c.workspace && c.workspace.id === ws && (c.fullscreen & 2)) fs = true
          }
        } catch (e) {}
        root.notchFullscreen = fs
      }
    }
    onExited: if (root.notchFullscreenRecheck) {
      root.notchFullscreenRecheck = false
      running = true
    }
  }
  Timer {
    id: notchFullscreenDebounce
    interval: 50
    running: true  // initial check
    onTriggered: root.notchCheckFullscreen()
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = String(event.name)
      if (n === "fullscreen" || n.indexOf("workspace") === 0 || n.indexOf("focusedmon") === 0 ||
          n === "openwindow" || n === "closewindow" || n.indexOf("movewindow") === 0 ||
          n.indexOf("monitor") === 0)
        notchFullscreenDebounce.restart()
    }
  }
  function notchRoleFor(s) {
    // Only a bar along the top edge can live in the notch strip.
    if (position !== "top") return ""
    var n = s && s.name ? String(s.name) : ""
    if (n.indexOf("NOTCH") === 0) return "notch"
    if (notchParked && n === notchParkedScreen) return "parked"
    return ""
  }
  function notchTargetAt(x, y) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var t = clickTargets[i]
      if (!moduleTargetClickable(t)) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name) !== notchParkedScreen) continue
      // x only: the bar is a single row, and the parked copy is 1 px tall.
      var p = t.mapToItem(w.contentItem, 0, 0)
      if (x >= p.x && x < p.x + t.width) return t
    }
    return null
  }
  function notchTargetRects() {
    var out = []
    for (var i = 0; i < clickTargets.length; i++) {
      var t = clickTargets[i]
      if (!moduleTargetClickable(t)) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name).indexOf("NOTCH") !== 0) continue
      var p = t.mapToItem(w.contentItem, 0, 0)
      out.push([Math.round(p.x), Math.round(p.y), Math.round(t.width), Math.round(t.height)])
    }
    return out
  }
  // --- end omarchy-notch-bar --------------------------------------------
'''.replace("{VERSION_LINE}", VERSION_LINE))

    # 2. IPC target and watchdog, next to the existing omarchy.bar handler.
    text = replace_once(text, '''  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''', '''  // omarchy-notch-bar: control surface for the macOS notch helper.
  IpcHandler {
    target: "notchbar"

    function setParked(on: bool): string {
      root.notchLastBeat = Date.now()
      root.notchParked = on
      return root.notchParked ? "parked" : "unparked"
    }
    function setParkedScreen(name: string): string {
      root.notchParkedScreen = name
      return root.notchParkedScreen
    }
    function setNotch(left: real, right: real): string {
      root.notchLeft = left
      root.notchRight = right
      return left + "," + right
    }
    function setNotchHeight(height: real): string {
      root.notchHeight = height > 0 && height < 200 ? height : 0
      return String(root.notchHeight)
    }
    function setNotchBarHeight(height: real): string {
      root.notchBarHeight = height > 0 && height < 200 ? height : 0
      return String(root.notchBarHeight)
    }
    function poke(): string {
      root.notchPokeSerial++
      return String(root.notchPokeSerial)
    }
    function heartbeat(): string {
      root.notchLastBeat = Date.now()
      return root.notchParked ? "parked" : "unparked"
    }
    function click(x: real, y: real, button: int): string {
      // bar-off or fullscreen: nothing is shown in the strip
      if (root.barHidden || root.notchFullscreen) return "miss"
      var t = root.notchTargetAt(x, y)
      if (!t) return "miss"
      t.triggerPress(button === 3 ? Qt.MiddleButton : button === 2 ? Qt.RightButton : Qt.LeftButton)
      return "ok"
    }
    function wheel(x: real, y: real, delta: int): string {
      if (root.barHidden || root.notchFullscreen) return "miss"
      var t = root.notchTargetAt(x, y)
      if (!t || typeof t.wheelMoved !== "function") return "miss"
      t.wheelMoved(delta)
      return "ok"
    }
    function targets(): string {
      return JSON.stringify(root.barHidden || root.notchFullscreen ? [] : root.notchTargetRects())
    }
    function state(): string {
      return JSON.stringify({ parked: root.notchParked, screen: root.notchParkedScreen,
                              notch: [root.notchLeft, root.notchRight], notchHeight: root.notchHeight, notchBarHeight: root.notchBarHeight, barSize: root.barSize,
                              beatAgeMs: root.notchLastBeat ? Date.now() - root.notchLastBeat : -1,
                              bars: notchBarVariants.instances.map(function(p) {
                                return [p.screen ? String(p.screen.name) : "", p.notchRole, p.parked, p.parkedSize, p.height]
                              }) })
    }
  }

  // Heartbeat and state go through two small files in
  // ~/.local/state/omanotch, so the steady state costs no process at all:
  // notchcast writes `beat` (a millisecond timestamp) every few seconds, the
  // bar writes `bar-state` whenever its parking or size changes. (An IPC call
  // starts a `qs` process each time.)
  readonly property string notchStateDir: home + "/.local/state/omanotch"
  readonly property real notchStartedAt: Date.now()
  FileView {
    id: notchBeatFile
    path: root.notchStateDir + "/beat"
    blockLoading: true
    printErrors: false
  }
  FileView {
    id: notchStateFile
    path: root.notchStateDir + "/bar-state"
    printErrors: false
  }
  function notchWriteState() {
    if (!notchStateFile.path) return  // still being created; the timer below writes it
    notchStateFile.setText(JSON.stringify({ parked: notchParked, barSize: barSize, started: notchStartedAt }) + "\n")
  }
  onNotchParkedChanged: notchWriteState()
  onBarSizeChanged: notchWriteState()
  Timer {
    interval: 500
    running: true
    onTriggered: root.notchWriteState()
  }

  // notchcast's last word on parking: "1 <output>" or "0" (notchcast writes
  // it before its IPC calls). Followed only while notchcast beats, so a file
  // left behind by a notchcast that died changes nothing.
  FileView {
    id: notchParkFile
    path: root.notchStateDir + "/park"
    blockLoading: true
    printErrors: false
  }
  function notchFollowParkFile() {
    notchBeatFile.reload()
    var beat = parseFloat(String(notchBeatFile.text()).trim())
    if (!(beat > 0) || Date.now() - beat > 15000) return
    if (beat > notchLastBeat) notchLastBeat = beat
    notchParkFile.reload()
    var p = String(notchParkFile.text()).trim().split(/\\s+/)
    if (p[0] === "1" && p.length === 2 && /^[A-Za-z0-9_.-]+$/.test(p[1])) {
      if (notchParkedScreen !== p[1]) notchParkedScreen = p[1]
      if (!notchParked) notchParked = true
    } else if (p[0] === "0" && p.length === 1 && notchParked) {
      notchParked = false
    }
  }

  // Follows the park file (at once when the shell starts: a restarted shell
  // must not wait for the next IPC call), and unparks when the helper goes
  // quiet, so the built-in display never ends up without a bar. notchcast
  // beats every 4 s and unparks by itself when the helper or the service
  // stops; the watchdog only catches a notchcast that died. Two tiny file
  // reads every 3 s, no process.
  Timer {
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.notchFollowParkFile()
      if (root.notchParked && Date.now() - root.notchLastBeat > 15000) root.notchParked = false
    }
  }

  Variants {
    id: notchBarVariants
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''')

    # 3. Parking per window instead of only through the global bar-off flag.
    text = replace_once(text, '''    visible: !remapGuard.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
''', '''    // omarchy-notch-bar: notchRemap, see below.
    visible: !remapGuard.remapping && !notchRemap.remapping
    // omarchy-notch-bar: role of this copy ("notch", "parked" or "").
    readonly property string notchRole: root.notchRoleFor(screen)
    // Over fullscreen the NOTCH copy stays mapped, even with the bar off, to
    // paint the strip black.
    readonly property bool notchBlack: notchRole === "notch" && root.notchFullscreen
    readonly property bool parked: (root.barHidden && !notchBlack) || notchRole === "parked"
    readonly property bool notchLayout: notchRole !== ""
    // The parked copy is 1 px tall: panels open at its height + gap, so they
    // appear right below the notch strip instead of a bar height lower.
    // The NOTCH copy fills the whole strip (notchHeight) and centres its
    // content in it.
    // It fills the whole NOTCH output, whose height notchcast rounds up to
    // whole pixels at fractional scales: nothing may show below the bar.
    // Flush (notchBarHeight): only the camera housing's height, the wallpaper
    // below it; over fullscreen the whole strip again, to paint it black.
    readonly property int notchFullSize: Math.max(root.barSize, Math.round(root.notchHeight),
                                                  screen ? Math.ceil(screen.height) : 0)
    readonly property int parkedSize: notchRole === "parked" ? 1
      : notchRole === "notch" ? (root.notchBarHeight > 0 && !notchBlack
                                 ? Math.max(root.barSize, Math.min(Math.round(root.notchBarHeight), notchFullSize))
                                 : notchFullSize) : root.barSize
    readonly property int notchPadTop: notchRole === "notch" ? Math.floor((parkedSize - root.barSize) / 2) : 0
    readonly property int notchPadBottom: notchRole === "notch" ? parkedSize - root.barSize - notchPadTop : 0
    exclusionMode: barWindow.parked ? ExclusionMode.Ignore : ExclusionMode.Auto

    // omarchy-notch-bar: Hyprland leaves a mapped layer surface at its old
    // place when its output moves (the bar is then on no screen at all).
    // Omarchy's ScreenMoveRemap is meant to remap it, but it waits for
    // xChanged/yChanged, which Quickshell's screens do not have (they only
    // have geometryChanged), so it never fires. This does the same on
    // geometryChanged, when the output's position really changed.
    Item {
      id: notchRemap
      visible: false
      property bool remapping: false
      property real lastX: NaN
      property real lastY: NaN
      function note() {
        var s = barWindow.screen
        if (!s || (s.x === lastX && s.y === lastY)) return
        var moved = !isNaN(lastX)
        lastX = s.x
        lastY = s.y
        if (moved) notchRemapSettle.restart()
      }
      Component.onCompleted: note()
      Connections {
        target: barWindow.screen
        function onGeometryChanged() { notchRemap.note() }
      }
      // Let a layout change settle, then unmap for a moment (long enough
      // that the compositor sees the unmap before the new map).
      Timer { id: notchRemapSettle; interval: 200; onTriggered: notchRemap.remapping = true }
      Timer { interval: 100; running: notchRemap.remapping; onTriggered: notchRemap.remapping = false }
    }
''')
    text = replace_once(text, '''      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0''', '''      top: barWindow.parked && root.position === "top" ? -barWindow.parkedSize : 0
      bottom: barWindow.parked && root.position === "bottom" ? -barWindow.parkedSize : 0
      left: barWindow.parked && root.position === "left" ? -barWindow.parkedSize : 0
      right: barWindow.parked && root.position === "right" ? -barWindow.parkedSize : 0''')

    # Omarchy from about October 2026 raises the bar to the camera cutout on
    # Asahi MacBooks (notchFloor); older versions use the bar size alone.
    # Ordinary bars keep Omarchy's height, the notch roles get parkedSize.
    stock_heights = [
        "    implicitHeight: root.vertical ? 0 : Math.max(root.barSize, notchFloor)\n",
        "    implicitHeight: root.vertical ? 0 : root.barSize\n",
    ]
    for stock in stock_heights:
        if text.count("    implicitWidth: root.vertical ? root.barSize : 0\n" + stock) == 1:
            expr = stock.split("root.vertical ? 0 : ", 1)[1].rstrip("\n")
            text = text.replace("    implicitWidth: root.vertical ? root.barSize : 0\n" + stock,
                                "    implicitWidth: root.vertical ? root.barSize : 0\n"
                                f"    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === \"\" ? {expr} : barWindow.parkedSize)\n")
            break
    else:
        sys.exit("apply-patch: could not find the bar's implicitHeight line (Omarchy changed it?)")

    text = replace_once(text, '''    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalBar : horizontalBar
''', '''    Loader {
      anchors.fill: parent
      anchors.topMargin: barWindow.notchPadTop
      anchors.bottomMargin: barWindow.notchPadBottom
      sourceComponent: root.vertical ? verticalBar : horizontalBar
''')

    # 4. Pass the layout mode to the horizontal centre section.
    text = replace_once(text, '''      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.left: parent.left''', '''      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent; notchLayout: barWindow.notchLayout }

        LeftModules {
          anchors.left: parent.left''')

    # 5. Centre widgets around the camera housing in notch layout.
    text = replace_once(text, '''    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''', '''    property var entries: root.layoutEntries("center")
    // omarchy-notch-bar: keep the camera housing free.
    property bool notchLayout: false
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''')
    text = replace_once(text, '''        CenterGestureArea { anchors.fill: parent }

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
''', '''        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        // omarchy-notch-bar: edges of the camera housing plus a small gap.
        Item { id: notchLeftEdge; x: root.notchLeft - Style.space(6); width: 0; height: parent.height }
        Item { id: notchRightEdge; x: root.notchRight + Style.space(6); width: 0; height: parent.height }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerRoot.notchLayout ? notchLeftEdge.left : centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }
''')

    # 6. One-pixel repaint trigger (pixel value unchanged) for notchcast.
    text = replace_once(text, '''    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top
''', '''    WlrLayershell.namespace: "omarchy-bar"
    // omarchy-notch-bar: on the NOTCH output the bar sits on the overlay
    // layer, above Omarchy's notification popups (overlay too; notchbar.lua
    // orders them), which would otherwise show their top edge in the strip.
    WlrLayershell.layer: barWindow.notchRole === "notch" ? WlrLayer.Overlay : WlrLayer.Top

    // omarchy-notch-bar: repaint trigger, see notchPokeSerial.
    Rectangle {
      x: 0; y: 0; width: 1; height: 1; z: -1
      color: root.transparent ? "transparent" : root.background
      opacity: root.notchPokeSerial % 2 ? 0.999 : 1
    }
    // omarchy-notch-bar: black strip over fullscreen windows.
    Rectangle {
      anchors.fill: parent
      z: 1000
      visible: barWindow.notchBlack
      color: "black"
    }
''')

    open(path, "w").write(text)
    print("patched")


if __name__ == "__main__":
    main()
