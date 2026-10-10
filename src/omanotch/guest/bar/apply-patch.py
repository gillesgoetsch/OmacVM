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
  * The right bar from the first frame after login: when the strip showed at
    the end of the last session (~/.local/state/omanotch/expect), the bar
    starts parked, with the notch geometry it had then (geom), and only
    comes back if Omanotch does not confirm within a few seconds.
  * FullPanel (OmacVM.app, experimental, #339): when the app's full screen
    covers the strip itself (/run/omacvm/host.env: OMACVM_FULLPANEL, the
    camera housing in Mac points), the bar on the built-in display sits in
    the strip, as tall as it, split around the housing, and reserves it
    (windows start below it; black over full-screen windows and while the
    bar is hidden). Only while the app says that output covers the whole
    display in full screen ($XDG_RUNTIME_DIR/omacvm/displays.json); else
    the bar is the normal one. notchcast does not run in such a boot.
"""
import os
import sys

MARK = "omarchy-notch-bar"
VERSION = 20
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
  // The NOTCH copy's height and top padding [height, pad] (logical px).
  // The strip shows NOTCH's bottom `strip` px: notchcast rounds NOTCH up to
  // whole pixels at fractional scales and the Mac cuts those extra rows off
  // at the top. So the bar (`size` tall) is centred in that bottom part, or
  // in its top `flush` px when the bar is only the camera housing's height,
  // and the padding is snapped to whole pixels of the output (`scale`).
  function notchBox(outH, strip, flush, size, scale) {
    var full = Math.max(size, Math.round(strip), outH)
    var cut = strip > 0 && strip < full ? full - strip : 0
    var region = flush > 0 ? Math.max(size, Math.min(flush, full - cut)) : full - cut
    var s = scale > 0 ? scale : 1
    var pad = Math.round((cut + (region - size) / 2) * s) / s
    return [flush > 0 ? Math.ceil(cut + region) : full, pad]
  }
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
  // FullPanel (OmacVM.app): the camera housing from host.env, in Mac points
  // [left, right, strip, width, height]; [] when this boot is not one.
  property var notchPanel: []
  // The built-in display's output covers the whole display in full screen
  // (displays.json): the bar on it sits in the strip.
  property bool notchPanelOn: false
  property string notchPanelScreen: "Virtual-1"
  // host.env's OMACVM_FULLPANEL=LxRxHxWxD -> the five numbers, [] if none or odd
  // (the same limits as the app's NotchGeometry.valid).
  function notchPanelParse(text) {
    var m = String(text).match(/^OMACVM_FULLPANEL=([0-9.]+)x([0-9.]+)x([0-9.]+)x([0-9.]+)x([0-9.]+)$/m)
    if (!m) return []
    var g = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])]
    if (!g.every(isFinite) || !(g[0] > 0 && g[1] > g[0] && g[1] < g[3] && g[1] - g[0] < g[3] / 3 &&
        g[2] >= 10 && g[2] <= 100 && g[3] >= 800 && g[4] > g[2] * 5)) return []
    return g
  }
  // From the app's layout message (displays.json) and the geometry: the
  // built-in display's output, and whether it covers the strip now (full
  // screen, at least the display's height less half the strip: the app's
  // clean size cuts a few rows at the bottom, below the notch it would be a
  // whole strip shorter).
  function notchPanelState(layoutText, g) {
    var out = { on: false, screen: "" }
    if (!g || g.length !== 5) return out
    try {
      var m = JSON.parse(String(layoutText))
      if (!m || typeof m.builtin !== "string" || !/^Virtual-[0-9]+$/.test(m.builtin)) return out
      out.screen = m.builtin
      if (m.fullscreen !== true || !Array.isArray(m.layout)) return out
      for (var i = 0; i < m.layout.length; i++) {
        var o = m.layout[i]
        if (o && o.output === m.builtin && Number(o.height) >= g[4] - g[2] / 2 &&
            Number(o.width) >= g[3] - 1) out.on = true
      }
    } catch (e) {}
    return out
  }
  // The housing and the strip in the output's logical pixels (the guest's
  // scale need not be the Mac's): [left, right, strip].
  function notchPanelBox(g, logicalWidth) {
    var k = logicalWidth > 0 ? logicalWidth / g[3] : 0
    return [g[0] * k, g[1] * k, g[2] * k]
  }
  function notchRoleFor(s) {
    // Only a bar along the top edge can live in the notch strip.
    if (position !== "top") return ""
    var n = s && s.name ? String(s.name) : ""
    if (n.indexOf("NOTCH") === 0) return "notch"
    if (notchPanelOn && n === notchPanelScreen) return "fullpanel"
    if (notchParked && n === notchParkedScreen) return "parked"
    return ""
  }
  // Omanotch's pointer over the strip (#308). The guest's pointer is not on
  // this bar then, so its hover handlers see nothing. Omanotch says where the
  // pointer is (x in bar px, -1: it left the strip), and the bar does what
  // its own hover handlers do: the auto-hidden indicators show while the
  // pointer is on the bar's free space and stay until it leaves the bar.
  property bool notchHovering: false
  function notchHover(x) {
    var stock = typeof root.setCenterSectionHovered === "function" && typeof root.setBarHovered === "function"
    if (x < 0 || root.barHidden || root.notchFullscreen) {
      if (!root.notchHovering) return "off"
      root.notchHovering = false
      if (stock) { root.setCenterSectionHovered(false); root.setBarHovered(false) }
      return "off"
    }
    if (!stock) return "unsupported"
    if (!root.notchHovering) { root.notchHovering = true; root.setBarHovered(true) }
    var t = root.notchTargetAt(x, 0)
    root.setCenterSectionHovered(!t)
    return t ? "widget" : "free"
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
      root.notchBootPark = false
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
      root.notchBootPark = false
      return root.notchParked ? "parked" : "unparked"
    }
    // Omanotch saw the VM full screen on the built-in display when it
    // connected: the strip is coming. Parked now, as with the boot hint, so
    // the display shows no bar of its own in the meantime (after a windowed
    // session the hint said "0").
    function bootPark(name: string): string {
      if (root.notchParked && !root.notchBootPark) return "parked"
      root.notchBootParkOn(name)
      return "boot-parked"
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
    function hover(x: real): string {
      return root.notchHover(x)
    }
    function targets(): string {
      return JSON.stringify(root.barHidden || root.notchFullscreen ? [] : root.notchTargetRects())
    }
    function state(): string {
      return JSON.stringify({ parked: root.notchParked, screen: root.notchParkedScreen,
                              fullpanel: root.notchPanel.length ? (root.notchPanelOn ? "strip" : "waiting") : "off",
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
  // blockAllReads: text() right after reload() waits for the new content
  // (with blockLoading alone it returns the previous load's text).
  FileView {
    id: notchBeatFile
    path: root.notchStateDir + "/beat"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchStateFile
    path: root.notchStateDir + "/bar-state"
    printErrors: false
  }
  function notchWriteState() {
    if (!notchStateFile.path) return  // still being created; the timer below writes it
    notchStateFile.setText(JSON.stringify({ parked: notchParked, barSize: barSize, started: notchStartedAt,
                                            fullpanel: notchPanel.length ? (notchPanelOn ? "strip" : "waiting") : "off" }) + "\n")
  }
  onNotchParkedChanged: notchWriteState()
  onNotchPanelOnChanged: notchWriteState()
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
    blockAllReads: true
    printErrors: false
  }
  function notchFollowParkFile() {
    notchBeatFile.reload()
    var beat = parseFloat(String(notchBeatFile.text()).trim())
    if (!(beat > 0) || Date.now() - beat > 15000) return
    notchParkFile.reload()
    var p = String(notchParkFile.text()).trim().split(/\\s+/)
    // "w <output>": notchcast is connected and waits for Omanotch's word
    // (often since before this shell started). Keeps a boot-parked bar
    // parked up to 15 s after that beat (the strip's first frame can take a
    // few seconds); changes nothing else.
    if (p[0] === "w") {
      if (notchBootPark && beat > notchLastBeat) {
        notchLastBeat = beat
        notchArmExpiry()
      }
      return
    }
    if (beat > notchLastBeat) notchLastBeat = beat
    notchBootPark = false
    if (p[0] === "1" && p.length === 2 && /^[A-Za-z0-9_.-]+$/.test(p[1])) {
      if (notchParkedScreen !== p[1]) notchParkedScreen = p[1]
      if (!notchParked) notchParked = true
    } else if (p[0] === "0" && p.length === 1 && notchParked) {
      notchParked = false
    }
  }

  // notchcast's word on the strip that outlives a reboot: "1 <output>" when
  // it showed at the end of the last session, "0" when it was hidden or
  // Omanotch went away. With "1" the shell starts parked, so the first frame
  // after login already has the bar in the strip only (no bar on the display
  // that then disappears, no windows that jump). If Omanotch does not confirm
  // within notchBootGraceMs (windowed now, or Omanotch not running), the bar
  // comes back and the file says "0", so the next start does not guess again.
  // The notch geometry of the last session (geom, "left right strip bar")
  // lays out the NOTCH copy right from its first frame.
  readonly property real notchBootGraceMs: 8000
  property bool notchBootPark: false
  // OmacVM.app with external displays: the built-in display may be another
  // output than in the last session; this file names it (when it is there yet).
  FileView {
    id: notchBuiltinFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/builtin"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchBootParkOn(name) {
    notchBuiltinFile.reload()
    var b = String(notchBuiltinFile.text()).trim()
    if (/^Virtual-[0-9]+$/.test(b)) name = b
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) return
    notchParkedScreen = name
    notchLastBeat = Date.now() - 15000 + notchBootGraceMs
    notchBootPark = true
    notchParked = true
    notchArmExpiry()
  }
  // Brings a guessed bar back on time when nothing confirms the guess (the
  // 3 s timer alone would make it up to 3 s later).
  Timer {
    id: notchBootExpiry
    onTriggered: root.notchWatchdog()
  }
  function notchArmExpiry() {
    notchBootExpiry.interval = Math.max(50, notchLastBeat + 15000 - Date.now() + 50)
    notchBootExpiry.restart()
  }
  FileView {
    id: notchExpectFile
    path: root.notchStateDir + "/expect"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchGeomFile
    path: root.notchStateDir + "/geom"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  // FullPanel: what the app said at this start (fixed for the boot) and its
  // layout message (each display change).
  FileView {
    id: notchHostEnvFile
    path: "/run/omacvm/host.env"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchLayoutFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/displays.json"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchPanelUpdate() {
    if (!notchPanel.length) return
    notchLayoutFile.reload()
    var st = notchPanelState(notchLayoutFile.text(), notchPanel)
    if (st.screen && st.screen !== notchPanelScreen) notchPanelScreen = st.screen
    var on = false
    var ss = Quickshell.screens
    for (var i = 0; st.on && i < ss.length; i++) {
      if (String(ss[i].name) !== notchPanelScreen) continue
      var b = notchPanelBox(notchPanel, ss[i].width)
      if (b[1] > b[0] && b[2] > 0) {
        if (notchLeft !== b[0]) notchLeft = b[0]
        if (notchRight !== b[1]) notchRight = b[1]
        if (notchHeight !== b[2]) notchHeight = b[2]
        // Fullscreen windows on it paint the strip black (notchWorkspaceId).
        if (notchParkedScreen !== notchPanelScreen) notchParkedScreen = notchPanelScreen
        on = true
      }
    }
    if (on !== notchPanelOn) notchPanelOn = on
  }
  function notchBoot() {
    notchPanel = notchPanelParse(notchHostEnvFile.text())
    if (notchPanel.length) {
      notchPanelUpdate()
      return
    }
    var g = String(notchGeomFile.text()).trim().split(/\\s+/).map(Number)
    if (g.length === 4 && g.every(isFinite) && g[0] > 0 && g[1] > g[0]) {
      notchLeft = g[0]
      notchRight = g[1]
      notchHeight = g[2] > 0 && g[2] < 200 ? g[2] : 0
      notchBarHeight = g[3] > 0 && g[3] < 200 ? g[3] : 0
    }
    // The hint first, then notchcast's word if it has one already (a fresh
    // beat: notchcast removes a beat it did not write itself when it starts).
    var e = String(notchExpectFile.text()).trim().split(/\\s+/)
    if (e[0] === "1" && e.length === 2 && /^[A-Za-z0-9_.-]+$/.test(e[1])) notchBootParkOn(e[1])
    notchFollowParkFile()
  }
  property bool notchBooted: false
  function notchWatchdog() {
    if (notchParked && Date.now() - notchLastBeat > 15000) {
      notchParked = false
      if (notchBootPark) {
        notchBootPark = false
        notchExpectFile.setText("0\\n")
      }
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
      if (!root.notchBooted) {
        root.notchBooted = true
        root.notchBoot()
      } else if (root.notchPanel.length) {
        root.notchPanelUpdate()
      } else {
        root.notchFollowParkFile()
      }
      root.notchWatchdog()
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
    // paint the strip black. FullPanel's bar too, and while the bar is hidden
    // it stays as a black strip, so the windows never go under the notch.
    readonly property bool notchBlack: (notchRole === "notch" && root.notchFullscreen) ||
                                       (notchRole === "fullpanel" && (root.notchFullscreen || root.barHidden))
    readonly property bool parked: (root.barHidden && !notchBlack) || notchRole === "parked"
    readonly property bool notchLayout: notchRole !== ""
    // The parked copy is 1 px tall: panels open at its height + gap, so they
    // appear right below the notch strip instead of a bar height lower.
    // The NOTCH copy fills the whole NOTCH output (nothing may show below the
    // bar) and centres its content in the part the strip shows (notchBox).
    // Flush (notchBarHeight): only the camera housing's height, the wallpaper
    // below it; over fullscreen the whole strip again, to paint it black.
    readonly property var notchFit: root.notchBox(screen ? Math.ceil(screen.height) : 0, root.notchHeight,
                                                  notchBlack ? 0 : root.notchBarHeight, root.barSize,
                                                  screen ? screen.devicePixelRatio : 1)
    // FullPanel: the bar is the strip's height, its content centred, so its
    // exclusive zone keeps the strip beside the notch free of windows.
    readonly property var notchPanelFit: root.notchBox(0, root.notchHeight, 0, root.barSize,
                                                       screen ? screen.devicePixelRatio : 1)
    readonly property int parkedSize: notchRole === "parked" ? 1
      : notchRole === "notch" ? notchFit[0] : notchRole === "fullpanel" ? notchPanelFit[0] : root.barSize
    readonly property real notchPadTop: notchRole === "notch" ? notchFit[1] : notchRole === "fullpanel" ? notchPanelFit[1] : 0
    readonly property real notchPadBottom: notchRole === "notch" || notchRole === "fullpanel"
      ? parkedSize - root.barSize - notchPadTop : 0
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
        function onGeometryChanged() { notchRemap.note(); root.notchPanelUpdate() }
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
    // FullPanel's bar likewise: above full-screen windows, to paint the strip black.
    WlrLayershell.layer: barWindow.notchRole === "notch" || barWindow.notchRole === "fullpanel" ? WlrLayer.Overlay : WlrLayer.Top

    // omarchy-notch-bar: repaint trigger, see notchPokeSerial.
    Rectangle {
      x: 0; y: 0; width: 1; height: 1; z: -1
      color: root.transparent ? "transparent" : root.background
      opacity: root.notchPokeSerial % 2 ? 0.999 : 1
    }
    // omarchy-notch-bar: black strip over fullscreen windows (FullPanel: also
    // while the bar is hidden; it takes the clicks the hidden bar would get).
    Rectangle {
      anchors.fill: parent
      z: 1000
      visible: barWindow.notchBlack
      color: "black"
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; enabled: barWindow.notchRole === "fullpanel" }
    }
''')

    open(path, "w").write(text)
    print("patched")


if __name__ == "__main__":
    main()
