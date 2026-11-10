import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import "Layout.js" as Layout

// Mission Control: the workspace's windows spread out so that none overlaps,
// following a four-finger swipe, with the desktops along the top.
// https://github.com/gillesgoetsch/omarchy-mac-mission-control
//
// Hyprland (hypr/mac-mission-control.lua, which this file loads into it)
// forwards the gesture and a snapshot of the desktop as custom events
// ("mmc>>..."); everything else is
// here: the state, the layout (Layout.js), the drawing.
//
// How it stays seamless: every window is drawn as a live copy (ScreencopyView)
// with a replica of its titlebar, border and shadow, first exactly where the
// real one is. The copies are captured while the overlay is still unmapped;
// it maps once they all have a frame, so its first frame already shows them,
// and Hyprland hides the real windows in the handler of that very map ("h").
// From then on `progress` moves the copies. Leaving is the reverse: the copies
// return to the real positions and the overlay unmaps, which shows the windows.
Item {
  id: root

  // ------------------------------------------------------------ tunables

  property real travel: 140         // finger travel (Hyprland swipe units) from closed to open
  property real flick: 0.3          // progress per second at release above which the direction of travel decides
  property real commit: 0.35        // ... and otherwise: how far it must have come to carry on that way
  property real stiffness: 320      // spring that finishes the movement once the fingers lift
  property real damping: 35.8       // critical for that stiffness: no bounce
  property real gap: 40             // px between two windows in the overview
  property real previewHeight: 96   // a desktop in the bar: the same size on every screen
  property bool liveThumbnails: true

  // ------------------------------------------------------------ state

  // closed -> tracking (fingers down) / settling (spring) -> open -> ... -> restoring -> closed
  // open -> switching (a desktop was picked) -> settling -> restoring -> closed
  // open -> paging (fingers sideways) -> pageSettling -> open
  property string phase: "closed"
  property real raw: 0               // 0 closed .. 1 open, from the fingers or the spring
  property bool active: false        // the copies exist and capture
  property bool presentable: false   // ... and have a frame: the overlay is mapped, which hides the real windows
  property bool hiddenAck: false     // Hyprland has hidden them, on every monitor
  property var acks: ({})
  // Nothing moves before the copies have taken over (~80 ms into a swipe).
  // What the fingers travelled until then is `debt`: the copies start from
  // rest at that moment and close the gap to the fingers smoothly (an
  // exponential approach, `catchUp` seconds), without a jump at either speed.
  property real debt: 0
  property real catchUp: 0.07
  readonly property real progress: hiddenAck ? Math.max(0, raw) : 0
  readonly property bool interactive: phase === "open"
  property bool grabKeys: false

  property var pending: null         // snapshot being received
  property var deco: ({ activeBorder: "#ff7daea3", inactiveBorder: "#aa595959", border: 2, bar: 30, rounding: 0,
                        titlebar: "#3c3836", title: "#d4be98", shadowRange: 16, shadowPower: 3, shadow: "#35000000" })
  property var monitors: ({})        // name -> { x, y, w, h, top, bottom, left, right, activeWs, offset, focused }
  property var byMonitor: ({})       // name -> [window] of every desktop, stacking order
  property var spaces: ({})          // name -> [workspace id]
  property var wsOf: ({})            // address -> workspace id (changes when a window is dragged to a desktop)
  property var gone: ({})            // address -> true: closed while the overview is up
  property var topped: ({})          // address -> n: brought to the front of another desktop, in that order
  property int toppedCount: 0
  property var geo: ({})             // address -> { x, y, w, h, bar }: geometry that changed since the snapshot
  property var geoPending: null
  property var slots: ({})           // address -> { x, y, s } in the overview
  // The pictures for the bar's previews and for the neighbouring desktops are
  // not needed in the first frame: one more window starts being captured every
  // few milliseconds once the overview moves, instead of all of them at once.
  property int quota: 0
  property var needed: ({})          // addresses whose first frame is still awaited
  property string activeAddress: ""
  property string raised: ""
  property string hoverAddress: ""
  property bool dragging: false
  property string lifted: ""         // the window that is in the hand or flying to where it was dropped
  property int dropSpace: -1         // desktop under a dragged window
  property string fadeMonitor: ""    // the monitor whose desktop is being switched
  property real fade: 1
  // Four fingers sideways while the overview is up: the monitor's desktops
  // slide like pages, each one spread out. `pagePos` is the position among
  // them (an index into `spaces`), fractional under the fingers.
  // A desktop being dragged to a new place in the bar: from which position to which.
  property string reorderMonitor: ""
  property int reorderFrom: -1
  property int reorderTo: -1
  property string pageMonitor: ""
  property real pagePos: 0
  property real pageRaw: 0
  property real pageTravel: 500      // finger travel per desktop: Hyprland's workspace_swipe_distance
  property bool ignorePage: false
  property var afterClose: null
  property bool ignoreGesture: false
  property int gestureFrom: 0        // where the swipe started: 0 closed, 1 open
  property string gestureHover: ""   // the window under the pointer when a closing swipe began
  property real gestureRaw: 0
  property var samples: []
  property var timing: ({})

  readonly property string home: Quickshell.env("HOME")
  readonly property string wallpaper: "file://" + home + "/.local/state/omarchy/current/background"

  NumberAnimation { id: fadeIn; target: root; property: "fade"; from: 0; to: 1; duration: 160; easing.type: Easing.OutCubic }

  // ------------------------------------------------------------ Hyprland

  function hypr(lua) {
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  // The Hyprland half lives in Hyprland's Lua, which a config reload starts
  // afresh: load it now and after every reload. Nothing in ~/.config/hypr
  // has to know about it.
  readonly property string luaFile: String(Qt.resolvedUrl("hypr/mac-mission-control.lua")).replace(/^file:\/\//, "")
  // (A hot reload of the plugin makes the new instance before it destroys the
  // old one, which must then not unload what the new one has just loaded.)
  readonly property string instance: Date.now() + "-" + Math.round(Math.random() * 1e6)
  function loadLua() {
    root.teardown()
    root.appNames = ({})
    root.hypr("dofile([[" + root.luaFile + "]]) mac_mission_control.owner = '" + root.instance + "'")
    animations.running = true
  }
  // Hyprland's own workspace animation, when it is on, as the Lua table that
  // sets it: a switch made from the overview turns it off and puts this back.
  property string slide: ""
  function switchTo(id) {
    root.hypr("mac_mission_control.workspace(" + id + (root.slide ? ", " + root.slide : "") + ")")
  }
  Process {
    id: animations
    command: ["hyprctl", "-j", "animations"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var leaf = null
        try {
          var leaves = JSON.parse(text)[0]
          for (var i = 0; i < leaves.length; i++) if (leaves[i].name === "workspaces") leaf = leaves[i]
        } catch (e) {}
        var plain = /^[\w .%:-]*$/
        if (!leaf || !leaf.enabled || !leaf.overridden || !plain.test(leaf.bezier) || !plain.test(leaf.style)) {
          root.slide = ""
          return
        }
        var spring = String(leaf.bezier).indexOf("spring:") === 0
        root.slide = '{ leaf = "workspaces", enabled = true, speed = ' + Number(leaf.speed)
                   + (spring ? ', spring = "' + leaf.bezier.substring(7) + '"' : leaf.bezier ? ', bezier = "' + leaf.bezier + '"' : "")
                   + (leaf.style ? ', style = "' + leaf.style + '"' : "") + " }"
      }
    }
  }
  Component.onCompleted: root.loadLua()
  Component.onDestruction: root.hypr("if mac_mission_control and mac_mission_control.owner == '" + root.instance
                                     + "' then mac_mission_control.unload() end")
  Timer { id: reload; interval: 150; onTriggered: root.loadLua() }

  function bare(address) {
    var a = String(address || "").toLowerCase()
    return a.indexOf("0x") === 0 ? a.substring(2) : a
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") reload.restart()
      if (event.name !== "custom") return
      var data = event.data
      if (data.indexOf("mmc>>") === 0) root.handle(data.substring(5))
    }
  }

  function handle(message) {
    var f = message.split(",")
    switch (f[0]) {
    case "snap":
      root.pending = { mons: {}, spaces: {}, wins: [], deco: null }
      break
    case "o":   // settings from mac_mission_control_config, where given
      if (Number(f[1]) > 0) root.travel = Number(f[1])
      if (Number(f[2]) > 0) root.gap = Number(f[2])
      if (Number(f[3]) > 0) root.previewHeight = Number(f[3])
      break
    case "c":
      if (root.pending) root.pending.deco = {
        activeBorder: "#" + f[1], inactiveBorder: "#" + f[2],
        border: Number(f[3]), bar: Number(f[4]), rounding: Number(f[5]),
        titlebar: "#" + f[6], title: "#" + f[7],
        shadowRange: Number(f[8]) || 0, shadowPower: Number(f[9]) || 3, shadow: "#" + (f[10] || "35000000")
      }
      break
    case "m":
      if (root.pending) root.pending.mons[f[1]] = {
        name: f[1], x: Number(f[2]), y: Number(f[3]), w: Number(f[4]), h: Number(f[5]),
        activeWs: Number(f[6]), focused: f[7] === "1",
        notch: Number(f[8]) || 0,   // a camera notch's height
        renumber: f[9] === "1"      // demo mode: desktops are numbered by their place in the bar
      }
      break
    case "k":
      if (root.pending) {
        if (!root.pending.spaces[f[2]]) root.pending.spaces[f[2]] = []
        root.pending.spaces[f[2]].push(Number(f[1]))
      }
      break
    case "w":
      if (root.pending) root.pending.wins.push({
        address: f[1], x: Number(f[2]), y: Number(f[3]), w: Number(f[4]), h: Number(f[5]),
        ws: Number(f[6]), mon: f[7], floating: f[8] === "1", fullscreen: Number(f[9]),
        pinned: f[10] === "1", bar: f[11] === "1", active: f[12] === "1"
      })
      break
    case "g":
      if (f[1] === "s") root.gestureStart(f[2] === "1")
      else if (f[1] === "u") root.gestureUpdate(Number(f[2]), Number(f[3]))
      else if (f[1] === "e") root.gestureEnd()
      break
    case "s":
      if (f[1] === "s") root.pageStart(f[2], Number(f[3]))
      else if (f[1] === "u") root.pageUpdate(Number(f[2]), Number(f[3]))
      else if (f[1] === "e") root.pageEnd()
      break
    case "ws": root.enterSpace(f[1], Number(f[2])); break
    case "key":   // SUPER or CTRL + W / Q: the window under the pointer, as those keys do to the focused one
      if (!root.interactive || !root.hoverAddress || root.gone[root.hoverAddress]) break
      root.hypr("mac_mission_control." + (f[1] === "q" ? "quit" : "close") + "('" + root.hoverAddress + "')")
      break
    case "gone":
      if (root.phase === "closed" || root.gone[f[1]] || root.wsOf[f[1]] === undefined) break
      var gone = Object.assign({}, root.gone)
      gone[f[1]] = true
      root.gone = gone
      if (root.hoverAddress === f[1]) root.hoverAddress = ""
      root.layout()
      root.refreshGeometry()
      break
    case "x":   // fresh geometry, asked for with refreshGeometry()
      if (f[1] !== "end") {
        if (!root.geoPending) root.geoPending = {}
        root.geoPending[f[1]] = { x: Number(f[2]), y: Number(f[3]), w: Number(f[4]), h: Number(f[5]), bar: f[7] === "1" }
      } else if (root.geoPending) {
        if (root.phase !== "closed" && root.phase !== "restoring") {
          root.geo = root.geoPending
          root.layout()
        }
        root.geoPending = null
      }
      break
    case "toggle": root.toggle(); break
    case "h":
      root.acks[f[1]] = true
      root.timing["h_" + f[1]] = Date.now() - root.timing.start
      for (var name in root.monitors) if (!root.acks[name]) return
      root.timing.hidden = Date.now() - root.timing.start
      ackTimeout.stop()
      root.debt = root.phase === "tracking" ? Math.max(0, root.gestureRaw) : 0
      root.hiddenAck = true
      break
    case "leave": root.leave(); break
    case "stale":   // the Hyprland half was updated and its hooks are older: a config reload renews them
      Quickshell.execDetached(["hyprctl", "reload"])
      break
    case "reset": root.teardown(); break
    }
  }

  // ------------------------------------------------------------ opening

  function arm() {
    var snap = root.pending
    root.pending = null
    if (!snap) return false
    var any = false
    for (var name in snap.mons) any = true
    if (!any) return false

    var handles = {}
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++) handles[root.bare(list[i].address)] = list[i]

    var byMonitor = {}, wsOf = {}, needed = {}, activeAddress = ""
    for (name in snap.mons) byMonitor[name] = []
    for (i = 0; i < snap.wins.length; i++) {
      var w = snap.wins[i]
      var mon = snap.mons[w.mon]
      if (!mon) continue
      var t = handles[root.bare(w.address)]
      w.toplevel = t && t.wayland ? t.wayland : null
      w.title = t ? (t.title || "") : ""
      w.appId = w.toplevel ? (w.toplevel.appId || "") : ""
      w.barTitle = root.appName(w.appId) || w.title
      byMonitor[w.mon].push(w)
      wsOf[w.address] = w.ws
      if (w.active) activeAddress = w.address
      if (w.toplevel && (w.ws === mon.activeWs || w.pinned)) needed[w.address] = true
    }

    var spaces = {}
    for (name in snap.mons) {
      var ids = (snap.spaces[name] || []).slice()
      if (ids.indexOf(snap.mons[name].activeWs) < 0) ids.push(snap.mons[name].activeWs)
      ids.sort(function(a, b) { return a - b })
      spaces[name] = ids
    }

    if (snap.deco) root.deco = snap.deco
    root.monitors = snap.mons
    root.byMonitor = byMonitor
    root.spaces = spaces
    root.wsOf = wsOf
    root.needed = needed
    root.activeAddress = activeAddress
    root.raised = ""
    root.hoverAddress = ""
    root.afterClose = null
    root.dragging = false
    root.lifted = ""
    root.dropSpace = -1
    root.fadeMonitor = ""
    root.fade = 1
    root.pageMonitor = ""
    root.geo = ({})
    root.geoPending = null
    root.gone = ({})
    root.topped = ({})
    root.layout()

    root.timing = { start: Date.now() }
    root.raw = 0
    root.hiddenAck = false
    root.quota = 0
    root.debt = 0
    root.acks = ({})
    root.presentable = false
    root.grabKeys = false
    root.active = true
    armTimeout.restart()
    root.checkReady()
    return true
  }

  function frameOf(win, mon) {
    var w = root.geo[win.address] || win
    var full = win.fullscreen === 2
    var bar = w.bar && !full ? root.deco.bar : 0
    var b = full ? 0 : root.deco.border
    return { x: w.x - mon.x - b, y: w.y - mon.y - bar - b, w: w.w + 2 * b, h: w.h + bar + 2 * b }
  }

  // The desktops bar: previews, their names, padding. It comes down over the
  // menu bar, which is gone while the overview is up, as on macOS.
  // Under a camera notch the bar still starts at the top of the screen, and
  // the previews start below the notch.
  function barHeight(mon) {
    return (mon.notch || 0) + root.previewHeight + 46
  }

  function areaOf(mon) {
    var side = Math.max(40, Math.round(mon.w * 0.04))
    var top = root.barHeight(mon) + 30
    return { x: side, y: top, w: mon.w - 2 * side, h: mon.h - top - 60 }
  }

  // Every desktop gets its layout, not only the one in view: the others are
  // what slides in on a sideways swipe.
  function layout() {
    var slots = {}
    for (var name in root.monitors) {
      var mon = root.monitors[name]
      var groups = {}
      var list = root.byMonitor[name] || []
      for (var i = 0; i < list.length; i++) {
        var w = list[i]
        if (root.gone[w.address]) continue
        var ws = w.pinned ? mon.activeWs : root.wsOf[w.address]
        if (!groups[ws]) groups[ws] = { shown: [], frames: [] }
        groups[ws].shown.push(w)
        groups[ws].frames.push(root.frameOf(w, mon))
      }
      for (var id in groups) {
        var g = groups[id]
        var placed = Layout.arrange(g.frames, { x: 0, y: 0, w: mon.w, h: mon.h }, root.areaOf(mon), root.gap, 1)
        for (i = 0; i < g.shown.length; i++) slots[g.shown[i].address] = placed[i]
      }
    }
    root.slots = slots
  }

  // A window's copy has its first frame.
  function ready(address) {
    if (!root.needed[address]) return
    delete root.needed[address]
    root.checkReady()
  }

  function checkReady() {
    if (!root.active || root.presentable) return
    for (var address in root.needed) return
    root.go()
  }

  function go() {
    if (!root.active || root.presentable) return
    armTimeout.stop()
    root.timing.ready = Date.now() - root.timing.start
    root.presentable = true
    ackTimeout.restart()
  }

  Timer {
    interval: 12
    repeat: true
    running: root.hiddenAck && root.quota < 64
    onTriggered: root.quota += 1
  }

  // Copies that never deliver a frame must not hold the overview back.
  Timer { id: armTimeout; interval: 150; onTriggered: root.go() }
  // Without Hyprland's answer (module not loaded) carry on rather than hang.
  Timer {
    id: ackTimeout
    interval: 300
    onTriggered: {
      root.debt = root.phase === "tracking" ? Math.max(0, root.gestureRaw) : 0
      root.hiddenAck = true
    }
  }

  // ------------------------------------------------------------ closing

  function settle(target, velocity) {
    root.pageMonitor = ""
    spring.target = target
    spring.velocity = velocity
    root.phase = "settling"
  }

  function settled() {
    if (spring.target >= 1) {
      root.phase = "open"
      root.grabKeys = true
      return
    }
    root.restore()
  }

  // Copies are back where the windows are: give that frame time to be on
  // screen, then unmap, which shows the real ones in the same frame.
  function restore() {
    root.raw = 0
    root.grabKeys = false
    switchDelay.stop()
    if (!root.presentable) {
      root.teardown()
      return
    }
    root.phase = "restoring"
    unmapDelay.restart()
  }

  Timer { id: unmapDelay; interval: 34; onTriggered: if (root.phase === "restoring") root.teardown() }

  function teardown() {
    armTimeout.stop(); ackTimeout.stop(); unmapDelay.stop(); switchDelay.stop()
    var then = root.afterClose
    root.afterClose = null
    root.phase = "closed"
    root.presentable = false
    root.active = false
    root.hiddenAck = false
    root.grabKeys = false
    root.raw = 0
    root.dragging = false
    root.lifted = ""
    root.dropSpace = -1
    root.hoverAddress = ""
    root.fadeMonitor = ""
    root.fade = 1
    root.pageMonitor = ""
    root.reorderMonitor = ""
    root.reorderFrom = -1
    geoSoon.stop(); geoLater.stop()
    root.byMonitor = ({})
    root.geo = ({})
    root.slots = ({})
    root.needed = ({})
    if (then) then()
  }

  function close() {
    if (root.phase === "closed" || root.phase === "restoring") return
    root.grabKeys = false
    root.settle(0, 0)
  }

  // Something changed underneath (a window opened, the workspace switched).
  function leave() {
    if (root.phase === "closed" || root.phase === "restoring") return
    root.afterClose = null
    root.restore()
  }

  function toggle() {
    if (root.phase === "closed") {
      if (root.arm()) root.settle(1, 0)
    } else if (root.phase === "open" || (root.phase === "settling" && spring.target >= 1)) {
      root.close()
    } else if (root.phase === "settling") {
      root.settle(1, spring.velocity)
    }
  }

  // ------------------------------------------------------------ gesture

  function gestureStart(up) {
    root.ignoreGesture = false
    if (root.phase === "closed") {
      if (!up || !root.arm()) {
        root.ignoreGesture = true
        return
      }
    } else if (root.phase !== "open" && root.phase !== "settling" && root.phase !== "tracking") {
      root.ignoreGesture = true
      return
    }
    // Swiping it shut with the pointer on a window: that window comes to the
    // front as they all return, and is the one you land in.
    root.gestureHover = root.phase === "open" && !root.gone[root.hoverAddress] ? root.hoverAddress : ""
    if (root.gestureHover) root.raised = root.gestureHover
    root.grabKeys = false
    root.phase = "tracking"
    root.gestureFrom = root.raw > 0.5 ? 1 : 0
    root.debt = 0
    root.gestureRaw = root.raw
    root.samples = []
  }

  // Past fully open the copies give a little and no more.
  function banded(value) {
    if (value <= 1) return Math.max(0, value)
    return 1 + 0.05 * (1 - Math.exp(-(value - 1) * 4))
  }

  function gestureUpdate(dy, time) {
    if (root.ignoreGesture || root.phase !== "tracking") return
    var step = -dy / root.travel
    root.gestureRaw = Math.max(0, Math.min(1.25, root.gestureRaw + step))
    if (root.hiddenAck) root.raw = root.banded(Math.max(0, root.gestureRaw - root.debt))
    var s = root.samples
    s.push({ t: time, v: root.gestureRaw })
    while (s.length > 2 && time - s[0].t > 90) s.shift()
  }

  // Units per second over the last moments of a swipe.
  function sampledVelocity() {
    var s = root.samples
    if (s.length < 2 || s[s.length - 1].t <= s[0].t) return 0
    return (s[s.length - 1].v - s[0].v) / ((s[s.length - 1].t - s[0].t) / 1000)
  }

  function gestureEnd() {
    if (root.ignoreGesture || root.phase !== "tracking") return
    var velocity = Math.max(-6, Math.min(6, root.sampledVelocity()))
    // Still moving when the fingers lift: that way. Resting: whether it came far
    // enough from where it started (a third of the way, not half).
    var target
    if (Math.abs(velocity) > root.flick) target = velocity > 0 ? 1 : 0
    else if (root.gestureFrom === 0) target = root.raw > root.commit ? 1 : 0
    else target = root.raw < 1 - root.commit ? 0 : 1
    if (root.gestureHover) {
      if (target === 0) root.pick(root.gestureHover)
      else root.raised = ""
      root.gestureHover = ""
    }
    root.settle(target, velocity)
  }

  // Under the fingers: the gap left by the start is closed frame by frame.
  FrameAnimation {
    running: root.phase === "tracking" && root.hiddenAck && root.debt > 0
    onTriggered: {
      root.debt *= Math.exp(-Math.min(frameTime, 0.05) / root.catchUp)
      if (root.debt < 0.002) root.debt = 0
      root.raw = root.banded(Math.max(0, root.gestureRaw - root.debt))
    }
  }

  // How evenly the frames come while it moves, for debugState: the longest
  // frame and how many took more than 20 ms since the opening began.
  FrameAnimation {
    running: root.phase === "tracking" || root.phase === "settling"
    onTriggered: {
      if (!root.hiddenAck) return
      var ms = frameTime * 1000
      root.timing.frames = (root.timing.frames || 0) + 1
      if (ms > (root.timing.longest || 0)) root.timing.longest = Math.round(ms)
      if (ms > 20) root.timing.slow = (root.timing.slow || 0) + 1
    }
  }

  FrameAnimation {
    id: spring
    property real target: 0
    property real velocity: 0
    // Opening by key waits for the copies to have taken over, so that it
    // starts from rest instead of catching up with a spring already under way.
    running: root.phase === "settling" && (root.hiddenAck || target < 1)
    onTriggered: {
      var left = Math.min(frameTime, 0.05)
      while (left > 0) {
        var h = Math.min(left, 0.004)
        left -= h
        velocity += (-root.stiffness * (root.raw - target) - root.damping * velocity) * h
        root.raw += velocity * h
      }
      if (Math.abs(root.raw - target) < 0.002 && Math.abs(velocity) < 0.05) {
        root.raw = target
        root.settled()
      }
    }
  }

  // ------------------------------------------------------------ desktops, sideways

  function spaceIndex(monitorName, id) {
    return (root.spaces[monitorName] || []).indexOf(id)
  }

  function setActive(monitorName, id) {
    var mons = {}
    for (var name in root.monitors) mons[name] = Object.assign({}, root.monitors[name], { focused: name === monitorName })
    mons[monitorName].activeWs = id
    root.monitors = mons
  }

  function pageStart(monitorName, distance) {
    root.ignorePage = true
    var mon = root.monitors[monitorName]
    if (!mon) return
    if (root.phase === "open") root.pagePos = Math.max(0, root.spaceIndex(monitorName, mon.activeWs))
    else if (root.phase !== "pageSettling" || root.pageMonitor !== monitorName) return   // else: caught mid-slide
    root.ignorePage = false
    root.pageMonitor = monitorName
    root.pageRaw = root.pagePos
    root.pageTravel = distance > 0 ? distance : 500
    root.samples = []
    root.hoverAddress = ""
    root.phase = "paging"
  }

  function pageUpdate(dx, time) {
    if (root.ignorePage || root.phase !== "paging") return
    var last = (root.spaces[root.pageMonitor] || []).length - 1
    root.pageRaw = Math.max(-1, Math.min(last + 1, root.pageRaw - dx / root.pageTravel))
    // Past the first or the last desktop it gives a little and no more.
    var v = root.pageRaw
    if (v < 0) v = -0.18 * (1 - Math.exp(v * 3))
    else if (v > last) v = last + 0.18 * (1 - Math.exp(-(v - last) * 3))
    root.pagePos = v
    var s = root.samples
    s.push({ t: time, v: root.pageRaw })
    while (s.length > 2 && time - s[0].t > 90) s.shift()
  }

  // A flick goes on to the next desktop in its direction; otherwise a desktop
  // that is more than a nudge (15 %) in view is the one to land on.
  function pageEnd() {
    if (root.ignorePage || root.phase !== "paging") return
    var name = root.pageMonitor
    var ids = root.spaces[name] || []
    var from = Math.max(0, ids.indexOf(root.monitors[name].activeWs))
    var velocity = root.sampledVelocity()
    var target
    if (Math.abs(velocity) > 1.2) target = velocity > 0 ? Math.ceil(root.pageRaw) : Math.floor(root.pageRaw)
    else target = root.pageRaw > from ? Math.floor(root.pageRaw + 0.85) : Math.ceil(root.pageRaw - 0.85)
    target = Math.max(0, Math.min(ids.length - 1, target))
    if (target !== from) {
      // Hyprland switches under cover; the overview stays up on that desktop.
      root.switchTo(ids[target])
      root.activeAddress = ""
      root.raised = ""
      root.setActive(name, ids[target])
    }
    pageSpring.target = target
    pageSpring.velocity = Math.max(-8, Math.min(8, velocity))
    root.phase = "pageSettling"
  }

  // Hyprland switched a monitor's workspace by other means (a key, the bar).
  function enterSpace(monitorName, id) {
    var mon = root.monitors[monitorName]
    if (!mon || mon.activeWs === id || root.phase === "closed" || root.phase === "restoring") return
    var slide = root.phase === "open"
    root.addSpace(monitorName, id)
    var from = Math.max(0, root.spaceIndex(monitorName, mon.activeWs))
    root.activeAddress = ""
    root.raised = ""
    root.setActive(monitorName, id)
    root.layout()
    if (!slide) return
    root.pageMonitor = monitorName
    root.pagePos = from
    pageSpring.target = Math.max(0, root.spaceIndex(monitorName, id))
    pageSpring.velocity = 0
    root.phase = "pageSettling"
  }

  // The same spring as the workspace slide (looknfeel.lua, macSpace).
  FrameAnimation {
    id: pageSpring
    property real target: 0
    property real velocity: 0
    running: root.phase === "pageSettling"
    onTriggered: {
      var left = Math.min(frameTime, 0.05)
      while (left > 0) {
        var h = Math.min(left, 0.004)
        left -= h
        velocity += (-300 * (root.pagePos - target) - 35 * velocity) * h
        root.pagePos += velocity * h
      }
      if (Math.abs(root.pagePos - target) < 0.001 && Math.abs(velocity) < 0.02) {
        root.pagePos = target
        root.pageMonitor = ""
        root.phase = "open"
        root.grabKeys = true
      }
    }
  }

  // ------------------------------------------------------------ actions

  // The window to come out of the overview in: in front here at once, and
  // focused and raised in Hyprland.
  function pick(address) {
    root.raised = address
    root.activeAddress = address
    var lua = "mac_mission_control.activate('" + address + "')"
    // Now, under cover, so the window is in front when the copies land on it
    // (a moment later: Hyprland refuses focus while the overlay holds the
    // keyboard); and once more after, for workspaces where focus follows the
    // pointer and the pointer is over another window.
    activateDelay.lua = lua
    activateDelay.restart()
    root.afterClose = function() { root.hypr(lua) }
  }

  function activate(address) {
    if (!root.interactive) return
    root.grabKeys = false
    root.pick(address)
    root.settle(0, 0)
  }

  Timer {
    id: activateDelay
    property string lua: ""
    interval: 30
    onTriggered: root.hypr(lua)
  }

  // A desktop picked in the bar: Hyprland switches to it under cover, its
  // windows take the overview's places, and the overview zooms into it.
  function goToSpace(monitorName, id) {
    if (!root.interactive) return
    var mon = root.monitors[monitorName]
    if (!mon) return
    if (mon.activeWs === id) {
      root.close()
      return
    }
    root.grabKeys = false
    root.phase = "switching"
    root.switchTo(id)

    root.addSpace(monitorName, id)
    root.fadeMonitor = monitorName
    root.fade = 0
    root.activeAddress = ""
    root.raised = ""
    root.pageMonitor = ""
    root.setActive(monitorName, id)
    root.layout()
    // Once more when the overview is gone: the keyboard goes to that desktop.
    root.afterClose = function() { root.switchTo(id) }
    switchDelay.restart()
  }

  // Long enough for Hyprland to have switched and the new copies to have a frame.
  Timer {
    id: switchDelay
    interval: 50
    onTriggered: {
      if (root.phase !== "switching") return
      fadeIn.restart()
      root.settle(0, 0)
    }
  }

  // After something moved windows about in Hyprland: once at once, and once
  // more when Omarchy's layout mode has caught up with a window that changed desktop.
  function refreshGeometry() {
    geoSoon.restart()
    geoLater.restart()
  }
  Timer { id: geoSoon; interval: 70; onTriggered: root.hypr("mac_mission_control.geometry()") }
  Timer { id: geoLater; interval: 450; onTriggered: root.hypr("mac_mission_control.geometry()") }

  function addSpace(monitorName, id) {
    var ids = (root.spaces[monitorName] || []).slice()
    if (ids.indexOf(id) >= 0) return
    ids.push(id)
    ids.sort(function(a, b) { return a - b })
    var spaces = Object.assign({}, root.spaces)
    spaces[monitorName] = ids
    root.spaces = spaces
  }

  function moveWindow(address, monitorName, id) {
    if (id <= 0 || root.wsOf[address] === id) return
    root.hypr("mac_mission_control.move('" + address + "', " + id + ")")
    var wsOf = Object.assign({}, root.wsOf)
    wsOf[address] = id
    root.wsOf = wsOf
    // It goes in front of what is there (Hyprland does the same to the window).
    var topped = Object.assign({}, root.topped)
    topped[address] = ++root.toppedCount
    root.topped = topped
    root.addSpace(monitorName, id)
    root.layout()
    root.refreshGeometry()
  }

  // The desktop at position `from` in the bar goes to position `to`. The
  // numbers stay where they are; what is on them moves along (Hyprland
  // renumbers the workspaces), as when desktops are reordered on macOS.
  function reorderSpace(monitorName, from, to) {
    var ids = root.spaces[monitorName] || []
    if (from === to || from < 0 || to < 0 || from >= ids.length || to >= ids.length) return
    var order = ids.slice()
    order.splice(to, 0, order.splice(from, 1)[0])
    var map = {}, pairs = []
    for (var i = 0; i < ids.length; i++) {
      map[order[i]] = ids[i]
      if (order[i] !== ids[i]) pairs.push(order[i] + ":" + ids[i])
    }
    root.hypr("mac_mission_control.reorder('" + pairs.join(",") + "')")

    var wsOf = {}
    for (var address in root.wsOf) {
      var ws = root.wsOf[address]
      wsOf[address] = map[ws] !== undefined ? map[ws] : ws
    }
    var mons = Object.assign({}, root.monitors)
    var mon = mons[monitorName]
    if (map[mon.activeWs] !== undefined) mons[monitorName] = Object.assign({}, mon, { activeWs: map[mon.activeWs] })
    root.wsOf = wsOf
    root.monitors = mons
    root.layout()
    root.refreshGeometry()
  }

  // The first free desktop of a monitor.
  function newSpace(monitorName) {
    var mon = root.monitors[monitorName]
    if (!mon) return -1
    var ids = root.spaces[monitorName] || []
    var base = root.blockOf(mon.activeWs)
    for (var n = 1; n <= 10; n++) if (ids.indexOf(base + n) < 0) return base + n
    return -1
  }

  // A monitor's ten workspaces start after a multiple of ten (1-10, 11-20, ...),
  // which is how Omarchy numbers them per monitor; what you see is 1..9 and 0.
  function blockOf(id) {
    return Math.floor((id - 1) / 10) * 10
  }

  // What Omarchy's titlebars show (omarchy-hyprland-titlebars, appName.cpp):
  // the name of the desktop entry whose StartupWMClass is the window's class,
  // or else whose file name is; a window no launcher claims keeps its title.
  property var appNames: ({})
  function appName(appId) {
    if (!appId) return ""
    if (root.appNames[appId] !== undefined) return root.appNames[appId]
    var entries = DesktopEntries.applications.values
    var name = ""
    for (var i = 0; i < entries.length && !name; i++)
      if (entries[i].startupClass === appId) name = entries[i].name
    var wanted = appId.toLowerCase()
    for (i = 0; i < entries.length && !name; i++)
      if (String(entries[i].id).toLowerCase() === wanted) name = entries[i].name
    root.appNames[appId] = name
    return name
  }

  function iconFor(appId) {
    if (!appId) return ""
    var entry = DesktopEntries.heuristicLookup(appId)
    return entry && entry.icon ? Quickshell.iconPath(entry.icon, true) : ""
  }

  // `omarchy-shell shell call mac.missioncontrol debugState ""`
  function debugState() {
    var windows = 0
    for (var name in root.byMonitor) windows += root.byMonitor[name].length
    return JSON.stringify({ phase: root.phase, raw: Math.round(root.raw * 1000) / 1000, active: root.active,
                            presentable: root.presentable, hiddenAck: root.hiddenAck, windows: windows,
                            waiting: Object.keys(root.needed).length, timing: root.timing, slide: root.slide,
                            pageMonitor: root.pageMonitor, pagePos: Math.round(root.pagePos * 1000) / 1000,
                            spaces: root.spaces, slots: root.slots })
  }

  signal debugDrop(string address, int id)

  // For tests, what the pointer would do:
  //   omarchy-shell shell call mac.missioncontrol debugAction "space Virtual-1 2"
  //   ... "activate 0xaaaa..." | "move 0xaaaa... Virtual-1 3"
  function debugAction(spec) {
    var a = String(spec).split(" ")
    if (a[0] === "space") root.goToSpace(a[1], Number(a[2]))
    else if (a[0] === "activate") root.activate(a[1])
    else if (a[0] === "move") root.moveWindow(a[1], a[2], Number(a[3]))
    else if (a[0] === "hover") root.hoverAddress = a[1]   // the pointer on a window
    else if (a[0] === "drop") root.debugDrop(a[1], Number(a[2]))   // a window let go over a desktop (0: over nothing)
    else if (a[0] === "reorder") root.reorderSpace(a[1], Number(a[2]), Number(a[3]))   // positions in the bar, from 0
    else if (a[0] === "page") {   // "page Virtual-1 1": a swipe to the next desktop (-1: previous)
      var now = Date.now()
      root.pageStart(a[1], 500)
      for (var i = 1; i <= 6; i++) root.pageUpdate(-50 * Number(a[2]), now + i * 30)
      root.pageUpdate(0, now + 400)
      root.pageEnd()
    }
    return root.phase
  }

  // ------------------------------------------------------------ view

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      readonly property var mon: root.monitors[modelData.name] || null
      readonly property var area: mon ? root.areaOf(mon) : ({ x: 0, y: 0, w: 1, h: 1 })
      readonly property var list: mon ? (root.byMonitor[mon.name] || []) : []
      readonly property real shown: Math.min(1, root.progress)
      // Where this monitor is among its desktops: on the one in view, or between two while they slide.
      readonly property int home: mon ? Math.max(0, root.spaceIndex(mon.name, mon.activeWs)) : 0
      readonly property real pagePos: mon && root.pageMonitor === mon.name ? root.pagePos : home

      screen: modelData
      // Hyprland hides this monitor's real windows while this is mapped (mac-mission-control.lua).
      visible: root.active && root.presentable && mon !== null
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "mac-mission-control"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.grabKeys && mon && mon.focused ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      Item {
        id: stage
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.close()

        // The wallpaper dims below the desktops bar.
        Rectangle {
          y: bar.y + bar.height
          width: parent.width
          height: parent.height - y
          color: "black"
          opacity: 0.25 * panel.shown
        }

        // A click beside the windows leaves.
        MouseArea {
          anchors.fill: parent
          enabled: root.active
          onClicked: if (root.interactive) root.close()
        }

        // ---------------------------------------------------- windows

        Item {
          id: windows
          anchors.fill: parent
          // A window in the hand, or on its way into a desktop, passes over the bar.
          z: root.lifted !== "" ? 2 : 0
          opacity: panel.mon && panel.mon.name === root.fadeMonitor ? root.fade : 1

          Repeater {
            model: panel.list

            delegate: Item {
              id: thumb
              required property var modelData
              required property int index
              readonly property string address: modelData.address
              // Where the window is and how large: as snapshotted, or as Hyprland
              // has it since (a window moved to another desktop re-tiles the rest).
              readonly property var g: root.geo[modelData.address] || modelData
              readonly property bool here: (root.wsOf[address] === panel.mon.activeWs || modelData.pinned)
              // Its desktop's place among the monitor's, and how far that is from the view.
              readonly property int pageIndex: root.spaceIndex(panel.mon.name, root.wsOf[address])
              readonly property real pageOffset: modelData.pinned || pageIndex < 0 ? 0 : (pageIndex - panel.pagePos) * panel.mon.w
              readonly property bool onStage: modelData.pinned
                                              || (pageIndex >= 0 && Math.abs(pageIndex - panel.pagePos) < 0.999 && (here || root.hiddenAck))
              // The neighbouring desktops' windows are captured ahead, for the swipe.
              readonly property bool wanted: here || (root.hiddenAck && pageIndex >= 0 && Math.abs(pageIndex - panel.home) <= 1)
              readonly property bool full: modelData.fullscreen === 2
              readonly property real barHeight: g.bar && !full ? root.deco.bar : 0
              readonly property real border: full ? 0 : root.deco.border
              readonly property real fx: g.x - panel.mon.x - border
              readonly property real fy: g.y - panel.mon.y - barHeight - border
              readonly property var slot: root.slots[address] || null
              property real tx: slot ? slot.x : fx
              property real ty: slot ? slot.y : fy
              property real ts: slot ? slot.s : 1
              readonly property bool isActive: root.activeAddress === address
              readonly property bool hovered: root.hoverAddress === address && root.interactive && !root.dragging
              // Nothing of a copy is drawn before it has the window's picture: a
              // frame or titlebar on its own would flash over the real window.
              readonly property bool solid: view.hasContent || root.hiddenAck

              // In the hand (`dragged`) and on the flight after it is let go the
              // copy is `free`: the point it was grabbed at (gx, gy) stays under
              // the pointer (px, py) while `factor` shrinks it, the more the
              // nearer it comes to the bar; `fly` then takes it from there to
              // where it lands, a desktop's preview or its old place.
              property bool dragged: false
              property bool free: false
              property real px: 0
              property real py: 0
              property real gx: 0
              property real gy: 0
              property real factor: 1
              property real fly: 0
              property real flyX: 0
              property real flyY: 0
              property real flyScale: 1
              readonly property real heldScale: ts * factor
              readonly property real heldX: px - gx * heldScale
              readonly property real heldY: py - gy * heldScale
              Behavior on factor { enabled: thumb.dragged; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              NumberAnimation {
                id: flight
                target: thumb
                property: "fly"
                from: 0
                to: 1
                duration: Style.duration(300)
                easing.type: Easing.OutCubic
                onFinished: thumb.land()
              }

              // As large as a window in a preview (a little more, to stay in view) over the bar.
              function factorAt(y) {
                var mini = bar.previewW / panel.mon.w * 1.5
                var near = Math.max(0, Math.min(1, (bar.height + 180 - y) / 180))
                return (ts * 0.82 + (mini - ts * 0.82) * near) / ts
              }

              function release(id) {
                thumb.dragged = false
                root.dragging = false
                root.dropSpace = -1
                var spot = id > 0 && id !== root.wsOf[address]
                           ? bar.landing(id, { x: fx, y: fy, w: width, h: height }) : null
                if (spot) {
                  thumb.flyX = spot.x; thumb.flyY = spot.y; thumb.flyScale = spot.s
                  // Now, so the others close ranks and the preview has its picture while this one is on its way.
                  root.moveWindow(address, panel.mon.name, id)
                } else {
                  thumb.flyX = thumb.tx; thumb.flyY = thumb.ty; thumb.flyScale = thumb.ts
                }
                flight.restart()
              }

              // For tests: taken up by its middle, carried half way to the bar, let go.
              Connections {
                target: root
                function onDebugDrop(address, id) {
                  if (address !== thumb.address || !root.interactive) return
                  thumb.gx = thumb.width / 2
                  thumb.gy = thumb.height / 2
                  thumb.px = thumb.x + thumb.gx * thumb.ts
                  thumb.py = (thumb.y + thumb.gy * thumb.ts + bar.height) / 2
                  thumb.fly = 0
                  thumb.free = true
                  thumb.dragged = true
                  root.dragging = true
                  root.lifted = thumb.address
                  thumb.factor = thumb.factorAt(thumb.py)
                  thumb.release(id)
                }
              }

              function land() {
                thumb.free = false
                thumb.fly = 0
                thumb.factor = 1
                if (root.lifted === address) root.lifted = ""
              }

              readonly property bool gone: root.gone[address] === true
              visible: (onStage || free) && opacity > 0
              opacity: gone ? 0 : 1
              Behavior on opacity { NumberAnimation { duration: Style.duration(140) } }
              x: free ? heldX + (flyX - heldX) * fly : fx + (tx - fx) * root.progress + pageOffset
              y: free ? heldY + (flyY - heldY) * fly : fy + (ty - fy) * root.progress
              width: g.w + 2 * border
              height: g.h + barHeight + 2 * border
              scale: free ? heldScale + (flyScale - heldScale) * fly : 1 + (ts - 1) * root.progress
              transformOrigin: Item.TopLeft
              z: free ? 3000 : root.raised === address ? 2000 : root.topped[address] ? 1000 + root.topped[address] : index

              // A window left behind by a dragged-away neighbour glides to its new place.
              Behavior on tx { enabled: root.interactive; NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }
              Behavior on ty { enabled: root.interactive; NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }
              Behavior on ts { enabled: root.interactive; NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }

              // Floating workspaces give their windows a shadow: Hyprland's own, to the pixel.
              ShaderEffect {
                readonly property real reach: root.deco.shadowRange
                readonly property color c: root.deco.shadow
                // The real window still casts its own until Hyprland hides it.
                visible: thumb.g.bar && !thumb.full && reach > 0 && root.hiddenAck
                x: -reach
                y: -reach
                width: parent.width + 2 * reach
                height: parent.height + 2 * reach
                property real range: reach
                property real power: root.deco.shadowPower
                property vector2d size: Qt.vector2d(width, height)
                property vector4d tint: Qt.vector4d(c.r, c.g, c.b, c.a)
                fragmentShader: Qt.resolvedUrl("shadow.frag.qsb")
              }

              // The border: Hyprland draws it around titlebar and window together.
              Rectangle {
                anchors.fill: parent
                visible: thumb.border > 0 && thumb.solid
                color: "transparent"
                border.width: thumb.border
                border.color: thumb.isActive ? root.deco.activeBorder : root.deco.inactiveBorder
              }

              // Until the copy has a frame.
              Rectangle {
                x: thumb.border
                y: thumb.border + thumb.barHeight
                width: thumb.g.w
                height: thumb.g.h
                color: Commons.Color.background
                visible: !view.hasContent && root.hiddenAck
              }

              // Titlebar, as omarchy-hyprland-titlebars draws it.
              Rectangle {
                visible: thumb.barHeight > 0 && thumb.solid
                x: thumb.border
                y: thumb.border
                width: thumb.g.w
                height: thumb.barHeight
                color: root.deco.titlebar

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  x: 10
                  width: parent.width - 20 - 3 * 28
                  textFormat: Text.PlainText
                  text: thumb.modelData.barTitle
                  elide: Text.ElideRight
                  color: root.deco.title
                  font.family: "monospace"
                  font.pointSize: 8.8    // bar_text_size 12 as hyprbars renders it: 11.7 px
                }
                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: 10
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 8
                  Repeater {
                    model: ["−", "□", "×"]
                    Text {
                      required property string modelData
                      width: 20
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: modelData
                      color: root.deco.title
                      font.family: "monospace"
                      font.pixelSize: 13
                    }
                  }
                }
              }

              ScreencopyView {
                id: view
                x: thumb.border
                y: thumb.border + thumb.barHeight
                width: thumb.g.w
                height: thumb.g.h
                captureSource: thumb.here || (thumb.wanted && root.quota > thumb.index) ? thumb.modelData.toplevel : null
                live: root.liveThumbnails && thumb.onStage
                onHasContentChanged: if (hasContent) root.ready(thumb.address)
                Component.onCompleted: if (hasContent) root.ready(thumb.address)
              }

              // Pointer over a window: a ring in the accent color.
              Rectangle {
                readonly property real t: 4 / Math.max(0.05, thumb.scale)
                anchors.fill: parent
                anchors.margins: -t
                visible: thumb.hovered
                color: "transparent"
                border.color: Commons.Color.accent
                border.width: t
                radius: root.deco.rounding / Math.max(0.05, thumb.scale)   // as the windows: square unless Hyprland rounds them
              }

              MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.interactive
                property real startX: 0
                property real startY: 0
                property bool moved: false

                onContainsMouseChanged: {
                  if (containsMouse) root.hoverAddress = thumb.address
                  else if (root.hoverAddress === thumb.address) root.hoverAddress = ""
                }
                onPressed: (mouse) => {
                  var p = mapToItem(stage, mouse.x, mouse.y)
                  startX = p.x
                  startY = p.y
                  moved = false
                }
                onPositionChanged: (mouse) => {
                  if (!pressed || (thumb.free && !thumb.dragged)) return
                  var p = mapToItem(stage, mouse.x, mouse.y)
                  if (!thumb.dragged) {
                    if (Math.abs(p.x - startX) + Math.abs(p.y - startY) < 14) return
                    // Taken up exactly where it is.
                    thumb.gx = mouse.x
                    thumb.gy = mouse.y
                    thumb.px = p.x
                    thumb.py = p.y
                    thumb.factor = 1
                    thumb.fly = 0
                    thumb.free = true
                    thumb.dragged = true
                    root.dragging = true
                    root.lifted = thumb.address
                    moved = true
                  }
                  thumb.px = p.x
                  thumb.py = p.y
                  thumb.factor = thumb.factorAt(p.y)
                  root.dropSpace = bar.spaceAt(p.x, p.y)
                }
                onReleased: (mouse) => {
                  if (!thumb.dragged) return
                  var p = mapToItem(stage, mouse.x, mouse.y)
                  thumb.release(bar.spaceAt(p.x, p.y))
                }
                onCanceled: if (thumb.dragged) thumb.release(-1)
                onClicked: if (!moved) root.activate(thumb.address)
              }
            }
          }

          // Names sit above every window, at screen size whatever the scale.
          Repeater {
            model: panel.list

            delegate: Item {
              id: label
              required property var modelData
              readonly property var g: root.geo[modelData.address] || modelData
              readonly property var slot: root.slots[modelData.address] || null
              readonly property bool hovered: slot !== null && root.interactive && !root.dragging
                                              && root.hoverAddress === modelData.address
              readonly property real frameW: (g.w + 2 * root.deco.border) * (slot ? slot.s : 1)
              readonly property real frameH: (g.h + (g.bar ? root.deco.bar : 0) + 2 * root.deco.border) * (slot ? slot.s : 1)
              visible: opacity > 0
              opacity: hovered ? 1 : 0
              z: 5000
              x: slot ? slot.x + frameW / 2 - width / 2 : 0
              y: slot ? slot.y + frameH + 12 : 0
              width: pill.width
              height: pill.height
              Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

              Rectangle {
                id: pill
                width: Math.min(row.implicitWidth + 24, 520)
                height: 30
                radius: Style.cornerRadius
                color: Qt.rgba(0, 0, 0, 0.66)
                Row {
                  id: row
                  anchors.centerIn: parent
                  spacing: 8
                  Image {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    sourceSize.width: 36
                    sourceSize.height: 36
                    source: label.opacity > 0 ? root.iconFor(label.modelData.appId) : ""
                    visible: status === Image.Ready
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 450)
                    textFormat: Text.PlainText
                    text: label.modelData.title || label.modelData.appId
                    elide: Text.ElideRight
                    color: "white"
                    font.family: Style.font.menuFamily
                    font.pixelSize: 13
                  }
                }
              }
            }
          }
        }

        // ---------------------------------------------------- desktops bar

        Item {
          id: bar
          readonly property var ids: panel.mon ? (root.spaces[panel.mon.name] || []) : []
          readonly property real full: panel.mon ? root.barHeight(panel.mon) : 150
          readonly property real previewH: root.previewHeight
          readonly property real inset: panel.mon ? (panel.mon.notch || 0) : 0
          readonly property real previewW: panel.mon ? previewH * panel.mon.w / panel.mon.h : previewH
          readonly property int fresh: panel.mon ? root.newSpace(panel.mon.name) : -1

          x: 0
          width: parent.width
          height: full
          // Not part of the overlay's first frame: the copies are all that has to be in it.
          visible: root.hiddenAck
          // Slides down from above the screen as the windows spread.
          y: -(1 - panel.shown) * (height + 4)

          // Frosted glass. The only thing behind the bar is the wallpaper (the
          // windows are hidden), so the frost is the wallpaper itself, blurred
          // here, whether or not the compositor blurs; it stays put on the
          // screen while the glass slides over it.
          Item {
            anchors.fill: parent
            clip: true
            // Blurred at an eighth of the size and blown up: a blur costs by the
            // pixel, and at full size (a 6K layer on a large screen) it was the
            // one slow frame at the start of every opening.
            Item {
              readonly property int shrink: 8
              y: -bar.y
              width: Math.ceil(bar.width / shrink)
              height: Math.ceil(stage.height / shrink)
              scale: shrink
              transformOrigin: Item.TopLeft
              Image {
                anchors.fill: parent
                source: root.wallpaper
                sourceSize.width: 320
                fillMode: Image.PreserveAspectCrop
                layer.enabled: true
                layer.smooth: true
                layer.effect: MultiEffect {
                  autoPaddingEnabled: false
                  blurEnabled: true
                  blur: 1
                  blurMax: 10
                  saturation: 0.25
                }
              }
            }
            Rectangle {
              anchors.fill: parent
              color: Util.alpha(Commons.Color.background, 0.5)
            }
            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: 1
              color: Util.alpha(Commons.Color.foreground, 0.14)
            }
          }
          MouseArea { anchors.fill: parent }   // the strip itself does nothing

          // Where a window (its frame on the monitor) dropped on a desktop comes
          // to rest: its own place in that desktop's preview, at the preview's scale.
          function landing(id, frame) {
            var k = bar.previewW / panel.mon.w
            for (var i = 0; i < entries.count; i++) {
              var item = entries.itemAt(i)
              if (!item || item.target !== id) continue
              var o = item.mapToItem(stage, 0, 0)
              if (item.isNew) return { x: o.x + (item.width - frame.w * k) / 2, y: o.y + (bar.previewH - frame.h * k) / 2, s: k }
              return { x: o.x + frame.x * k, y: o.y + frame.y * k, s: k }
            }
            return null
          }

          // The desktop under a point of the stage (a window dropped on "+": a new one).
          function spaceAt(px, py) {
            if (py < bar.y || py > bar.y + bar.height) return -1
            for (var i = 0; i < entries.count; i++) {
              var item = entries.itemAt(i)
              if (!item) continue
              var p = item.mapFromItem(stage, px, py)
              if (p.x >= 0 && p.x <= item.width && p.y >= 0 && p.y <= item.height) return item.target
            }
            return -1
          }

          Row {
            id: strip
            anchors.horizontalCenter: parent.horizontalCenter
            y: bar.inset + 12
            spacing: 18

            Repeater {
              id: entries
              model: bar.ids.concat(bar.fresh > 0 ? [0] : [])

              delegate: Item {
                id: entry
                required property int modelData
                required property int index
                readonly property bool isNew: modelData === 0
                // Dragged sideways it leaves its place; the ones between there
                // and where it is now make room.
                readonly property real pitch: bar.previewW + strip.spacing
                readonly property bool reordering: root.reorderFrom >= 0 && panel.mon !== null && root.reorderMonitor === panel.mon.name
                readonly property bool lifted: reordering && root.reorderFrom === index
                property real dragX: 0
                property real shift: lifted ? dragX
                                   : !reordering || isNew ? 0
                                   : root.reorderFrom < index && index <= root.reorderTo ? -pitch
                                   : root.reorderTo <= index && index < root.reorderFrom ? pitch : 0
                Behavior on shift {
                  enabled: entry.reordering && !entry.lifted
                  NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
                }
                transform: Translate { x: entry.shift }
                z: lifted ? 10 : 0
                readonly property int target: isNew ? bar.fresh : modelData
                readonly property bool current: !isNew && panel.mon !== null && modelData === panel.mon.activeWs
                readonly property bool dropHere: root.dragging && root.dropSpace === target
                width: isNew ? Math.round(bar.previewH * 0.55) : bar.previewW
                height: bar.full - bar.inset - 12

                // The desktop in miniature: wallpaper and its windows where they are.
                Rectangle {
                  id: preview
                  width: entry.width
                  height: bar.previewH
                  radius: 0   // a desktop is a screen: square corners
                  color: entry.isNew ? Util.alpha(Commons.Color.foreground, entryMouse.containsMouse || entry.dropHere ? 0.22 : 0.1) : "#101010"
                  scale: entry.dropHere ? 1.06 : 1
                  Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

                  Loader {
                    anchors.fill: parent
                    active: !entry.isNew && panel.mon !== null
                    sourceComponent: Item {
                      id: mini
                      readonly property real k: width / panel.mon.w
                      clip: true
                      Image {
                        anchors.fill: parent
                        source: root.wallpaper
                        sourceSize.width: 800
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                      }
                      Repeater {
                        model: panel.list
                        Item {
                          id: tiny
                          required property var modelData
                          required property int index
                          readonly property var g: root.geo[modelData.address] || modelData
                          readonly property bool here: root.wsOf[modelData.address] === entry.modelData && !root.gone[modelData.address]
                          z: root.topped[modelData.address] ? 1000 + root.topped[modelData.address] : index
                          readonly property real barHeight: g.bar && modelData.fullscreen !== 2 ? root.deco.bar : 0
                          visible: here
                          x: (g.x - panel.mon.x) * mini.k
                          y: (g.y - panel.mon.y - barHeight) * mini.k
                          width: g.w * mini.k
                          height: (g.h + barHeight) * mini.k
                          Rectangle {
                            anchors.fill: parent
                            color: root.deco.titlebar
                          }
                          ScreencopyView {
                            y: tiny.barHeight * mini.k
                            width: parent.width
                            height: tiny.g.h * mini.k
                            // After the big copies have theirs, so the opening is not held up.
                            captureSource: tiny.here && root.hiddenAck && root.quota > tiny.index ? tiny.modelData.toplevel : null
                            live: root.liveThumbnails && entry.current
                          }
                        }
                      }
                    }
                  }
                  Text {
                    visible: entry.isNew
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "+"
                    color: Commons.Color.foreground
                    opacity: 0.85
                    font.pixelSize: 26
                  }
                  // The desktop you are on, and the one a click or a drop would go to.
                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    radius: 0
                    color: "transparent"
                    visible: !entry.isNew && (entry.current || entryMouse.containsMouse || entry.dropHere)
                    border.width: 2
                    border.color: entry.dropHere ? Commons.Color.accent : Util.alpha(Commons.Color.foreground, entry.current ? 1 : 0.45)
                  }
                }

                Text {
                  visible: !entry.isNew
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: bar.previewH + 8
                  textFormat: Text.PlainText
                  // Omarchy's own name for a workspace: its number on this monitor, the tenth as 0.
                  readonly property int number: panel.mon && panel.mon.renumber ? entry.index + 1
                                                                                 : entry.modelData - root.blockOf(entry.modelData)
                  text: number === 10 ? "0" : String(number)
                  color: Commons.Color.foreground
                  opacity: entry.current || entryMouse.containsMouse ? 1 : 0.65
                  font.family: Style.font.menuFamily
                  font.pixelSize: 12
                  font.weight: entry.current ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: entryMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: root.interactive
                  property real pressX: 0
                  property bool moved: false

                  function drop() {
                    root.reorderFrom = -1
                    root.reorderMonitor = ""
                    entry.dragX = 0
                  }
                  onPressed: (mouse) => {
                    pressX = mapToItem(strip, mouse.x, 0).x
                    moved = false
                  }
                  onPositionChanged: (mouse) => {
                    if (!pressed || entry.isNew) return
                    var x = mapToItem(strip, mouse.x, 0).x
                    if (!moved && Math.abs(x - pressX) < 10) return
                    moved = true
                    entry.dragX = x - pressX
                    root.reorderMonitor = panel.mon.name
                    root.reorderFrom = entry.index
                    root.reorderTo = Math.max(0, Math.min(bar.ids.length - 1, Math.round(entry.index + entry.dragX / entry.pitch)))
                  }
                  onReleased: {
                    if (!moved) return
                    var from = root.reorderFrom, to = root.reorderTo
                    var name = panel.mon.name
                    drop()
                    if (from >= 0 && from !== to) root.reorderSpace(name, from, to)
                  }
                  onCanceled: drop()
                  onClicked: if (!moved) root.goToSpace(panel.mon.name, entry.target)
                }
              }
            }
          }
        }
      }
    }
  }
}
